use serde_json::Value;
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

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
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src/host.ts")
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

fn parse_host_output(stdout: &str, stderr: &str, success: bool) -> Result<Value, String> {
    let trimmed = stdout.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Ok(value);
    }
    if !success {
        return Err(if stderr.trim().is_empty() {
            format!("node host exited without JSON")
        } else {
            stderr.trim().to_string()
        });
    }
    Err(if stderr.trim().is_empty() {
        format!("node host returned invalid JSON")
    } else {
        format!("node host returned invalid JSON; {}", stderr.trim())
    })
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
    with_gui_path(&mut cmd);
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_path])
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
}
