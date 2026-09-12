use serde::{Serialize, Serializer};
use serde_json::Value;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Node start + brain + one fixture click take well under a minute; a hung child is killed, not awaited forever.
const HOST_TIMEOUT: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(50);

/// IPC error with a stable code. It crosses the IPC as the string `code: message`, which the
/// existing webview already renders verbatim; an object would show as `[object Object]`.
#[derive(Debug)]
pub struct HostError {
    pub code: String,
    pub message: String,
}

impl HostError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl Serialize for HostError {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format!("{}: {}", self.code, self.message))
    }
}

fn node_bin() -> String {
    std::env::var("PPOMI_NODE").unwrap_or_else(|_| "node".into())
}

fn host_script() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src/host.ts")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The window has no approval gate yet, so the IPC never arms a live body: `live` is refused
/// with a coded error, and the arming variables are stripped from the child's environment so a
/// `PPOMI_BODY_LIVE=1` inherited by the app cannot turn the fixture run into real control.
/// Async so the node run does not block the main thread and the webview.
#[tauri::command]
async fn run_path(intent: String, body: String, live: bool) -> Result<Value, HostError> {
    if live {
        return Err(HostError::new(
            "live_refused",
            "live is CLI-only until the window has an approval gate: PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live",
        ));
    }
    tauri::async_runtime::spawn_blocking(move || spawn_host(&intent, &body))
        .await
        .map_err(|error| HostError::new("host_task", format!("node host task failed: {error}")))?
}

fn spawn_host(intent: &str, body: &str) -> Result<Value, HostError> {
    let node = node_bin();
    let mut child = Command::new(&node)
        .arg("--experimental-strip-types")
        .arg(host_script())
        .arg("--intent")
        .arg(intent)
        .arg("--body")
        .arg(body)
        .current_dir(repo_root())
        .env_remove("PPOMI_BODY_LIVE")
        .env_remove("PPOMI_BODY_AX")
        .env_remove("PPOMI_BODY")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            HostError::new(
                "host_spawn",
                format!("node host failed to start ({node}): {error}"),
            )
        })?;

    let stdout = drain(child.stdout.take());
    let stderr = drain(child.stderr.take());
    let status = wait_with_timeout(&mut child, HOST_TIMEOUT);
    let stdout = String::from_utf8_lossy(&stdout.join().unwrap_or_default())
        .trim()
        .to_string();
    let stderr = String::from_utf8_lossy(&stderr.join().unwrap_or_default())
        .trim()
        .to_string();
    let status = status?;
    if !status.success() {
        return Err(HostError::new(
            "host_exit",
            if stderr.is_empty() {
                format!("node host exited {status}")
            } else {
                stderr
            },
        ));
    }
    serde_json::from_str(&stdout).map_err(|error| {
        HostError::new(
            "host_json",
            if stderr.is_empty() {
                format!("node host returned invalid JSON: {error}")
            } else {
                format!("node host returned invalid JSON: {error}; {stderr}")
            },
        )
    })
}

/// Read a pipe to the end on its own thread so a chatty child cannot deadlock on a full pipe.
fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut buffer = Vec::new();
        if let Some(mut pipe) = pipe {
            let _ = pipe.read_to_end(&mut buffer);
        }
        buffer
    })
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) -> Result<ExitStatus, HostError> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(HostError::new(
                        "host_timeout",
                        format!(
                            "node host did not finish within {} s and was killed",
                            timeout.as_secs()
                        ),
                    ));
                }
                thread::sleep(POLL);
            }
            Err(error) => {
                return Err(HostError::new(
                    "host_wait",
                    format!("node host wait failed: {error}"),
                ))
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_path])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
