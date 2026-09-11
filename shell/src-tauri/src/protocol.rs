use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const MAX_REQUEST: usize = 2 * 1024 * 1024;
pub const MAX_REPLY: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub id: String,
    pub method: String,
    pub args: Value,
}

impl Request {
    pub fn validate(&self, management: bool) -> Result<(), &'static str> {
        if self.id.is_empty() || self.id.len() > 128 || !self.id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
            || !self.args.is_object() || serde_json::to_vec(self).map_err(|_| "invalid_request")?.len() > MAX_REQUEST {
            return Err("invalid_request");
        }
        let allowed = match self.method.as_str() {
            "bootstrap" | "request" | "executeTool" | "sessionState" | "heard" | "declineCall"
            | "bankProfileRequest" | "bankProfileSubmit" | "bankProfileCancel" => true,
            "executorStatus" | "answerApproval" | "setControlApps" | "openSettings" | "openAccount" | "openRecords" | "configureDevice"
            | "beginSignIn" | "completeSignIn" | "signOut" | "refreshAccount" => management,
            _ => false,
        };
        if allowed { Ok(()) } else { Err("invalid_request") }
    }
}

pub fn failure(id: &str, code: &str) -> Value {
    json!({"id": id, "error": {"code": code, "message": "Native operation failed"}})
}

pub fn is_notification(value: &Value) -> bool {
    matches!(value.get("event").and_then(Value::as_str),
        Some("notice" | "incomingCall" | "answerCall" | "stop" | "voiceStop" | "toolProgress" | "statusChanged"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn model_requests_cannot_use_management_or_arbitrary_processes() {
        for method in ["answerApproval", "configureDevice", "setControlApps", "setEndpoint", "beginSignIn", "completeSignIn", "signOut", "refreshAccount", "shell", "spawn"] {
            let request = Request {id: "request-1".into(), method: method.into(), args: json!({})};
            assert_eq!(request.validate(false), Err("invalid_request"));
        }
    }
    #[test]
    fn invalid_envelopes_are_rejected_before_executor_start() {
        let mut request = Request {id: "one\ntwo".into(), method: "bootstrap".into(), args: json!({})};
        assert!(request.validate(false).is_err());
        request.id = "one".into();
        request.args = json!([]);
        assert!(request.validate(false).is_err());
        request.args = json!({"value": "x".repeat(MAX_REQUEST)});
        assert!(request.validate(false).is_err());
    }
    #[test]
    fn native_events_have_a_closed_vocabulary() {
        assert!(is_notification(&json!({"event":"stop", "payload":{}})));
        assert!(!is_notification(&json!({"event":"evaluateJavascript", "payload":"..."})));
    }
}
