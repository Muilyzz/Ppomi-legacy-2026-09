use serde_json::Value;
use tauri::{plugin::{Builder, TauriPlugin}, Manager, Runtime};

#[cfg(target_os = "android")]
use tauri::{ipc::Channel, plugin::PluginHandle, Emitter};

/// Android execution stays in Kotlin; desktop shells use their own process transport.
pub struct Executor<R: Runtime> {
    #[cfg(target_os = "android")]
    handle: PluginHandle<R>,
    #[cfg(not(target_os = "android"))]
    marker: std::marker::PhantomData<fn() -> R>,
}

impl<R: Runtime> Executor<R> {
    /// Call from a worker thread; requests may wait for explicit native permission UI.
    pub fn request(&self, request: Value) -> Result<Value, String> {
        #[cfg(target_os = "android")]
        {
            self.handle.run_mobile_plugin("request", serde_json::json!({"request": request.to_string()}))
                .map_err(|_| "android_executor_unavailable".to_owned())
        }
        #[cfg(not(target_os = "android"))]
        {
            let _ = request;
            Err("android_executor_unavailable".to_owned())
        }
    }
}

pub trait ExecutorExt<R: Runtime> {
    fn executor(&self) -> &Executor<R>;
}
impl<R: Runtime, T: Manager<R>> ExecutorExt<R> for T {
    fn executor(&self) -> &Executor<R> { self.state::<Executor<R>>().inner() }
}

#[tauri::command]
async fn request<R: Runtime>(app: tauri::AppHandle<R>, request: Value) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || app.executor().request(request))
        .await.map_err(|_| "android_executor_unavailable".to_owned())?
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("ppomi-executor")
        .invoke_handler(tauri::generate_handler![request])
        .setup(|app, api| {
            #[cfg(target_os = "android")]
            {
                let handle = api.register_android_plugin("com.ppomi.executor", "PpomiExecutorPlugin")?;
                let events = handle.clone();
                let event_app = app.clone();
                // Registration must not block Android's UI thread during plugin setup.
                std::thread::spawn(move || {
                    let channel = Channel::<Value>::new(move |body| {
                        let value: Value = body.deserialize()?;
                        event_app.emit("ppomi-executor", value)
                    });
                    let _ = events.run_mobile_plugin::<Value>("registerListener",
                        serde_json::json!({"event": "notification", "handler": channel}));
                });
                app.manage(Executor { handle });
            }
            #[cfg(not(target_os = "android"))]
            {
                let _ = api;
                app.manage(Executor::<R> { marker: std::marker::PhantomData });
            }
            Ok(())
        })
        .build()
}
