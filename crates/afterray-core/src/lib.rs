use afterray_protocol::{AudioSegment, Moment, Session};
use async_trait::async_trait;

#[derive(Debug, Clone)]
pub struct CapturedArtifact {
    pub content_type: String,
    pub captured_at_ms: i64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct CapturedAudioSegment {
    pub content_type: String,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("capture backend error: {0}")]
    Capture(String),
    #[error("store error: {0}")]
    Store(String),
}

#[async_trait]
pub trait CaptureBackend: Send + Sync {
    async fn start(&self) -> Result<(), CoreError>;
    async fn stop(&self) -> Result<(), CoreError>;
}

#[async_trait]
pub trait Store: Send + Sync {
    async fn create_session(&self, started_at_ms: i64) -> Result<Session, CoreError>;
    async fn end_session(&self, id: &str, ended_at_ms: i64) -> Result<(), CoreError>;
    async fn sessions(&self) -> Result<Vec<Session>, CoreError>;
    async fn moments(&self, session_id: &str) -> Result<Vec<Moment>, CoreError>;
    async fn audio_segments(&self, session_id: &str) -> Result<Vec<AudioSegment>, CoreError>;
}
