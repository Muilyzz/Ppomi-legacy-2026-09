//! Per-webview microphone boundary. Wry's other WKUIDelegate behavior remains intact.

use std::{
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

use block2::Block;
use objc2::{
    define_class, msg_send,
    rc::Retained,
    runtime::{AnyObject, NSObject, ProtocolObject, Sel},
    DefinedClass, MainThreadOnly,
};
use objc2_foundation::{MainThreadMarker, NSObjectProtocol};
use objc2_web_kit::{
    WKFrameInfo, WKMediaCaptureState, WKMediaCaptureType, WKPermissionDecision, WKSecurityOrigin,
    WKUIDelegate, WKWebView,
};

static DELEGATE_KEY: u8 = 0;

struct MediaDelegateIvars {
    // WKWebView's delegate property is weak; the wrapper retains Wry's original delegate.
    original: Option<Retained<ProtocolObject<dyn WKUIDelegate>>>,
    voice_active: Arc<AtomicBool>,
    webview_address: usize,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "PpomiMediaPermissionDelegate"]
    #[thread_kind = MainThreadOnly]
    #[ivars = MediaDelegateIvars]
    struct MediaDelegate;

    unsafe impl NSObjectProtocol for MediaDelegate {
        #[unsafe(method(respondsToSelector:))]
        fn responds_to_selector(&self, selector: Sel) -> bool {
            // NSObject discovers methods implemented here, including the media decision override.
            let own: bool = unsafe { msg_send![super(self), respondsToSelector: selector] };
            own || self.ivars().original.as_ref().is_some_and(|delegate| delegate.respondsToSelector(selector))
        }
    }

    impl MediaDelegate {
        #[unsafe(method(forwardingTargetForSelector:))]
        fn forwarding_target(&self, selector: Sel) -> *mut AnyObject {
            // Optional WKUIDelegate methods (file picker/new-window handling, etc.) keep Wry's
            // implementation. The ivar keeps this borrowed forwarding target alive.
            self.ivars().original.as_ref()
                .filter(|delegate| delegate.respondsToSelector(selector))
                .map(|delegate| Retained::as_ptr(delegate).cast_mut().cast::<AnyObject>())
                .unwrap_or(ptr::null_mut())
        }
    }

    unsafe impl WKUIDelegate for MediaDelegate {
        #[unsafe(method(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:))]
        fn request_media_capture_permission(
            &self,
            webview: &WKWebView,
            origin: &WKSecurityOrigin,
            frame: &WKFrameInfo,
            capture_type: WKMediaCaptureType,
            decision_handler: &Block<dyn Fn(WKPermissionDecision)>,
        ) {
            let allowed = unsafe {
                let frame_origin = frame.securityOrigin();
                let frame_url = frame.request().URL().and_then(|url| url.absoluteString()).map(|url| url.to_string());
                let page_url = webview.URL().and_then(|url| url.absoluteString()).map(|url| url.to_string());
                let origin_matches = trusted_origin(&origin.protocol().to_string(), &origin.host().to_string(), origin.port())
                    && trusted_origin(&frame_origin.protocol().to_string(), &frame_origin.host().to_string(), frame_origin.port());
                can_capture(
                    self.ivars().voice_active.load(Ordering::SeqCst),
                    capture_type == WKMediaCaptureType::Microphone,
                    frame.isMainFrame(),
                    self.ivars().webview_address == webview as *const WKWebView as usize,
                    origin_matches,
                    frame_url.as_deref(),
                    page_url.as_deref(),
                )
            };
            // WebKit/macOS still enforce OS microphone permission; this grants no camera access.
            decision_handler.call((if allowed { WKPermissionDecision::Grant } else { WKPermissionDecision::Deny },));
        }
    }
);

impl MediaDelegate {
    fn new(marker: MainThreadMarker, ivars: MediaDelegateIvars) -> Retained<Self> {
        let allocated = marker.alloc::<Self>().set_ivars(ivars);
        unsafe { msg_send![super(allocated), init] }
    }
}

