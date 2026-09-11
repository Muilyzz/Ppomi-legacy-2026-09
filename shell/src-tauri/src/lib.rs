mod protocol;
mod media;
#[cfg(target_os = "macos")]
mod media_macos;
#[cfg(any(target_os = "windows", test))]
mod media_windows;
#[cfg(not(target_os = "android"))]
mod desktop;
#[cfg(not(target_os = "android"))]
mod account;

use protocol::{failure, Request};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

fn trusted(window: &WebviewWindow) -> bool {
    window.label() == "main" && window.url().is_ok_and(|url|
        (url.scheme() == "tauri" && url.host_str() == Some("localhost")) ||
        (matches!(url.scheme(), "http" | "https") && url.host_str() == Some("tauri.localhost")))
}

async fn dispatch(app: &AppHandle, request: Request) -> Value {
    #[cfg(target_os = "android")]
    {
        use tauri_plugin_ppomi_executor::ExecutorExt;
        let id = request.id.clone();
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let value = serde_json::to_value(request).unwrap();
            app.executor().request(value).unwrap_or_else(|_| failure(&id, "native_unavailable"))
        }).await.unwrap_or_else(|_| failure("", "native_unavailable"))
    }
    #[cfg(not(target_os = "android"))]
    { app.state::<desktop::Executor>().request(app, request).await }
}

#[tauri::command]
async fn executor_request(app: AppHandle, window: WebviewWindow, request: Request) -> Value {
    if !trusted(&window) || request.validate(false).is_err() { return failure(&request.id, "invalid_request"); }
    let policy = app.state::<media::MediaPolicy>();
    let token = policy.begin(&request);
    if token.is_some() { media::revoke(&app); }
    let reply = dispatch(&app, request.clone()).await;
    policy.finish(&request, &reply, token);
    reply
}

/// Google sign-in (desktop): the executor mints the Supabase authorize URL, the system browser shows Google, and the
/// `ppomi://auth?code=…` deep link comes back through the single running instance. Only the executor sees tokens.
#[cfg(not(target_os = "android"))]
async fn sign_in(app: &AppHandle, id: String) -> Value {
    use tauri_plugin_opener::OpenerExt;
    let begun = dispatch(app, account::begin_frame()).await;
    if let Some(error) = begun.get("error") { return json!({"id": id, "error": error}); }
    let url = begun.get("result").and_then(|result| result.get("url")).and_then(Value::as_str).and_then(|text| tauri::Url::parse(text).ok());
    let Some(url) = url.filter(account::is_authorize_url) else { return failure(&id, "sign_in_failed"); };
    let callbacks = app.state::<account::SignInCallback>();
    let receiver = callbacks.arm();
    if app.opener().open_url(url.as_str(), None::<&str>).is_err() { callbacks.disarm(); return failure(&id, "sign_in_failed"); }
    // The person may take a while in the browser; an abandoned attempt simply expires (the executor forgets its verifier too).
    let callback = match tokio::time::timeout(std::time::Duration::from_secs(300), receiver).await {
        Ok(Ok(callback)) => callback,
        _ => { callbacks.disarm(); return failure(&id, "sign_in_failed"); }
    };
    dispatch(app, account::complete_frame(id, callback)).await
}

