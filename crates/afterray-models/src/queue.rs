use crate::{AdapterError, Cancellation, ModelAdapter, ModelCapability, ModelInput, ModelOutput};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{Mutex, Notify, Semaphore};
use uuid::Uuid;

pub type JobId = String;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Pending,
    Running,
    Done,
    Failed,
    Cancelled,
}

impl JobState {
    const fn terminal(self) -> bool {
        matches!(self, Self::Done | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobSnapshot {
    pub id: JobId,
    pub capability: ModelCapability,
    pub adapter: String,
    pub state: JobState,
    pub attempts: u32,
    pub max_attempts: u32,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub output: Option<ModelOutput>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct CapabilityConcurrency {
    pub ocr: usize,
    pub asr: usize,
    pub embedding: usize,
    pub llm: usize,
}

impl Default for CapabilityConcurrency {
    fn default() -> Self {
        Self {
            ocr: 1,
            asr: 1,
            embedding: 2,
            llm: 1,
        }
    }
}

impl CapabilityConcurrency {
    const fn for_capability(self, capability: ModelCapability) -> usize {
        match capability {
            ModelCapability::Ocr => self.ocr,
            ModelCapability::Asr => self.asr,
            ModelCapability::Embedding => self.embedding,
            ModelCapability::Llm => self.llm,
        }
    }
}

#[derive(Debug, Clone)]
pub struct QueueConfig {
    pub max_attempts: u32,
    pub retry_delay: Duration,
    pub concurrency: CapabilityConcurrency,
}

impl Default for QueueConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            retry_delay: Duration::from_secs(2),
            concurrency: CapabilityConcurrency::default(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum QueueError {
    #[error("no model adapter is registered for {0:?}")]
    MissingAdapter(ModelCapability),
    #[error("model concurrency for {0:?} must be at least one")]
    InvalidConcurrency(ModelCapability),
    #[error("model job `{0}` does not exist")]
    MissingJob(String),
    #[error("model job `{0}` is not in a retryable state")]
    NotRetryable(String),
}

struct JobRecord {
    snapshot: JobSnapshot,
    input: ModelInput,
    cancellation: Cancellation,
    generation: u64,
}

struct QueueInner {
    adapters: HashMap<ModelCapability, Arc<dyn ModelAdapter>>,
    semaphores: HashMap<ModelCapability, Arc<Semaphore>>,
    jobs: Mutex<HashMap<JobId, JobRecord>>,
    changed: Notify,
    config: QueueConfig,
}

#[derive(Clone)]
pub struct ModelQueue {
    inner: Arc<QueueInner>,
}

impl ModelQueue {
    /// Creates a model queue with at most one adapter per capability.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::InvalidConcurrency`] when any capability is
    /// configured with zero execution slots.
    pub fn new(
        adapters: impl IntoIterator<Item = Arc<dyn ModelAdapter>>,
        config: QueueConfig,
    ) -> Result<Self, QueueError> {
        let mut by_capability = HashMap::new();
        for adapter in adapters {
            by_capability.insert(adapter.capability(), adapter);
        }

        let mut semaphores = HashMap::new();
        for capability in [
            ModelCapability::Ocr,
            ModelCapability::Asr,
            ModelCapability::Embedding,
            ModelCapability::Llm,
        ] {
            let count = config.concurrency.for_capability(capability);
            if count == 0 {
                return Err(QueueError::InvalidConcurrency(capability));
            }
            semaphores.insert(capability, Arc::new(Semaphore::new(count)));
        }

        Ok(Self {
            inner: Arc::new(QueueInner {
                adapters: by_capability,
                semaphores,
                jobs: Mutex::new(HashMap::new()),
                changed: Notify::new(),
                config,
            }),
        })
    }

    /// Enqueues a typed inference job and starts processing it in the background.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingAdapter`] when no adapter handles the input.
    pub async fn submit(&self, input: ModelInput) -> Result<JobId, QueueError> {
        let capability = input.capability();
        let adapter = self
            .inner
            .adapters
            .get(&capability)
            .ok_or(QueueError::MissingAdapter(capability))?;
        let id = Uuid::now_v7().to_string();
        let now = unix_time_ms();
        let record = JobRecord {
            snapshot: JobSnapshot {
                id: id.clone(),
                capability,
                adapter: adapter.name().to_owned(),
                state: JobState::Pending,
                attempts: 0,
                max_attempts: self.inner.config.max_attempts.max(1),
                created_at_ms: now,
                updated_at_ms: now,
                output: None,
                last_error: None,
            },
            input,
            cancellation: Cancellation::default(),
            generation: 0,
        };
        self.inner.jobs.lock().await.insert(id.clone(), record);
        self.inner.changed.notify_waiters();
        spawn_attempt(Arc::clone(&self.inner), id.clone(), 0);
        Ok(id)
    }

    /// Reads the current immutable job snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn get(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        self.inner
            .jobs
            .lock()
            .await
            .get(id)
            .map(|record| record.snapshot.clone())
            .ok_or_else(|| QueueError::MissingJob(id.to_owned()))
    }

    pub async fn list(&self) -> Vec<JobSnapshot> {
        let mut jobs: Vec<_> = self
            .inner
            .jobs
            .lock()
            .await
            .values()
            .map(|record| record.snapshot.clone())
            .collect();
        jobs.sort_by_key(|job| job.created_at_ms);
        jobs
    }

    /// Waits until a job reaches a terminal state.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn wait(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        loop {
            let changed = self.inner.changed.notified();
            let snapshot = self.get(id).await?;
            if snapshot.state.terminal() {
                return Ok(snapshot);
            }
            changed.await;
        }
    }

    /// Cancels pending slot acquisition or a running adapter process.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn cancel(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        let mut jobs = self.inner.jobs.lock().await;
        let record = jobs
            .get_mut(id)
            .ok_or_else(|| QueueError::MissingJob(id.to_owned()))?;
        if !record.snapshot.state.terminal() {
            record.cancellation.cancel();
            record.generation = record.generation.wrapping_add(1);
            record.snapshot.state = JobState::Cancelled;
            record.snapshot.updated_at_ms = unix_time_ms();
            record.snapshot.last_error = Some("cancelled by caller".to_owned());
        }
        let snapshot = record.snapshot.clone();
        drop(jobs);
        self.inner.changed.notify_waiters();
        Ok(snapshot)
    }

    /// Restarts a failed or cancelled job with a fresh retry budget.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown, or
    /// [`QueueError::NotRetryable`] when it has not failed or been cancelled.
    pub async fn retry(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        let generation;
        let snapshot;
        {
            let mut jobs = self.inner.jobs.lock().await;
            let record = jobs
                .get_mut(id)
                .ok_or_else(|| QueueError::MissingJob(id.to_owned()))?;
            if !matches!(
                record.snapshot.state,
                JobState::Failed | JobState::Cancelled
            ) {
                return Err(QueueError::NotRetryable(id.to_owned()));
            }
            record.cancellation.cancel();
            record.cancellation = Cancellation::default();
            record.generation = record.generation.wrapping_add(1);
            generation = record.generation;
            record.snapshot.state = JobState::Pending;
            record.snapshot.attempts = 0;
            record.snapshot.updated_at_ms = unix_time_ms();
            record.snapshot.output = None;
            record.snapshot.last_error = None;
            snapshot = record.snapshot.clone();
        }
        self.inner.changed.notify_waiters();
        spawn_attempt(Arc::clone(&self.inner), id.to_owned(), generation);
        Ok(snapshot)
    }
}

fn spawn_attempt(inner: Arc<QueueInner>, id: JobId, generation: u64) {
    tokio::spawn(async move {
        run_attempts(&inner, &id, generation).await;
    });
}

async fn run_attempts(inner: &Arc<QueueInner>, id: &str, generation: u64) {
    loop {
        let Some((input, capability, cancellation, attempt, max_attempts)) =
            prepare_attempt(inner, id, generation).await
        else {
            return;
        };
        let Some(adapter) = inner.adapters.get(&capability).cloned() else {
            finish_failed(inner, id, generation, "adapter disappeared".to_owned()).await;
            return;
        };
        let Some(semaphore) = inner.semaphores.get(&capability).cloned() else {
            finish_failed(
                inner,
                id,
                generation,
                "concurrency slot disappeared".to_owned(),
            )
            .await;
            return;
        };

        let permit = tokio::select! {
            () = cancellation.cancelled() => return,
            result = semaphore.acquire_owned() => {
                let Ok(permit) = result else {
                    finish_failed(inner, id, generation, "model queue is shutting down".to_owned()).await;
                    return;
                };
                permit
            }
        };
        if !set_running(inner, id, generation).await {
            return;
        }
        let result = adapter.execute(id, &input, cancellation.clone()).await;
        drop(permit);

        match result {
            Ok(output) => {
                finish_done(inner, id, generation, output).await;
                return;
            }
            Err(AdapterError::Cancelled) => return,
            Err(error) if error.retryable() && attempt < max_attempts => {
                if !set_pending_error(inner, id, generation, error.to_string()).await {
                    return;
                }
                tokio::select! {
                    () = cancellation.cancelled() => return,
                    () = tokio::time::sleep(inner.config.retry_delay) => {}
                }
            }
            Err(error) => {
                finish_failed(inner, id, generation, error.to_string()).await;
                return;
            }
        }
    }
}

async fn prepare_attempt(
    inner: &QueueInner,
    id: &str,
    generation: u64,
) -> Option<(ModelInput, ModelCapability, Cancellation, u32, u32)> {
    let mut jobs = inner.jobs.lock().await;
    let record = jobs.get_mut(id)?;
    if record.generation != generation || record.snapshot.state != JobState::Pending {
        return None;
    }
    record.snapshot.attempts += 1;
    record.snapshot.updated_at_ms = unix_time_ms();
    let value = (
        record.input.clone(),
        record.snapshot.capability,
        record.cancellation.clone(),
        record.snapshot.attempts,
        record.snapshot.max_attempts,
    );
    drop(jobs);
    inner.changed.notify_waiters();
    Some(value)
}

async fn set_running(inner: &QueueInner, id: &str, generation: u64) -> bool {
    update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Running;
    })
    .await
}

