use serde_json::Value;
use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

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

fn prepare_host(cmd: &mut Command) {
    with_gui_path(cmd);
    // Grok Bot / Electron inject NODE_PATH into GUI apps; keep Ppomi + Gateway env.
    cmd.env_remove("NODE_PATH");
    cmd.env_remove("NODE_OPTIONS");
    cmd.env_remove("ELECTRON_RUN_AS_NODE");
    cmd.env_remove("ELECTRON_NO_ASAR");
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

#[tauri::command]
fn run_path(intent: String, body: String, live: bool) -> Result<Value, String> {
    let mut cmd = Command::new(node_bin());
    cmd.arg("--experimental-strip-types")
        .arg(host_script())
        .arg("--intent")
        .arg(&intent)
        .arg("--body")
        .arg(&body)
        .current_dir(repo_root());
    prepare_host(&mut cmd);
    if live {
        cmd.arg("--live");
        cmd.env("PPOMI_BODY_LIVE", "1");
    }
    let output = cmd
        .output()
        .map_err(|error| format!("node host failed to start: {error}"))?;
    parse_host_output(
        &String::from_utf8_lossy(&output.stdout),
        &String::from_utf8_lossy(&output.stderr),
        output.status.success(),
    )
}

#[tauri::command]
fn ai_gateway(body: Value) -> Result<Value, String> {
    let mut cmd = Command::new(node_bin());
    cmd.arg("--experimental-strip-types")
        .arg(host_script())
        .arg("--proxy-responses")
        .current_dir(repo_root())
        .stdin(Stdio::piped());
    prepare_host(&mut cmd);
    let mut child = cmd
        .spawn()
        .map_err(|error| format!("node host failed to start: {error}"))?;
    {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "node host stdin missing".to_string())?;
        stdin
            .write_all(body.to_string().as_bytes())
            .map_err(|error| format!("node host stdin failed: {error}"))?;
        stdin
            .flush()
            .map_err(|error| format!("node host stdin failed: {error}"))?;
    }
    let output = child
        .wait_with_output()
        .map_err(|error| format!("node host failed: {error}"))?;
    parse_host_output(
        &String::from_utf8_lossy(&output.stdout),
        &String::from_utf8_lossy(&output.stderr),
        output.status.success(),
    )
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
}
