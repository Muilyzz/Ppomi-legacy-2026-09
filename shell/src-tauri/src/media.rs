use crate::protocol::Request;
use serde_json::Value;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

pub fn revoke(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    {
        use tauri::Manager;
        if let Some(window) = app.get_webview_window("main") { let _ = crate::media_macos::revoke(&window); }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

/// Capture belongs to an acknowledged voice session, including when start/stop replies race.
#[derive(Default)]
pub struct MediaPolicy {
    pub active: Arc<AtomicBool>,
    epoch: Mutex<u64>,
}

impl MediaPolicy {
    pub fn begin(&self, request: &Request) -> Option<u64> {
        if request.method != "sessionState" { return None; }
        let mut epoch = self.epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.active.store(false, Ordering::Release);
        Some(*epoch)
    }

    pub fn finish(&self, request: &Request, reply: &Value, token: Option<u64>) {
        let Some(token) = token else { return; };
        let epoch = self.epoch.lock().unwrap();
        if *epoch == token {
            let allowed = request.args.get("active").and_then(Value::as_bool) == Some(true)
                && request.args.get("mode").and_then(Value::as_str).unwrap_or("voice") == "voice"
                && reply.get("error").is_none()
                && reply.get("result").and_then(|value| value.get("active")).and_then(Value::as_bool) == Some(true);
            self.active.store(allowed, Ordering::Release);
        }
    }

    pub fn stop(&self) {
        let mut epoch = self.epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.active.store(false, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn session(active: bool, mode: &str) -> Request {
        Request {id:"test".into(), method:"sessionState".into(), args:json!({"active":active,"mode":mode})}
    }
    #[test]
    fn stop_wins_over_delayed_start_and_helper_exit_revokes_capture() {
        let policy = MediaPolicy::default();
        let start = session(true, "voice");
        let token = policy.begin(&start);
        policy.begin(&session(false,"voice"));
        policy.finish(&start, &json!({"result":{"active":true}}), token);
        assert!(!policy.active.load(Ordering::Acquire));
        let token = policy.begin(&start);
        policy.finish(&start, &json!({"result":{"active":true}}), token);
        assert!(policy.active.load(Ordering::Acquire));
        policy.stop();
        policy.finish(&start, &json!({"result":{"active":true}}), token);
        assert!(!policy.active.load(Ordering::Acquire));
    }
    #[test]
    fn text_and_rejected_sessions_never_enable_capture() {
        let policy = MediaPolicy::default();
        let text = session(true,"text");
        let token = policy.begin(&text);
        policy.finish(&text, &json!({"result":{"active":true}}), token);
        assert!(!policy.active.load(Ordering::Acquire));
        let voice = session(true,"voice");
        let token = policy.begin(&voice);
        policy.finish(&voice, &json!({"error":{"code":"session_ended"}}), token);
        assert!(!policy.active.load(Ordering::Acquire));
    }
}
