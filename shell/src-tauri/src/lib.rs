use serde::Serialize;
use serde_json::Value;
use std::env;
use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Node start + brain + one fixture click; a hung child is killed, never awaited forever.
const RUN_PATH_TIMEOUT: Duration = Duration::from_secs(60);
/// One Responses round trip through the Gateway on top of the node start.
const GATEWAY_TIMEOUT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_millis(50);

/// Everything the TS host may see from the app's environment. `PATH` is rebuilt by `with_gui_path`.
/// Nothing else crosses: not the live-arming variables (`PPOMI_BODY_LIVE`, `PPOMI_BODY_AX`,
/// `PPOMI_BODY`, `PPOMI_SECRETS_LIVE`), not `NODE_*` (module/TLS injection), not `DYLD_*` / `LD_*`.
const CHILD_ENV_ALLOW: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "LANG",
    "PPOMI_CHAT",
    "PPOMI_NODE",
    "PPOMI_MAC_BROWSER",
    "AI_GATEWAY_API_KEY",
    "AI_GATEWAY_BASE_URL",
    "AI_TEXT_MODEL",
];

/// IPC error with a stable code. The webview reads `code`; `message` is the diagnostic
/// (spawn error, exit status + stderr preview, JSON preview) that the person otherwise never sees.
#[derive(Debug, Clone, Serialize)]
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

fn node_bin() -> PathBuf {
    if let Ok(explicit) = env::var("PPOMI_NODE") {
        return PathBuf::from(explicit);
    }
    for candidate in [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ] {
        if Path::new(candidate).is_file() {
            return PathBuf::from(candidate);
        }
    }
    PathBuf::from("node")
}

fn host_script() -> PathBuf {
    let raw = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src/host.ts");
    raw.canonicalize().unwrap_or(raw)
}

fn repo_root() -> PathBuf {
    env::var_os("PPOMI_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."))
}

fn with_gui_path(cmd: &mut Command) {
    let mut paths: Vec<PathBuf> = env::var_os("PATH")
        .map(|value| env::split_paths(&value).collect())
        .unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/usr/local/bin"] {
        let extra = PathBuf::from(extra);
        if extra.is_dir() && !paths.iter().any(|path| path == &extra) {
            paths.push(extra);
        }
    }
    if let Ok(joined) = env::join_paths(paths) {
        cmd.env("PATH", joined);
    }
}

fn child_env_allowed(name: &str) -> bool {
    CHILD_ENV_ALLOW.contains(&name) || name.starts_with("LC_")
}

/// Start from an empty environment and copy only the allow-list; the app's own environment
/// (whatever the launching shell, `launchctl setenv`, or another GUI app injected) stays behind.
fn prepare_host(cmd: &mut Command) {
    let inherited: Vec<(OsString, OsString)> = env::vars_os().collect();
    cmd.env_clear();
    for (key, value) in inherited {
        if key.to_str().is_some_and(child_env_allowed) {
            cmd.env(&key, &value);
        }
    }
    with_gui_path(cmd);
}

fn host_command(args: &[&str]) -> Command {
    let mut cmd = Command::new(node_bin());
    cmd.arg("--experimental-strip-types").arg(host_script());
    for arg in args {
        cmd.arg(arg);
    }
    cmd.current_dir(repo_root());
    prepare_host(&mut cmd);
    cmd
}

struct Captured {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

enum ChildFailure {
    Spawn(io::Error),
    Stdin(io::Error),
    Timeout(Duration),
    Wait(io::Error),
}

impl ChildFailure {
    fn describe(&self, node: &Path) -> String {
        match self {
            ChildFailure::Spawn(error) => format!("node host failed to start ({}): {error}", node.display()),
            ChildFailure::Stdin(error) => format!("node host stdin failed: {error}"),
            ChildFailure::Timeout(timeout) => {
                format!("node host did not finish within {} s and was killed", timeout.as_secs())
            }
            ChildFailure::Wait(error) => format!("node host wait failed: {error}"),
        }
    }
}

/// Spawn with every pipe attached, feed `stdin_payload` (then close stdin so the child sees EOF),
/// drain stdout and stderr on their own threads so a chatty child cannot block on a full pipe,
/// and kill the child at `timeout`. The bytes the child wrote are always what comes back —
/// never the parent's inherited stdout.
fn run_child(mut cmd: Command, stdin_payload: Option<&[u8]>, timeout: Duration) -> Result<Captured, ChildFailure> {
    cmd.stdin(if stdin_payload.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(ChildFailure::Spawn)?;
    let stdout = drain(child.stdout.take());
    let stderr = drain(child.stderr.take());
    if let Some(payload) = stdin_payload {
        let written = match child.stdin.take() {
            Some(mut stdin) => stdin.write_all(payload).and_then(|()| stdin.flush()),
            None => Err(io::Error::other("stdin pipe missing")),
        };
        if let Err(error) = written {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout.join();
            let _ = stderr.join();
            return Err(ChildFailure::Stdin(error));
        }
    }
    // A killed child may leave grandchildren holding the pipes; do not wait on the drains then.
    let status = wait_with_timeout(&mut child, timeout)?;
    Ok(Captured {
        status,
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
    })
}

fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut buffer = Vec::new();
        if let Some(mut pipe) = pipe {
            let _ = pipe.read_to_end(&mut buffer);
        }
        buffer
    })
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) -> Result<ExitStatus, ChildFailure> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ChildFailure::Timeout(timeout));
                }
                thread::sleep(POLL);
            }
            Err(error) => return Err(ChildFailure::Wait(error)),
        }
    }
}