async fn set_pending_error(inner: &QueueInner, id: &str, generation: u64, error: String) -> bool {
    update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Pending;
        snapshot.last_error = Some(error);
    })
    .await
}

async fn finish_done(inner: &QueueInner, id: &str, generation: u64, output: ModelOutput) {
    let summary = output_summary(&output);
    let logged = update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Done;
        snapshot.output = Some(output);
        snapshot.last_error = None;
    })
    .await;
    if logged {
        eprintln!("model job {id} done ({summary})");
    }
}

async fn finish_failed(inner: &QueueInner, id: &str, generation: u64, error: String) {
    let logged = update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Failed;
        snapshot.last_error = Some(error.clone());
    })
    .await;
    if logged {
        eprintln!("model job {id} failed: {error}");
    }
}

fn output_summary(output: &ModelOutput) -> String {
    match output {
        ModelOutput::Ocr { text } => format!("ocr, {} chars", text.chars().count()),
        ModelOutput::Asr { text, language } => match language {
            Some(language) if !language.is_empty() => {
                format!("asr/{language}, {} chars", text.chars().count())
            }
            _ => format!("asr, {} chars", text.chars().count()),
        },
        ModelOutput::Embedding { vector } => format!("embedding, {} dims", vector.len()),
        ModelOutput::Llm { text } => format!("llm, {} chars", text.chars().count()),
    }
}