fn trusted_origin(scheme: &str, host: &str, port: isize) -> bool {
    matches!((scheme, host, port),
        ("tauri", "localhost", 0)
        | ("http", "tauri.localhost", 0 | 80)
        | ("https", "tauri.localhost", 0 | 443))
}

fn trusted_url(raw: &str) -> bool {
    tauri::Url::parse(raw).is_ok_and(|url| {
        url.username().is_empty()
            && url.password().is_none()
            && trusted_origin(url.scheme(), url.host_str().unwrap_or(""), url.port().unwrap_or(0) as isize)
    })
}

fn can_capture(
    active: bool,
    microphone_only: bool,
    main_frame: bool,
    same_webview: bool,
    trusted_security_origins: bool,
    frame_url: Option<&str>,
    page_url: Option<&str>,
) -> bool {
    active
        && microphone_only
        && main_frame
        && same_webview
        && trusted_security_origins
        && frame_url.is_some_and(trusted_url)
        && page_url.is_some_and(trusted_url)
}

/// Install before presenting the voice UI. `active` must mean an active voice session,
/// not merely an open window or text session. Tauri runs with_webview on the UI thread.
pub fn install(window: &tauri::WebviewWindow, active: Arc<AtomicBool>) -> tauri::Result<()> {
    window.with_webview(move |platform| unsafe {
        let marker = MainThreadMarker::new().expect("Tauri WKWebView callback must run on the main thread");
        let webview = &*platform.inner().cast::<WKWebView>();
        let object = (webview as *const WKWebView).cast_mut().cast::<AnyObject>();
        let key = ptr::addr_of!(DELEGATE_KEY).cast();
        let previous = objc2::ffi::objc_getAssociatedObject(object, key);
        // Reinstalling replaces the old wrapper instead of building a forwarding chain.
        let original = if previous.is_null() {
            webview.UIDelegate()
        } else {
            (&*previous.cast::<MediaDelegate>()).ivars().original.clone()
        };
        let delegate = MediaDelegate::new(marker, MediaDelegateIvars {
            original,
            voice_active: active,
            webview_address: webview as *const WKWebView as usize,
        });
        webview.setUIDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        // The association retains the wrapper until this exact webview is destroyed. It holds
        // only a non-owning webview address, so there is no retain cycle.
        objc2::ffi::objc_setAssociatedObject(
            object,
            key,
            Retained::as_ptr(&delegate).cast_mut().cast(),
            objc2::ffi::OBJC_ASSOCIATION_RETAIN_NONATOMIC,
        );
    })
}

/// Call after setting `active` false on Stop, disconnect, navigation, or window close.
/// This also revokes an already-open stream; a permission callback alone only gates new streams.
pub fn revoke(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    window.with_webview(|platform| unsafe {
        let webview = &*platform.inner().cast::<WKWebView>();
        webview.setMicrophoneCaptureState_completionHandler(WKMediaCaptureState::None, None);
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_bundled_origins_are_trusted() {
        for url in ["tauri://localhost/index.html", "http://tauri.localhost/", "https://tauri.localhost/#chat"] {
            assert!(trusted_url(url), "{url}");
        }
        for url in ["https://example.com", "http://localhost:1420", "tauri://evil/", "https://tauri.localhost.evil/",
            "http://tauri.localhost:1420", "file:///index.html", "https://user@tauri.localhost/", "data:text/html,test"] {
            assert!(!trusted_url(url), "{url}");
        }
        assert!(!trusted_origin("https", "tauri.localhost", 444));
    }

    #[test]
    fn only_active_microphone_in_this_local_main_frame_can_capture() {
        let local = Some("tauri://localhost/index.html");
        assert!(can_capture(true, true, true, true, true, local, local));
        for gate in 0..5 {
            let mut flags = [true; 5]; flags[gate] = false;
            assert!(!can_capture(flags[0], flags[1], flags[2], flags[3], flags[4], local, local));
        }
        assert!(!can_capture(true, true, true, true, true, None, local));
        assert!(!can_capture(true, true, true, true, true, local, Some("https://example.com")));
    }
}
