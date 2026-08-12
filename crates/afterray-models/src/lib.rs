//! Local model scheduling and process adapters for `AfterRay`.
//!
//! The daemon owns scheduling through [`ModelQueue`]. Inference workers are
//! deliberately isolated behind [`ModelAdapter`], so a Python development
//! worker, an MLX Swift executable, or another local runtime can implement the
//! same JSON contract without changing the queue or store.

mod process;
mod queue;

pub use process::{ProcessAdapter, ProcessAdapterConfig, WorkerRequest, WorkerResponse};
pub use queue::{
    CapabilityConcurrency, JobId, JobSnapshot, JobState, ModelQueue, QueueConfig, QueueError,
};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc};

/// Model families understood by the V0 pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelCapability {
    Ocr,
    Asr,
    Embedding,
    Llm,
}

/// Typed input accepted by model adapters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ModelInput {
    Ocr {
        image_path: PathBuf,
        #[serde(skip_serializing_if = "Option::is_none")]
        prompt: Option<String>,
    },
    Asr {
        audio_path: PathBuf,
        #[serde(skip_serializing_if = "Option::is_none")]
        language: Option<String>,
    },
    Embedding {
        text: String,
    },
    Llm {
        prompt: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        system: Option<String>,
    },
}

impl ModelInput {
    #[must_use]
    pub const fn capability(&self) -> ModelCapability {
        match self {
            Self::Ocr { .. } => ModelCapability::Ocr,
            Self::Asr { .. } => ModelCapability::Asr,
            Self::Embedding { .. } => ModelCapability::Embedding,
            Self::Llm { .. } => ModelCapability::Llm,
        }
    }
}

/// Typed output returned by model adapters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ModelOutput {
    Ocr {
        text: String,
    },
    Asr {
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        language: Option<String>,
    },
    Embedding {
        vector: Vec<f32>,
    },
    Llm {
        text: String,
    },
}

impl ModelOutput {
    #[must_use]
    pub const fn capability(&self) -> ModelCapability {
        match self {
            Self::Ocr { .. } => ModelCapability::Ocr,
            Self::Asr { .. } => ModelCapability::Asr,
            Self::Embedding { .. } => ModelCapability::Embedding,
            Self::Llm { .. } => ModelCapability::Llm,
        }
    }
}

/// Cooperative cancellation shared by the scheduler and adapter.
#[derive(Debug, Clone, Default)]
pub struct Cancellation {
    inner: Arc<CancellationInner>,
}

#[derive(Debug, Default)]
struct CancellationInner {
    cancelled: std::sync::atomic::AtomicBool,
    notify: tokio::sync::Notify,
}

impl Cancellation {
    pub fn cancel(&self) {
        self.inner
            .cancelled
            .store(true, std::sync::atomic::Ordering::Release);
        self.inner.notify.notify_waiters();
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.inner
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
    }

    pub async fn cancelled(&self) {
        loop {
            let notified = self.inner.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AdapterError {
    #[error("model executable `{program}` was not found; install it or configure the adapter path")]
    MissingExecutable { program: String },
    #[error("model asset is missing: {0}")]
    MissingModel(String),
    #[error("model worker timed out after {seconds}s")]
    Timeout { seconds: u64 },
    #[error("model job was cancelled")]
    Cancelled,
    #[error("model worker exited unsuccessfully: {0}")]
    Process(String),
    #[error("model worker returned invalid output: {0}")]
    InvalidOutput(String),
    #[error("model worker I/O failed: {0}")]
    Io(#[from] std::io::Error),
}

impl AdapterError {
    /// Process crashes and transient I/O failures may succeed on another try.
    #[must_use]
    pub const fn retryable(&self) -> bool {
        matches!(self, Self::Process(_) | Self::Io(_) | Self::Timeout { .. })
    }
}

#[async_trait]
pub trait ModelAdapter: Send + Sync {
    fn capability(&self) -> ModelCapability;
    fn name(&self) -> &str;

    async fn execute(
        &self,
        job_id: &str,
        input: &ModelInput,
        cancellation: Cancellation,
    ) -> Result<ModelOutput, AdapterError>;
}

/// Builds adapters for all V0 capabilities from one compatible worker binary.
///
/// The repository's `scripts/download-models/afterray_model_worker.py` is the
/// reference implementation, but an MLX Swift worker can use the same contract.
#[must_use]
pub fn worker_adapters(program: impl Into<PathBuf>) -> Vec<Arc<dyn ModelAdapter>> {
    let program = program.into();
    [
        ModelCapability::Ocr,
        ModelCapability::Asr,
        ModelCapability::Embedding,
        ModelCapability::Llm,
    ]
    .into_iter()
    .map(|capability| {
        let name = format!("process-{capability:?}").to_lowercase();
        Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
            name,
            capability,
            program.clone(),
        ))) as Arc<dyn ModelAdapter>
    })
    .collect()
}