async fn update_job(
    inner: &QueueInner,
    id: &str,
    generation: u64,
    update: impl FnOnce(&mut JobSnapshot),
) -> bool {
    let mut jobs = inner.jobs.lock().await;
    let Some(record) = jobs.get_mut(id) else {
        return false;
    };
    if record.generation != generation || record.snapshot.state == JobState::Cancelled {
        return false;
    }
    update(&mut record.snapshot);
    record.snapshot.updated_at_ms = unix_time_ms();
    drop(jobs);
    inner.changed.notify_waiters();
    true
}

fn unix_time_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestAdapter {
        failures_left: AtomicUsize,
        running: AtomicUsize,
        peak: AtomicUsize,
        delay: Duration,
    }

    #[async_trait]
    impl ModelAdapter for TestAdapter {
        fn capability(&self) -> ModelCapability {
            ModelCapability::Embedding
        }

        fn name(&self) -> &'static str {
            "test"
        }

        async fn execute(
            &self,
            _job_id: &str,
            _input: &ModelInput,
            cancellation: Cancellation,
        ) -> Result<ModelOutput, AdapterError> {
            let running = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak.fetch_max(running, Ordering::SeqCst);
            tokio::select! {
                () = cancellation.cancelled() => {
                    self.running.fetch_sub(1, Ordering::SeqCst);
                    return Err(AdapterError::Cancelled);
                }
                () = tokio::time::sleep(self.delay) => {}
            }
            self.running.fetch_sub(1, Ordering::SeqCst);
            if self
                .failures_left
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |value| {
                    value.checked_sub(1)
                })
                .is_ok()
            {
                return Err(AdapterError::Process("transient".to_owned()));
            }
            Ok(ModelOutput::Embedding { vector: vec![1.0] })
        }
    }

    fn queue(adapter: Arc<TestAdapter>, concurrency: usize, max_attempts: u32) -> ModelQueue {
        ModelQueue::new(
            vec![adapter as Arc<dyn ModelAdapter>],
            QueueConfig {
                max_attempts,
                retry_delay: Duration::from_millis(1),
                concurrency: CapabilityConcurrency {
                    embedding: concurrency,
                    ..CapabilityConcurrency::default()
                },
            },
        )
        .unwrap()
    }

    fn embedding_input() -> ModelInput {
        ModelInput::Embedding {
            text: "hello".to_owned(),
        }
    }

    #[tokio::test]
    async fn retries_transient_failure_until_done() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(1),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(1),
        });
        let queue = queue(adapter, 1, 3);
        let id = queue.submit(embedding_input()).await.unwrap();
        let job = queue.wait(&id).await.unwrap();
        assert_eq!(job.state, JobState::Done);
        assert_eq!(job.attempts, 2);
    }

    #[tokio::test]
    async fn respects_capability_concurrency() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(30),
        });
        let queue = queue(Arc::clone(&adapter), 2, 1);
        let mut ids = Vec::new();
        for _ in 0..6 {
            ids.push(queue.submit(embedding_input()).await.unwrap());
        }
        for id in ids {
            assert_eq!(queue.wait(&id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(adapter.peak.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn cancels_a_running_job_and_can_retry_it() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(100),
        });
        let queue = queue(adapter, 1, 1);
        let id = queue.submit(embedding_input()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert_eq!(queue.cancel(&id).await.unwrap().state, JobState::Cancelled);
        assert_eq!(queue.retry(&id).await.unwrap().state, JobState::Pending);
        assert_eq!(queue.wait(&id).await.unwrap().state, JobState::Done);
    }
}
