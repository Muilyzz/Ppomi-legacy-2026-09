//! WebView2 media permission policy for the bundled Windows shell.
//!
//! This handles new capture permission requests. The voice controller must also stop
//! existing MediaStream tracks when a session ends; a permission callback cannot revoke
//! a stream that WebView2 has already handed to the page.

#[cfg(target_os = "windows")]
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
#[cfg(target_os = "windows")]
use webview2_com::{
    take_pwstr,
    Microsoft::Web::WebView2::Win32::{
        ICoreWebView2PermissionRequestedEventArgs3, COREWEBVIEW2_PERMISSION_KIND,
        COREWEBVIEW2_PERMISSION_KIND_MICROPHONE, COREWEBVIEW2_PERMISSION_STATE_ALLOW,
        COREWEBVIEW2_PERMISSION_STATE_DENY,
    },
    PermissionRequestedEventHandler,
};
#[cfg(target_os = "windows")]
use windows::core::{Interface, PWSTR};

fn local_origin(uri: &str) -> Option<String> {
    let url = tauri::Url::parse(uri).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str() != Some("tauri.localhost")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return None;
    }
    Some(url.origin().ascii_serialization())
}

fn permits(request_uri: &str, page_uri: &str, microphone: bool, active_voice: bool) -> bool {
    microphone
        && active_voice
        && matches!(
            (local_origin(request_uri), local_origin(page_uri)),
            (Some(request), Some(page)) if request == page
        )
}

/// Install once immediately after creating the bundled webview. `active` is owned by
/// Rust session management, not a JavaScript writable setting. A dispatch/registration
/// failure must not leave a view with WebView2's default permission prompt behavior.
#[cfg(target_os = "windows")]
pub fn install(window: &tauri::WebviewWindow, active: Arc<AtomicBool>) -> tauri::Result<()> {
    let failed_window = window.clone();
    window.with_webview(move |platform| {
        let result = (|| -> windows::core::Result<()> {
            let controller = platform.controller();
            let webview = unsafe { controller.CoreWebView2()? };
            let callback_active = active.clone();
            let handler = PermissionRequestedEventHandler::create(Box::new(move |sender, args| {
                let Some(args) = args else {
                    return Ok(());
                };
                unsafe {
                    // Deny first: camera, location, clipboard, notification, unknown kinds,
                    // old runtimes and any later lookup failure never fall back to a prompt.
                    if args.SetState(COREWEBVIEW2_PERMISSION_STATE_DENY).is_err() {
                        std::process::exit(70);
                    }
                    let Ok(persistent_args) =
                        args.cast::<ICoreWebView2PermissionRequestedEventArgs3>()
                    else {
                        return Ok(());
                    };
                    persistent_args.SetSavesInProfile(false)?;
                    persistent_args.SetHandled(true)?;
                    let mut kind = COREWEBVIEW2_PERMISSION_KIND::default();
                    args.PermissionKind(&mut kind)?;
                    if kind != COREWEBVIEW2_PERMISSION_KIND_MICROPHONE
                        || !callback_active.load(Ordering::Acquire)
                    {
                        return Ok(());
                    }
                    let Some(sender) = sender else {
                        return Ok(());
                    };
                    let mut request_uri = PWSTR::null();
                    args.Uri(&mut request_uri)?;
                    let request_uri = take_pwstr(request_uri);
                    let mut page_uri = PWSTR::null();
                    sender.Source(&mut page_uri)?;
                    let page_uri = take_pwstr(page_uri);
                    if permits(
                        &request_uri,
                        &page_uri,
                        true,
                        callback_active.load(Ordering::Acquire),
                    ) {
                        args.SetState(COREWEBVIEW2_PERMISSION_STATE_ALLOW)?;
                    }
                    Ok(())
                }
            }));
            // The view retains the COM event handler until it is closed. Never remove it
            // while the view is alive, which would restore default permission behavior.
            let mut registration_token = 0i64;
            unsafe {
                webview.add_PermissionRequested(&handler, &mut registration_token)?;
            }
            Ok(())
        })();
        if result.is_err() {
            active.store(false, Ordering::Release);
            // with_webview schedules a UI-thread closure, so errors inside it cannot be
            // returned synchronously. Close that view instead of continuing without a gate.
            let _ = failed_window.destroy();
        }
    })
}

#[cfg(test)]
mod tests {
    use super::permits;

    #[test]
    fn allows_only_active_local_microphone() {
        assert!(permits(
            "http://tauri.localhost/",
            "http://tauri.localhost/index.html",
            true,
            true
        ));
        assert!(permits(
            "https://tauri.localhost/",
            "https://tauri.localhost/",
            true,
            true
        ));
        assert!(!permits(
            "http://tauri.localhost/",
            "http://tauri.localhost/",
            false,
            true
        ));
        assert!(!permits(
            "http://tauri.localhost/",
            "http://tauri.localhost/",
            true,
            false
        ));
    }

    #[test]
    fn rejects_remote_frames_navigation_and_origin_confusion() {
        for uri in [
            "https://example.invalid/",
            "http://tauri.localhost.evil.invalid/",
            "http://tauri.localhost@evil.invalid/",
            "http://evil@tauri.localhost/",
            "http://tauri.localhost:1420/",
            "file:///index.html",
            "tauri://localhost/",
        ] {
            assert!(!permits(uri, "http://tauri.localhost/", true, true));
            assert!(!permits("http://tauri.localhost/", uri, true, true));
        }
        assert!(!permits(
            "https://tauri.localhost/",
            "http://tauri.localhost/",
            true,
            true
        ));
    }
}