/// Settings and human answers are separate from the model's request channel.
#[tauri::command]
async fn executor_manage(app: AppHandle, window: WebviewWindow, action: String, args: Value) -> Value {
    let id = uuid::Uuid::new_v4().to_string();
    if !trusted(&window) || !args.is_object() { return failure(&id, "invalid_request"); }
    let (method, arguments) = match action.as_str() {
        "status" => ("executorStatus", json!({})),
        "answerApproval" => ("answerApproval", args),
        "setControlApps" => ("setControlApps", args),
        "openSettings" => ("openSettings", json!({})),
        "openAccount" => ("openAccount", json!({})),
        "openRecords" => ("openRecords", json!({})),
        "signIn" => {
            #[cfg(not(target_os = "android"))]
            { return sign_in(&app, id).await; }
            #[cfg(target_os = "android")]
            { ("openAccount", json!({})) }
        }
        "signOut" => ("signOut", json!({})),
        "refreshAccount" => ("refreshAccount", json!({})),
        "configureDevice" => {
            #[cfg(not(target_os = "android"))]
            {
                use tauri_plugin_dialog::DialogExt;
                let handle = app.clone();
                let selected = tauri::async_runtime::spawn_blocking(move ||
                    handle.dialog().file().set_title("뽀미 기기 등록 파일").add_filter("JSON", &["json"]).blocking_pick_file()
                ).await.ok().flatten();
                let Some(path) = selected.and_then(|p| p.into_path().ok()) else { return json!({"id":id,"result":{"cancelled":true}}); };
                ("configureDevice", json!({"path":path}))
            }
            #[cfg(target_os = "android")]
            { ("openSettings", json!({})) }
        }
        _ => return failure(&id, "invalid_request"),
    };
    let request = Request { id, method: method.into(), args: arguments };
    if request.validate(true).is_err() { return failure(&request.id, "invalid_request"); }
    dispatch(&app, request).await
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    // Single instance first: a `ppomi://auth` deep link launched by the browser must reach this window, not a second one.
    #[cfg(not(target_os = "android"))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
        if let Some(window) = app.get_webview_window("main") { let _ = window.set_focus(); }
    }));
    let builder = builder.manage(media::MediaPolicy::default());
    #[cfg(not(target_os = "android"))]
    let builder = builder.manage(desktop::Executor::default()).manage(account::SignInCallback::default())
        .plugin(tauri_plugin_dialog::init()).plugin(tauri_plugin_opener::init()).plugin(tauri_plugin_deep_link::init());
    #[cfg(target_os = "android")]
    let builder = builder.plugin(tauri_plugin_ppomi_executor::init());
    let app = builder
        .invoke_handler(tauri::generate_handler![executor_request, executor_manage])
        .setup(|app| {
            #[cfg(not(target_os = "android"))]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                // Installers register ppomi:// too; registering here covers `tauri dev` and portable runs (no schemes are configured on macOS).
                #[cfg(any(target_os = "windows", target_os = "linux"))]
                let _ = app.deep_link().register_all();
                let handle = app.handle().clone();
                app.deep_link().on_open_url(move |event| { handle.state::<account::SignInCallback>().deliver(&event.urls()); });
            }
            let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("뽀미").inner_size(1000.0, 780.0).min_inner_size(360.0, 480.0)
                .incognito(true)
                .use_https_scheme(true)
                .on_navigation(|url| (url.scheme() == "tauri" && url.host_str() == Some("localhost")) ||
                    (matches!(url.scheme(), "http" | "https") && url.host_str() == Some("tauri.localhost")))
                .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny)
                .on_page_load(|window, payload| {
                    if payload.event() == tauri::webview::PageLoadEvent::Started {
                        let app = window.app_handle().clone();
                        app.state::<media::MediaPolicy>().stop();
                        media::revoke(&app);
                        #[cfg(not(target_os = "android"))]
                        tauri::async_runtime::spawn(async move { app.state::<desktop::Executor>().stop().await; });
                        #[cfg(target_os = "android")]
                        tauri::async_runtime::spawn(async move {
                            let _ = dispatch(&app, Request {id:uuid::Uuid::new_v4().to_string(), method:"sessionState".into(), args:json!({"active":false,"mode":"voice"})}).await;
                        });
                    }
                })
                .build()?;
            #[cfg(target_os = "macos")]
            media_macos::install(&window, app.state::<media::MediaPolicy>().active.clone())?;
            #[cfg(target_os = "windows")]
            media_windows::install(&window, app.state::<media::MediaPolicy>().active.clone())?;
            #[cfg(not(any(target_os = "macos", target_os = "windows")))]
            let _ = window;
            Ok(())
        })
        .build(tauri::generate_context!()).expect("Could not start Ppomi shell");
    app.run(|app, event| {
        if matches!(event, tauri::RunEvent::Exit | tauri::RunEvent::WindowEvent {event: tauri::WindowEvent::Destroyed, ..}) {
            app.state::<media::MediaPolicy>().stop();
            #[cfg(not(target_os = "android"))]
            {
                let handle = app.clone();
                // Do not block the UI thread while a reader is dispatching its final UI event.
                // Process exit also closes the owned pipe, which terminates the helper on EOF.
                tauri::async_runtime::spawn(async move { handle.state::<desktop::Executor>().stop().await; });
            }
        }
    });
}
