//! Google sign-in round trip on desktop: the executor owns the PKCE verifier and every token; the shell only opens the
//! Supabase authorize URL in the system browser and hands the `ppomi://auth?code=…` deep link back to the executor.
use std::sync::Mutex;
use tauri::Url;
use tokio::sync::oneshot;

/// Public service host (SupabaseAuth.swift `PpomiServer.supabaseURL`). Not a secret; it bounds what the shell will open.
const SUPABASE_HOST: &str = "nafutfqfbbmknzmyspus.supabase.co";

/// Exactly one sign-in may wait for the browser at a time. A later attempt replaces the earlier waiter, which then fails.
#[derive(Default)]
pub struct SignInCallback(Mutex<Option<oneshot::Sender<String>>>);

impl SignInCallback {
    pub fn arm(&self) -> oneshot::Receiver<String> {
        let (sender, receiver) = oneshot::channel();
        *self.0.lock().unwrap() = Some(sender);
        receiver
    }

    pub fn disarm(&self) {
        self.0.lock().unwrap().take();
    }

    /// Every deep link the OS delivers passes through here. Only a `ppomi://auth` URL completes a waiting sign-in;
    /// anything else, or a callback nobody waits for, is dropped without effect.
    pub fn deliver(&self, urls: &[Url]) -> bool {
        let Some(url) = urls.iter().find(|url| is_callback(url)) else { return false };
        match self.0.lock().unwrap().take() {
            Some(sender) => sender.send(url.to_string()).is_ok(),
            None => false,
        }
    }
}

pub fn is_callback(url: &Url) -> bool {
    url.scheme() == "ppomi" && url.host_str() == Some("auth") && url.username().is_empty() && url.password().is_none()
}

/// The shell opens only the Supabase Google authorize endpoint over HTTPS, never an arbitrary URL from the helper.
pub fn is_authorize_url(url: &Url) -> bool {
    url.scheme() == "https" && url.host_str() == Some(SUPABASE_HOST) && url.port().is_none()
        && url.path() == "/auth/v1/authorize" && url.username().is_empty() && url.password().is_none()
        && url.query_pairs().any(|(key, value)| key == "provider" && value == "google")
        && url.query_pairs().any(|(key, value)| key == "redirect_to" && value == "ppomi://auth")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_supabase_google_authorize_url_is_opened() {
        let ok = Url::parse("https://nafutfqfbbmknzmyspus.supabase.co/auth/v1/authorize?provider=google&redirect_to=ppomi%3A%2F%2Fauth&code_challenge=abc&code_challenge_method=s256").unwrap();
        assert!(is_authorize_url(&ok));
        for bad in [
            "http://nafutfqfbbmknzmyspus.supabase.co/auth/v1/authorize?provider=google&redirect_to=ppomi%3A%2F%2Fauth",
            "https://evil.example/auth/v1/authorize?provider=google&redirect_to=ppomi%3A%2F%2Fauth",
            "https://nafutfqfbbmknzmyspus.supabase.co/auth/v1/token?provider=google&redirect_to=ppomi%3A%2F%2Fauth",
            "https://nafutfqfbbmknzmyspus.supabase.co/auth/v1/authorize?provider=github&redirect_to=ppomi%3A%2F%2Fauth",
            "https://nafutfqfbbmknzmyspus.supabase.co/auth/v1/authorize?provider=google&redirect_to=https%3A%2F%2Fevil.example",
            "https://user@nafutfqfbbmknzmyspus.supabase.co/auth/v1/authorize?provider=google&redirect_to=ppomi%3A%2F%2Fauth",
        ] {
            assert!(!is_authorize_url(&Url::parse(bad).unwrap()), "{bad}");
        }
    }

    #[test]
    fn callback_completes_exactly_one_waiting_sign_in() {
        let callbacks = SignInCallback::default();
        let stray = Url::parse("ppomi://auth?code=stray").unwrap();
        assert!(!callbacks.deliver(&[stray.clone()]), "nobody waiting: dropped");
        let mut receiver = callbacks.arm();
        assert!(!callbacks.deliver(&[Url::parse("ppomi://other?code=x").unwrap(), Url::parse("https://auth?code=x").unwrap()]));
        assert!(receiver.try_recv().is_err(), "foreign URLs do not complete the sign-in");
        assert!(callbacks.deliver(&[Url::parse("ppomi://auth?code=synthetic-code-1234").unwrap()]));
        assert_eq!(receiver.try_recv().unwrap(), "ppomi://auth?code=synthetic-code-1234");
        assert!(!callbacks.deliver(&[stray]), "a second callback has no waiter");
        let receiver = callbacks.arm();
        callbacks.disarm();
        assert!(receiver.blocking_recv().is_err(), "disarming fails the waiter instead of leaving it hanging");
    }
}
