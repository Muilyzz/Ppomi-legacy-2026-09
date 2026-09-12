use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;

fn node_bin() -> String {
    std::env::var("PPOMI_NODE").unwrap_or_else(|_| "node".into())
}

fn host_script() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../src/host.ts")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
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
    if live {
        cmd.arg("--live");
        cmd.env("PPOMI_BODY_LIVE", "1");
    }
    let output = cmd
        .output()
        .map_err(|error| format!("node host failed to start: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !output.status.success() {
        return Err(if stderr.is_empty() {
            format!("node host exited {}", output.status)
        } else {
            stderr
        });
    }
    serde_json::from_str(&stdout).map_err(|error| {
        if stderr.is_empty() {
            format!("node host returned invalid JSON: {error}")
        } else {
            format!("node host returned invalid JSON: {error}; {stderr}")
        }
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_path])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
