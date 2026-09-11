use crate::protocol::{failure, is_notification, Request, MAX_REPLY};
use serde_json::{json, Value};
use std::{collections::HashMap, path::PathBuf, process::Stdio, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};
use tauri::{AppHandle, Emitter, Manager};
use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, process::{ChildStdin, Command}, sync::{mpsc, oneshot, Mutex as AsyncMutex}};

type Pending = Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>;

struct Connection {
    stdin: AsyncMutex<ChildStdin>,
    pending: Pending,
    alive: Arc<AtomicBool>,
    shutdown: mpsc::UnboundedSender<()>,
}

impl Connection {
    async fn request(&self, request: Request) -> Value {
        let id = request.id.clone();
        let (send, receive) = oneshot::channel();
        {
            let mut pending = self.pending.lock().unwrap();
            if !self.alive.load(Ordering::Acquire) { return failure(&id, "native_unavailable"); }
            if pending.contains_key(&id) { return failure(&id, "invalid_request"); }
            pending.insert(id.clone(), send);
        }
        let mut data = match serde_json::to_vec(&request) {
            Ok(data) => data,
            Err(_) => { self.pending.lock().unwrap().remove(&id); return failure(&id, "invalid_request"); }
        };
        data.push(b'\n');
        let write = {
            let mut stdin = self.stdin.lock().await;
            stdin.write_all(&data).await
        };
        if write.is_err() {
            self.pending.lock().unwrap().remove(&id);
            self.stop();
            return failure(&id, "native_unavailable");
        }
        // A native approval or long playbook can remain pending; other requests, especially Stop, keep flowing.
        // Completing a sign-in is two server round trips (token exchange, device registration) that the executor bounds at 90 s.
        let timeout = match request.method.as_str() {
            "executeTool" => Duration::from_secs(900),
            "completeSignIn" => Duration::from_secs(120),
            _ => Duration::from_secs(60),
        };
        match tokio::time::timeout(timeout, receive).await {
            Ok(Ok(value)) => value,
            Ok(Err(_)) => failure(&id, "native_unavailable"),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                // Do not retry a write whose outcome is unknown.
                failure(&id, "bridge_timeout")
            }
        }
    }

    fn stop(&self) {
        self.alive.store(false, Ordering::Release);
        let _ = self.shutdown.send(());
        fail_pending(&self.pending);
    }
}

fn fail_pending(pending: &Pending) {
    for (id, sender) in pending.lock().unwrap().drain() {
        let _ = sender.send(failure(&id, "session_ended"));
    }
}

fn when_current(generation: &Mutex<u64>, own: u64, action: impl FnOnce()) {
    let current = generation.lock().unwrap();
    if *current == own { action(); }
}

fn notify_current(app: &AppHandle, generation: Arc<Mutex<u64>>, own: u64, value: Value) {
    let handle = app.clone();
    // Keep the generation check and UI effects together on the main thread. A reader
    // never holds the generation lock while waiting for that thread to dispatch work.
    let _ = app.run_on_main_thread(move || when_current(&generation, own, || {
        if matches!(value.get("event").and_then(Value::as_str), Some("stop" | "voiceStop")) {
            handle.state::<crate::media::MediaPolicy>().stop();
            crate::media::revoke(&handle);
        }
        let _ = handle.emit_to("main", "ppomi-executor", value);
    }));
}

#[derive(Default)]
pub struct Executor {
    connection: AsyncMutex<Option<Arc<Connection>>>,
    generation: Arc<Mutex<u64>>,
}

impl Executor {
    pub async fn request(&self, app: &AppHandle, request: Request) -> Value {
        let connection = {
            let mut current = self.connection.lock().await;
            if current.as_ref().is_some_and(|c| !c.alive.load(Ordering::Acquire)) { *current = None; }
            if current.is_none() {
                // Status polling does not revive a helper after shutdown or a crash.
                if request.method == "executorStatus" { return failure(&request.id, "native_unavailable"); }
                let mut generation = self.generation.lock().unwrap();
                *generation = generation.wrapping_add(1);
                match start(app, self.generation.clone(), *generation) {
                    Ok(connection) => *current = Some(Arc::new(connection)),
                    Err(_) => return failure(&request.id, "native_unavailable"),
                }
            }
            current.as_ref().unwrap().clone()
        };
        connection.request(request).await
    }

