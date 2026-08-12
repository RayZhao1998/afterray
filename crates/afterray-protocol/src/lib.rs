use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordingState {
    Idle,
    Recording,
    Stopping,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Ping,
    Status,
    RecordStart,
    RecordStop,
    SessionsList,
    MomentsList {
        session_id: String,
    },
    RecallWindow {
        session_id: String,
        center_ms: i64,
        limit: usize,
    },
    ReadArtifact {
        artifact_id: String,
    },
    FavoriteSet {
        moment_id: String,
        favorite: bool,
    },
    Search {
        query: String,
        limit: usize,
    },
    ModelsStatus,
    JobsList,
    JobRetry {
        job_id: String,
    },
    Summarize {
        session_id: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub protocol_version: u32,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Response {
    #[must_use]
    pub fn success(data: impl Serialize) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            ok: true,
            data: Some(serde_json::to_value(data).unwrap_or(Value::Null)),
            error: None,
        }
    }

    #[must_use]
    pub fn failure(error: impl Into<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            ok: false,
            data: None,
            error: Some(error.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Status {
    pub daemon_version: String,
    pub protocol_version: u32,
    pub schema_version: u32,
    pub recording_state: RecordingState,
    pub active_session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Moment {
    pub id: String,
    pub session_id: String,
    pub captured_at_ms: i64,
    pub image_artifact_id: String,
    pub is_favorite: bool,
    pub ocr_text: Option<String>,
    pub transcript_text: Option<String>,
    pub audio_artifact_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioSegment {
    pub id: String,
    pub session_id: String,
    pub track: AudioTrack,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub audio_artifact_id: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AudioTrack {
    System,
    Microphone,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtifactPayload {
    pub id: String,
    pub content_type: String,
    pub bytes_base64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub moment_id: String,
    pub session_id: String,
    pub captured_at_ms: i64,
    pub source: String,
    pub text: String,
    pub score: f32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip_is_stable() {
        let json = serde_json::to_string(&Request::RecordStart).unwrap();
        assert_eq!(json, r#"{"type":"record_start"}"#);
        let decoded: Request = serde_json::from_str(&json).unwrap();
        assert!(matches!(decoded, Request::RecordStart));
    }
}
