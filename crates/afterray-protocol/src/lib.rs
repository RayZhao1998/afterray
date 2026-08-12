use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroize as _;

pub const PROTOCOL_VERSION: u32 = 2;

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
    TimelineList,
    TimelineSince {
        since_ms: i64,
    },
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
    pub accessibility_artifact_id: Option<String>,
    pub application_name: Option<String>,
    pub bundle_identifier: Option<String>,
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

/// JSON header for `read_artifact`. The decrypted bytes follow the newline
/// as a raw payload of exactly `byte_length` octets. Failures are a JSON
/// line with no trailing body.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ArtifactMeta {
    pub id: String,
    pub content_type: String,
    pub byte_length: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtifactPayload {
    pub id: String,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

impl Drop for ArtifactPayload {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

impl ArtifactPayload {
    #[must_use]
    pub fn meta(&self) -> ArtifactMeta {
        ArtifactMeta {
            id: self.id.clone(),
            content_type: self.content_type.clone(),
            byte_length: u64::try_from(self.bytes.len()).unwrap_or(u64::MAX),
        }
    }

    /// Encodes the JSON response header preceding the raw artifact bytes.
    ///
    /// # Errors
    ///
    /// Returns an error if the response metadata cannot be serialized as JSON.
    pub fn header_line(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut header = serde_json::to_vec(&Response::success(self.meta()))?;
        header.push(b'\n');
        Ok(header)
    }
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

    #[test]
    fn timeline_cursor_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::TimelineSince { since_ms: 42 }).unwrap();
        assert_eq!(json, r#"{"type":"timeline_since","since_ms":42}"#);
    }

    #[test]
    fn artifact_header_omits_bytes() {
        let payload = ArtifactPayload {
            id: "a1".to_owned(),
            content_type: "image/jpeg".to_owned(),
            bytes: b"\x00\xffJPEG".to_vec(),
        };
        let header = payload.header_line().unwrap();
        let text = std::str::from_utf8(&header).unwrap();
        assert!(text.ends_with('\n'));
        assert!(!text.contains("bytes"));
        assert!(!text.contains("base64"));
        let parsed: Response = serde_json::from_slice(&header[..header.len() - 1]).unwrap();
        assert!(parsed.ok);
        let meta: ArtifactMeta = serde_json::from_value(parsed.data.unwrap()).unwrap();
        assert_eq!(meta.id, "a1");
        assert_eq!(meta.content_type, "image/jpeg");
        assert_eq!(meta.byte_length, 6);
    }
}