    pub async fn stop(&self) {
        let mut current = self.connection.lock().await;
        let mut generation = self.generation.lock().unwrap();
        *generation = generation.wrapping_add(1);
        if let Some(connection) = current.take() { connection.stop(); }
    }
}

fn executable(app: &AppHandle) -> Result<PathBuf, ()> {
    let name = if cfg!(target_os = "windows") { "executor/ppomi-executor.exe" } else { "executor/ppomi-executor" };
    // During cargo/tauri dev the staged binary lives in the source tree. Release only trusts packaged resources.
    #[cfg(debug_assertions)]
    {
        let staged = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join(name);
        if staged.is_file() { return Ok(staged); }
    }
    let packaged = app.path().resolve(name, tauri::path::BaseDirectory::Resource).map_err(|_| ())?;
    if packaged.is_file() { Ok(packaged) } else { Err(()) }
}

fn start(app: &AppHandle, generation: Arc<Mutex<u64>>, own_generation: u64) -> Result<Connection, ()> {
    if !cfg!(any(target_os = "macos", target_os = "windows")) { return Err(()); }
    let executable = executable(app)?;
    let mut command = Command::new(&executable);
    let resources = executable.parent().and_then(|path| path.parent()).ok_or(())?;
    command.args(["--executor", "--owner-pid", &std::process::id().to_string()])
        .env("PPOMI_RESOURCE_DIR", resources)
        .current_dir(executable.parent().ok_or(())?)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000); // CREATE_NO_WINDOW; the Tauri window is the host.
    let mut child = command.spawn().map_err(|_| ())?;
    let stdin = child.stdin.take().ok_or(())?;
    let stdout = child.stdout.take().ok_or(())?;
    let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
    let alive = Arc::new(AtomicBool::new(true));
    let (shutdown, mut stopping) = mpsc::unbounded_channel();
    let reader_pending = pending.clone();
    let reader_alive = alive.clone();
    let reader_shutdown = shutdown.clone();
    let notify = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = Vec::new();
            // A broken helper cannot grow the host's buffer without bound.
            let count = tokio::io::AsyncReadExt::take(&mut reader, (MAX_REPLY + 1) as u64).read_until(b'\n', &mut line).await;
            if !matches!(count, Ok(1..)) || line.len() > MAX_REPLY || !line.ends_with(b"\n") { break; }
            let value: Value = match serde_json::from_slice(&line) { Ok(value) => value, Err(_) => break };
            if let Some(id) = value.get("id").and_then(Value::as_str) {
                if let Some(sender) = reader_pending.lock().unwrap().remove(id) { let _ = sender.send(value); }
            } else if is_notification(&value) {
                notify_current(&notify, generation.clone(), own_generation, value);
            } else { break; }
        }
        reader_alive.store(false, Ordering::Release);
        fail_pending(&reader_pending);
        let _ = reader_shutdown.send(());
        // A late EOF from an earlier page/connection cannot stop its successor.
        notify_current(&notify, generation, own_generation, json!({"event":"stop", "payload":{}}));
    });
    let supervisor_alive = alive.clone();
    let supervisor_pending = pending.clone();
    tauri::async_runtime::spawn(async move {
        tokio::select! {
            _ = child.wait() => {},
            _ = stopping.recv() => { let _ = child.kill().await; }
        }
        supervisor_alive.store(false, Ordering::Release);
        fail_pending(&supervisor_pending);
    });
    Ok(Connection { stdin: AsyncMutex::new(stdin), pending, alive, shutdown })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_helper_notifications_cannot_stop_or_notify_its_successor() {
        let generation = Mutex::new(2);
        let mut delivered = Vec::new();
        when_current(&generation, 1, || delivered.push("old-stop"));
        when_current(&generation, 2, || delivered.push("current-notice"));
        *generation.lock().unwrap() = 3;
        when_current(&generation, 2, || delivered.push("late-stop"));
        assert_eq!(delivered, ["current-notice"]);
    }
    #[tokio::test]
    async fn helper_exit_rejects_every_pending_request_without_retry() {
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let (a, ar) = oneshot::channel();
        let (b, br) = oneshot::channel();
        pending.lock().unwrap().insert("a".into(), a);
        pending.lock().unwrap().insert("b".into(), b);
        fail_pending(&pending);
        assert_eq!(ar.await.unwrap()["error"]["code"], "session_ended");
        assert_eq!(br.await.unwrap()["id"], "b");
        assert!(pending.lock().unwrap().is_empty());
    }
}
