fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&["executor_request", "executor_manage"]),
        ),
    ).expect("Tauri shell configuration is invalid");
}
