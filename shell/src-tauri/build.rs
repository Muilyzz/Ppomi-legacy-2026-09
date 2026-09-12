fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&["run_path", "ai_gateway"]),
        ),
    )
    .expect("Tauri shell configuration is invalid");
}