fn preview_text(text: &str) -> String {
    const MAX: usize = 160;
    let trimmed = text.trim();
    if trimmed.chars().count() <= MAX {
        return trimmed.to_string();
    }
    trimmed.chars().take(MAX).collect::<String>() + "…"
}

fn last_json_value(stdout: &str) -> Option<Value> {
    let trimmed = stdout.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Some(value);
    }
    for line in trimmed.lines().rev() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            return Some(value);
        }
    }
    let start = trimmed.rfind('{')?;
    let end = trimmed.rfind('}')?;
    if end < start {
        return None;
    }
    serde_json::from_str::<Value>(&trimmed[start..=end]).ok()
}

fn parse_host_output(stdout: &str, stderr: &str, success: bool) -> Result<Value, String> {
    if let Some(value) = last_json_value(stdout) {
        return Ok(value);
    }
    let out = preview_text(stdout);
    let err = preview_text(stderr);
    let detail = match (out.is_empty(), err.is_empty()) {
        (true, true) => String::new(),
        (false, true) => format!("; stdout={out}"),
        (true, false) => format!("; stderr={err}"),
        (false, false) => format!("; stdout={out}; stderr={err}"),
    };
    if !success && out.is_empty() {
        return Err(if err.is_empty() {
            "node host exited without JSON".into()
        } else {
            err
        });
    }
    Err(format!("node host returned invalid JSON{detail}"))
}

/// Run one host invocation to completion and hand back the JSON object it printed last.
/// Every way this can go wrong — no node, stdin refused, timeout, non-JSON output — is one
/// `HostError` with the caller's `code`; nothing is guessed on the caller's behalf.
fn host_json(cmd: Command, stdin_payload: Option<&[u8]>, timeout: Duration, code: &str) -> Result<Value, HostError> {
    let node = node_bin();
    let captured = run_child(cmd, stdin_payload, timeout).map_err(|failure| HostError::new(code, failure.describe(&node)))?;
    parse_host_output(
        &String::from_utf8_lossy(&captured.stdout),
        &String::from_utf8_lossy(&captured.stderr),
        captured.status.success(),
    )
    .map_err(|message| HostError::new(code, message))
}

fn run_path_blocking(intent: &str, body: &str, live: bool) -> Result<Value, HostError> {
    let mut cmd = host_command(&["--intent", intent, "--body", body]);
    if live {
        cmd.arg("--live");
        cmd.env("PPOMI_BODY_LIVE", "1");
    }
    host_json(cmd, None, RUN_PATH_TIMEOUT, "run_path_host_failed")
}

fn ai_gateway_blocking(body: &Value) -> Result<Value, HostError> {
    let cmd = host_command(&["--proxy-responses"]);
    let payload = body.to_string();
    host_json(cmd, Some(payload.as_bytes()), GATEWAY_TIMEOUT, "gateway_host_failed")
}

fn join_failed(code: &str) -> impl FnOnce(tauri::Error) -> HostError + '_ {
    move |error| HostError::new(code, format!("node host task failed: {error}"))
}

/// Async so the node run never blocks the main thread and the webview.
#[tauri::command]
async fn run_path(intent: String, body: String, live: bool) -> Result<Value, HostError> {
    tauri::async_runtime::spawn_blocking(move || run_path_blocking(&intent, &body, live))
        .await
        .map_err(join_failed("run_path_host_failed"))?
}

/// The Gateway proxy: the Responses request goes to the host on stdin, the proxy reply comes
/// back as the last JSON object on stdout. A failure is `gateway_host_failed` with the detail,
/// never an empty or made-up reply.
#[tauri::command]
async fn ai_gateway(body: Value) -> Result<Value, HostError> {
    tauri::async_runtime::spawn_blocking(move || ai_gateway_blocking(&body))
        .await
        .map_err(join_failed("gateway_host_failed"))?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_path, ai_gateway])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_stdout_wins_even_when_exit_failed() {
        let value = parse_host_output("{\"status\":\"path_not_found\"}\n", "", false).unwrap();
        assert_eq!(value["status"], "path_not_found");
    }

    #[test]
    fn gateway_probe_json_is_host_stdout() {
        let value = parse_host_output("{\"configured\":false,\"fixture\":false}\n", "", true).unwrap();
        assert_eq!(value["configured"], false);
    }

    #[test]
    fn last_json_object_survives_stdout_noise() {
        let value = parse_host_output(
            "(node:1) ExperimentalWarning: strip types\n{\"status\":\"path_not_found\"}\nextra chatter\n",
            "ignored",
            true,
        )
        .unwrap();
        assert_eq!(value["status"], "path_not_found");
    }

    #[test]
    fn last_braced_json_survives_wrapped_noise() {
        let value = parse_host_output("prefix {\"configured\":true,\"fixture\":true} trailing", "", true).unwrap();
        assert_eq!(value["fixture"], true);
    }

    #[test]
    fn invalid_json_error_includes_stdout_and_stderr_preview() {
        let err = parse_host_output("not-json", "boom", true).unwrap_err();
        assert!(err.contains("invalid JSON"), "{err}");
        assert!(err.contains("not-json"), "{err}");
        assert!(err.contains("boom"), "{err}");
    }

    #[test]
    fn host_error_serializes_code_and_message() {
        let json = serde_json::to_value(HostError::new("gateway_host_failed", "boom")).unwrap();
        assert_eq!(json["code"], "gateway_host_failed");
        assert_eq!(json["message"], "boom");
    }

    #[test]
    fn child_env_is_an_allow_list() {
        for allowed in ["HOME", "PPOMI_CHAT", "AI_GATEWAY_API_KEY", "LC_ALL", "LC_CTYPE"] {
            assert!(child_env_allowed(allowed), "{allowed}");
        }
        for denied in [
            "PPOMI_BODY_LIVE",
            "PPOMI_BODY_AX",
            "PPOMI_BODY",
            "PPOMI_SECRETS_LIVE",
            "NODE_PATH",
            "NODE_OPTIONS",
            "NODE_EXTRA_CA_CERTS",
            "NODE_TLS_REJECT_UNAUTHORIZED",
            "DYLD_INSERT_LIBRARIES",
            "LD_PRELOAD",
            "ELECTRON_RUN_AS_NODE",
        ] {
            assert!(!child_env_allowed(denied), "{denied}");
        }
    }

    /// The reviewer's probe: the child writes its JSON to *its* stdout, and the parent must
    /// receive those bytes — with the old `wait_with_output` shape `captured stdout bytes = 0`.
    #[cfg(unix)]
    #[test]
    fn stdin_payload_reaches_the_child_and_its_stdout_is_captured() {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("read line; printf '{\"echo\":%s}\\n' \"$line\"");
        let captured = run_child(cmd, Some(b"{\"probe\":true}\n"), Duration::from_secs(10))
            .unwrap_or_else(|failure| panic!("{}", failure.describe(Path::new("sh"))));
        assert!(captured.status.success());
        assert!(!captured.stdout.is_empty(), "captured stdout bytes = 0");
        let value = last_json_value(&String::from_utf8_lossy(&captured.stdout)).unwrap();
        assert_eq!(value["echo"]["probe"], true);
    }

    #[cfg(unix)]
    #[test]
    fn stderr_is_captured_and_a_non_json_exit_is_a_coded_error() {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("echo boom >&2; exit 3");
        let err = host_json(cmd, None, Duration::from_secs(10), "gateway_host_failed").unwrap_err();
        assert_eq!(err.code, "gateway_host_failed");
        assert!(err.message.contains("boom"), "{}", err.message);
    }

    #[cfg(unix)]
    #[test]
    fn a_hung_child_is_killed_and_reported_as_the_callers_code() {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("sleep 30");
        let started = Instant::now();
        let err = host_json(cmd, None, Duration::from_millis(300), "run_path_host_failed").unwrap_err();
        assert_eq!(err.code, "run_path_host_failed");
        assert!(err.message.contains("did not finish"), "{}", err.message);
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_binary_is_a_coded_spawn_error() {
        let cmd = Command::new("/nonexistent/ppomi-node");
        let err = host_json(cmd, None, Duration::from_secs(1), "gateway_host_failed").unwrap_err();
        assert_eq!(err.code, "gateway_host_failed");
        assert!(err.message.contains("failed to start"), "{}", err.message);
    }

    /// Exact `ai_gateway` shape against the real TS host in fixture mode. Needs `node` on PATH and
    /// the repo checkout, so it only runs on request: `cargo test --lib -- --ignored gateway_probe`.
    #[test]
    #[ignore]
    fn gateway_probe_against_the_real_host_captures_json() {
        env::set_var("PPOMI_CHAT", "fixture");
        env::remove_var("AI_GATEWAY_API_KEY");
        let cmd = host_command(&["--proxy-responses"]);
        let captured = run_child(cmd, Some(b"{\"probe\":true}\n"), GATEWAY_TIMEOUT)
            .unwrap_or_else(|failure| panic!("{}", failure.describe(&node_bin())));
        eprintln!(
            "probe: captured stdout bytes = {}, stderr bytes = {}, status = {}",
            captured.stdout.len(),
            captured.stderr.len(),
            captured.status
        );
        assert!(!captured.stdout.is_empty(), "captured stdout bytes = 0");
        let value = ai_gateway_blocking(&serde_json::json!({ "probe": true })).unwrap();
        assert_eq!(value["configured"], true);
        assert_eq!(value["fixture"], true);
    }
}
