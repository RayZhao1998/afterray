use afterray_models::{
    JobState, ModelAdapter, ModelCapability, ModelInput, ModelOutput, ModelQueue, ProcessAdapter,
    ProcessAdapterConfig, QueueConfig,
};
use afterray_platform_macos::{
    ArtifactKind, CaptureConfig, CaptureError, CaptureEvent, MacOsCaptureBackend,
};
use afterray_protocol::{
    AppSettings, ArtifactPayload, PROTOCOL_VERSION, RecordingState, Request, Response, SearchHit,
    Status,
};
use afterray_store::{MacOsKeychainProvider, StoreError, Vault, VaultConfig, fuse_search_results};
use anyhow::Context;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Mutex,
    task::JoinHandle,
};
use uuid::Uuid;

fn default_socket_path() -> PathBuf {
    std::env::var_os("AFTERRAY_SOCKET").map_or_else(
        || std::env::temp_dir().join("afterray-v0.sock"),
        PathBuf::from,
    )
}

fn clear_stale_capture_files(staging_dir: &Path) -> std::io::Result<usize> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    std::fs::create_dir_all(staging_dir)?;
    #[cfg(unix)]
    std::fs::set_permissions(staging_dir, std::fs::Permissions::from_mode(0o700))?;
    let mut removed = 0;
    for entry in std::fs::read_dir(staging_dir)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_file() || file_type.is_symlink() {
            std::fs::remove_file(entry.path())?;
            removed += 1;
        }
    }
    Ok(removed)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let socket = default_socket_path();
    if socket.exists() {
        std::fs::remove_file(&socket).context("remove stale daemon socket")?;
    }
    let listener = UnixListener::bind(&socket).context("bind daemon socket")?;

    let mut vault_config = VaultConfig::default();
    if let Some(path) = std::env::var_os("AFTERRAY_DATA_DIR") {
        vault_config.data_dir = PathBuf::from(path);
    }
    if let Ok(value) = std::env::var("AFTERRAY_MAX_UNSTARRED_MOMENTS") {
        vault_config.max_unstarred_moments = value.parse().context("invalid retention limit")?;
    }
    let staging_dir = vault_config.data_dir.join("capture-staging");
    let removed_staging_files = clear_stale_capture_files(&staging_dir)?;
    if removed_staging_files > 0 {
        eprintln!("removed {removed_staging_files} stale capture staging file(s)");
    }
    let persisted = load_persisted_settings(&vault_config.data_dir);
    let data_dir = vault_config.data_dir.clone();
    let store = Arc::new(Vault::open(vault_config, &MacOsKeychainProvider)?);
    let repaired_sessions = store.close_orphaned_sessions_sync(now_ms())?;
    if repaired_sessions > 0 {
        eprintln!("closed {repaired_sessions} session(s) left open by an earlier daemon");
    }
    let shim_path = std::env::var_os("AFTERRAY_CAPTURE_SHIM").map_or_else(
        || PathBuf::from("apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim"),
        PathBuf::from,
    );
    let mut capture_config = CaptureConfig::new(shim_path, staging_dir.clone());
    capture_config.record_audio = persisted.record_audio;
    let capture = MacOsCaptureBackend::new(capture_config);

    let worker_path = std::env::var_os("AFTERRAY_MODEL_WORKER").map_or_else(
        || PathBuf::from("scripts/download-models/afterray_model_worker.py"),
        PathBuf::from,
    );
    let native_worker_path = std::env::var_os("AFTERRAY_NATIVE_MODEL_WORKER").map_or_else(
        || PathBuf::from(".build/release/afterray-native-model-worker"),
        PathBuf::from,
    );
    let models = ModelQueue::new(
        local_model_adapters(native_worker_path, worker_path),
        QueueConfig::default(),
    )?;

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let migration_store = Arc::clone(&store);
    let state = Arc::new(AppState {
        store,
        capture,
        models,
        recording: Mutex::new(RecordingRuntime::default()),
        capture_interval: Duration::from_secs(
            std::env::var("AFTERRAY_CAPTURE_INTERVAL_SECONDS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(10),
        ),
        data_dir,
        shutdown: shutdown_tx,
    });
    println!("afterrayd listening on {}", socket.display());
    tokio::task::spawn_blocking(move || match migration_store.run_artifact_maintenance() {
        Ok(0) => {}
        Ok(count) => eprintln!("migrated {count} legacy artifact(s) in the background"),
        Err(error) => eprintln!("background artifact maintenance paused: {error}"),
    });

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    if let Err(error) = handle(stream, state).await {
                        eprintln!("client error: {error:#}");
                    }
                });
            }
            () = &mut shutdown => break,
            changed = shutdown_rx.changed() => {
                if changed.is_ok() && *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }

    let response = record_stop(&state, None).await;
    if !response.ok {
        eprintln!(
            "could not finish the active session during shutdown: {}",
            response.error.as_deref().unwrap_or("unknown error")
        );
    }
    if let Err(error) = clear_stale_capture_files(&staging_dir) {
        eprintln!("could not clear capture staging during shutdown: {error}");
    }
    drop(listener);
    let _ = std::fs::remove_file(&socket);
    Ok(())
}

#[cfg(unix)]
async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};

    let mut terminate = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        result = tokio::signal::ctrl_c() => {
            if let Err(error) = result {
                eprintln!("Ctrl-C handler failed: {error}");
            }
        }
        _ = terminate.recv() => {}
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        eprintln!("Ctrl-C handler failed: {error}");
    }
}

fn local_model_adapters(
    native_worker: PathBuf,
    general_worker: PathBuf,
) -> Vec<Arc<dyn ModelAdapter>> {
    [
        (ModelCapability::Ocr, native_worker, "vision-ocr"),
        (
            ModelCapability::Asr,
            general_worker.clone(),
            "mlx-qwen3-asr",
        ),
        (
            ModelCapability::Embedding,
            general_worker.clone(),
            "llama-cpp-embedding",
        ),
        (ModelCapability::Llm, general_worker, "mlx-vlm"),
    ]
    .into_iter()
    .map(|(capability, program, name)| {
        Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
            name, capability, program,
        ))) as Arc<dyn ModelAdapter>
    })
    .collect()
}

struct AppState {
    store: Arc<Vault>,
    capture: Arc<MacOsCaptureBackend>,
    models: ModelQueue,
    recording: Mutex<RecordingRuntime>,
    capture_interval: Duration,
    data_dir: PathBuf,
    shutdown: tokio::sync::watch::Sender<bool>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct PersistedSettings {
    #[serde(default = "default_record_audio")]
    record_audio: bool,
}

const fn default_record_audio() -> bool {
    true
}

impl Default for PersistedSettings {
    fn default() -> Self {
        Self { record_audio: true }
    }
}

#[derive(Default)]
struct RecordingRuntime {
    active_session_id: Option<String>,
    scheduler: Option<JoinHandle<()>>,
    event_consumer: Option<JoinHandle<()>>,
}

async fn handle(stream: UnixStream, state: Arc<AppState>) -> anyhow::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        match serde_json::from_str::<Request>(&line) {
            Ok(Request::ReadArtifact { artifact_id }) => {
                write_artifact_response(&mut write, state.store.read_artifact(&artifact_id))
                    .await?;
            }
            Ok(request) => {
                write_json_response(&mut write, &dispatch(request, &state).await).await?;
            }
            Err(error) => {
                write_json_response(
                    &mut write,
                    &Response::failure(format!("invalid request: {error}")),
                )
                .await?;
            }
        }
    }
    Ok(())
}

async fn write_json_response(
    write: &mut tokio::net::unix::OwnedWriteHalf,
    response: &Response,
) -> anyhow::Result<()> {
    let mut encoded = serde_json::to_vec(response)?;
    encoded.push(b'\n');
    write.write_all(&encoded).await?;
    Ok(())
}

async fn write_artifact_response(
    write: &mut tokio::net::unix::OwnedWriteHalf,
    result: Result<ArtifactPayload, StoreError>,
) -> anyhow::Result<()> {
    match result {
        Ok(payload) => {
            write.write_all(&payload.header_line()?).await?;
            write.write_all(&payload.bytes).await?;
        }
        Err(error) => {
            write_json_response(write, &Response::failure(error.to_string())).await?;
        }
    }
    Ok(())
}

async fn dispatch(request: Request, state: &Arc<AppState>) -> Response {
    match request {
        Request::Ping => Response::success(serde_json::json!({"pong": true})),
        Request::Status => {
            let active_session_id = state.recording.lock().await.active_session_id.clone();
            Response::success(Status {
                daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
                protocol_version: PROTOCOL_VERSION,
                schema_version: afterray_store::SCHEMA_VERSION,
                recording_state: if active_session_id.is_some() {
                    RecordingState::Recording
                } else {
                    RecordingState::Idle
                },
                active_session_id,
            })
        }
        Request::RecordStart => record_start(state).await,
        Request::RecordStop { reason } => record_stop(state, reason.as_deref()).await,
        Request::SessionsList => into_response(state.store.sessions_sync()),
        Request::TimelineList => into_response(state.store.timeline_sync()),
        Request::TimelineSince { since_ms } => {
            into_response(state.store.timeline_since_sync(since_ms))
        }
        Request::MomentsList { session_id } => into_response(state.store.moments_sync(&session_id)),
        Request::RecallWindow {
            session_id,
            center_ms,
            limit,
        } => match state.store.moments_sync(&session_id) {
            Ok(mut moments) => {
                moments.sort_by_key(|moment| moment.captured_at_ms.abs_diff(center_ms));
                moments.truncate(limit.clamp(1, 500));
                moments.sort_by_key(|moment| moment.captured_at_ms);
                Response::success(moments)
            }
            Err(error) => Response::failure(error.to_string()),
        },
        Request::ReadArtifact { .. } => Response::failure(
            "read_artifact is framed as a JSON header plus raw bytes and is handled separately",
        ),
        Request::FavoriteSet {
            moment_id,
            favorite,
        } => match state.store.set_favorite(&moment_id, favorite) {
            Ok(()) => Response::success(
                serde_json::json!({"moment_id": moment_id, "is_favorite": favorite}),
            ),
            Err(error) => Response::failure(error.to_string()),
        },
        Request::Search { query, limit } => {
            match search_hits(&state.store, &state.models, &query, limit.clamp(1, 100)).await {
                Ok(hits) => Response::success(hits),
                Err(error) => Response::failure(error.to_string()),
            }
        }
        Request::ModelsStatus => Response::success(model_library()),
        Request::JobsList => Response::success(state.models.list().await),
        Request::JobRetry { job_id } => match state.models.retry(&job_id).await {
            Ok(snapshot) => Response::success(snapshot),
            Err(error) => Response::failure(error.to_string()),
        },
        Request::Summarize { session_id } => summarize(state, &session_id).await,
        Request::Settings => Response::success(current_settings(state)),
        Request::UpdateSettings { record_audio } => update_settings(state, record_audio).await,
        Request::Shutdown => {
            let _ = state.shutdown.send(true);
            Response::success(serde_json::json!({
                "stopping": true,
                "pid": std::process::id(),
            }))
        }
    }
}

async fn record_start(state: &Arc<AppState>) -> Response {
    let _ = state.store.end_open_idle_spans(now_ms());
    let mut recording = state.recording.lock().await;
    if let Some(id) = &recording.active_session_id {
        eprintln!("record_start: already recording session {id}");
        return Response::success(serde_json::json!({"session_id": id, "already_recording": true}));
    }
    let session = match state.store.create_session_sync(now_ms()) {
        Ok(session) => session,
        Err(error) => {
            eprintln!("record_start: failed to create session: {error}");
            return Response::failure(error.to_string());
        }
    };
    eprintln!(
        "record_start: session {} audio={}",
        session.id,
        state.capture.record_audio()
    );
    recording.active_session_id = Some(session.id.clone());
    drop(recording);
    if let Err(error) = start_capture_runtime(state, session.id.clone()).await {
        eprintln!("record_start: capture runtime failed: {error}");
        let _ = state.store.end_session_sync(&session.id, now_ms());
        let mut recording = state.recording.lock().await;
        if recording.active_session_id.as_deref() == Some(session.id.as_str()) {
            recording.active_session_id = None;
        }
        return Response::failure(error);
    }
    eprintln!("record_start: session {} is recording", session.id);
    Response::success(serde_json::json!({"session": session}))
}

async fn start_capture_runtime(state: &Arc<AppState>, session_id: String) -> Result<(), String> {
    const READY_TIMEOUT: Duration = Duration::from_secs(30);
    if let Err(error) = state.capture.start_capture().await {
        eprintln!("capture runtime: start_capture failed: {error}");
        return Err(error.to_string());
    }
    eprintln!(
        "capture runtime: waiting up to {}s for shim ready (session {session_id})",
        READY_TIMEOUT.as_secs()
    );
    match tokio::time::timeout(READY_TIMEOUT, state.capture.next_event()).await {
        Ok(Some(Ok(CaptureEvent::Ready {
            display_id,
            width,
            height,
        }))) => {
            eprintln!("capture runtime: shim ready display={display_id} {width}x{height}");
        }
        Ok(Some(Ok(CaptureEvent::Failed { code, message }))) => {
            let _ = state.capture.stop_capture().await;
            return Err(format!("capture startup failed [{code}]: {message}"));
        }
        Ok(Some(Ok(event))) => {
            let _ = state.capture.stop_capture().await;
            return Err(format!(
                "capture helper returned {event:?} before it was ready"
            ));
        }
        Ok(Some(Err(error))) => {
            let _ = state.capture.stop_capture().await;
            return Err(error.to_string());
        }
        Ok(None) => {
            let _ = state.capture.stop_capture().await;
            return Err("capture helper exited before it was ready".to_owned());
        }
        Err(_) => {
            let _ = state.capture.stop_capture().await;
            return Err("capture helper did not become ready within 30 seconds".to_owned());
        }
    }

    let capture = Arc::clone(&state.capture);
    let interval = state.capture_interval;
    let scheduler = tokio::spawn(async move {
        let mut timer = tokio::time::interval(interval);
        loop {
            timer.tick().await;
            let request_id = Uuid::now_v7().to_string();
            if let Err(error) = capture.capture_screen(&request_id).await {
                eprintln!("capture request failed: {error}");
                break;
            }
        }
    });

    let event_state = Arc::clone(state);
    let consumer_session = session_id.clone();
    let event_consumer = tokio::spawn(async move {
        consume_capture_events(event_state, consumer_session).await;
    });
    let mut recording = state.recording.lock().await;
    if recording.active_session_id.as_deref() != Some(session_id.as_str()) {
        scheduler.abort();
        let _ = state.capture.stop_capture().await;
        return Ok(());
    }
    recording.scheduler = Some(scheduler);
    recording.event_consumer = Some(event_consumer);
    Ok(())
}

async fn restart_capture_runtime(state: &Arc<AppState>) -> Result<(), String> {
    let (session_id, consumer) = {
        let mut recording = state.recording.lock().await;
        let Some(session_id) = recording.active_session_id.clone() else {
            return Ok(());
        };
        if let Some(scheduler) = recording.scheduler.take() {
            scheduler.abort();
        }
        (session_id, recording.event_consumer.take())
    };
    match state.capture.stop_capture().await {
        Ok(()) | Err(CaptureError::NotRunning) => {}
        Err(error) => return Err(error.to_string()),
    }
    if let Some(consumer) = consumer {
        let _ = tokio::time::timeout(Duration::from_secs(12), consumer).await;
    }
    start_capture_runtime(state, session_id).await
}

fn current_settings(state: &AppState) -> AppSettings {
    AppSettings {
        data_dir: state.data_dir.display().to_string(),
        model_dir: default_model_dir().display().to_string(),
        record_audio: state.capture.record_audio(),
        capture_interval_seconds: state.capture_interval.as_secs(),
    }
}

async fn update_settings(state: &Arc<AppState>, record_audio: Option<bool>) -> Response {
    if let Some(enabled) = record_audio {
        let previous = state.capture.record_audio();
        state.capture.set_record_audio(enabled);
        if let Err(error) = save_persisted_settings(
            &state.data_dir,
            &PersistedSettings {
                record_audio: enabled,
            },
        ) {
            state.capture.set_record_audio(previous);
            return Response::failure(format!("could not save settings: {error}"));
        }
        if previous != enabled
            && let Err(error) = restart_capture_runtime(state).await
        {
            return Response::failure(format!(
                "audio preference saved, but capture could not restart: {error}"
            ));
        }
    }
    Response::success(current_settings(state))
}

fn settings_path(data_dir: &Path) -> PathBuf {
    data_dir.join("settings.json")
}

fn load_persisted_settings(data_dir: &Path) -> PersistedSettings {
    let Ok(text) = std::fs::read_to_string(settings_path(data_dir)) else {
        return PersistedSettings::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save_persisted_settings(data_dir: &Path, settings: &PersistedSettings) -> std::io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    std::fs::write(
        settings_path(data_dir),
        serde_json::to_vec_pretty(settings)?,
    )
}

async fn record_stop(state: &Arc<AppState>, reason: Option<&str>) -> Response {
    let _ = state
        .store
        .begin_idle_span(now_ms(), reason.unwrap_or("pause"));
    let (session_id, scheduler, consumer) = {
        let mut recording = state.recording.lock().await;
        let Some(session_id) = recording.active_session_id.take() else {
            return Response::success(serde_json::json!({"already_stopped": true}));
        };
        (
            session_id,
            recording.scheduler.take(),
            recording.event_consumer.take(),
        )
    };
    if let Some(scheduler) = scheduler {
        scheduler.abort();
    }
    let capture_error = state.capture.stop_capture().await.err();
    if let Some(consumer) = consumer {
        let _ = tokio::time::timeout(Duration::from_secs(12), consumer).await;
    }
    let store_result = state.store.end_session_sync(&session_id, now_ms());
    match (capture_error, store_result) {
        (None, Ok(())) => Response::success(serde_json::json!({"session_id": session_id})),
        (Some(capture_error), Ok(())) => Response::failure(format!(
            "session closed, but capture helper did not stop cleanly: {capture_error}"
        )),
        (None, Err(store_error)) => Response::failure(store_error.to_string()),
        (Some(capture_error), Err(store_error)) => Response::failure(format!(
            "capture stop failed: {capture_error}; session close failed: {store_error}"
        )),
    }
}

async fn consume_capture_events(state: Arc<AppState>, session_id: String) {
    while let Some(event) = state.capture.next_event().await {
        match event {
            Ok(CaptureEvent::Ready { .. }) => {}
            Ok(CaptureEvent::Artifact {
                kind,
                path,
                content_type,
                started_at_ms,
                ended_at_ms,
                ..
            }) => {
                let result = import_artifact(
                    &state,
                    &session_id,
                    kind,
                    &path,
                    &content_type,
                    started_at_ms,
                    ended_at_ms,
                )
                .await;
                if let Err(error) = result {
                    eprintln!("capture artifact import failed: {error:#}");
                    let _ = tokio::fs::remove_file(&path).await;
                }
            }
            Ok(CaptureEvent::Warning { code, message }) => {
                eprintln!("capture warning [{code}]: {message}");
            }
            Ok(CaptureEvent::Failed { code, message }) => {
                eprintln!("capture failed [{code}]: {message}");
                finish_failed_recording(&state, &session_id).await;
                break;
            }
            Ok(CaptureEvent::Stopped) => break,
            Err(error) => {
                eprintln!("capture event stream failed: {error}");
                finish_failed_recording(&state, &session_id).await;
                break;
            }
        }
    }
}

async fn finish_failed_recording(state: &Arc<AppState>, session_id: &str) {
    let scheduler = {
        let mut recording = state.recording.lock().await;
        if recording.active_session_id.as_deref() != Some(session_id) {
            return;
        }
        recording.active_session_id = None;
        recording.scheduler.take()
    };
    if let Some(scheduler) = scheduler {
        scheduler.abort();
    }
    let _ = state.store.end_session_sync(session_id, now_ms());
}

async fn import_artifact(
    state: &Arc<AppState>,
    session_id: &str,
    kind: ArtifactKind,
    path: &Path,
    content_type: &str,
    started_at_ms: i64,
    ended_at_ms: i64,
) -> anyhow::Result<()> {
    let bytes = tokio::fs::read(path).await?;
    match kind {
        ArtifactKind::Screen => {
            let moment =
                state
                    .store
                    .insert_moment(session_id, started_at_ms, content_type, &bytes)?;
            let job = state
                .models
                .submit(ModelInput::Ocr {
                    image_path: path.to_path_buf(),
                    prompt: None,
                })
                .await?;
            let model_state = Arc::clone(state);
            let path = path.to_path_buf();
            tokio::spawn(async move {
                let snapshot = model_state.models.wait(&job).await;
                if let Ok(snapshot) = snapshot
                    && let Some(ModelOutput::Ocr { text }) = snapshot.output
                    && let Ok(evidence_id) = model_state.store.insert_text_evidence(
                        &moment.session_id,
                        Some(&moment.id),
                        None,
                        "ocr",
                        &text,
                        moment.captured_at_ms,
                        None,
                        &snapshot.adapter,
                    )
                {
                    submit_embedding(&model_state, evidence_id, text).await;
                }
                let _ = tokio::fs::remove_file(path).await;
            });
        }
        ArtifactKind::SystemAudio | ArtifactKind::Microphone => {
            let track = match kind {
                ArtifactKind::Microphone => afterray_protocol::AudioTrack::Microphone,
                ArtifactKind::SystemAudio | ArtifactKind::Screen | ArtifactKind::Accessibility => {
                    afterray_protocol::AudioTrack::System
                }
            };
            let segment = state.store.insert_audio_segment(
                session_id,
                track,
                started_at_ms,
                ended_at_ms,
                content_type,
                &bytes,
            )?;
            let job = state
                .models
                .submit(ModelInput::Asr {
                    audio_path: path.to_path_buf(),
                    language: None,
                })
                .await?;
            let model_state = Arc::clone(state);
            let path = path.to_path_buf();
            tokio::spawn(async move {
                let snapshot = model_state.models.wait(&job).await;
                if let Ok(snapshot) = snapshot
                    && let Some(ModelOutput::Asr { text, .. }) = snapshot.output
                    && let Ok(evidence_id) = model_state.store.insert_text_evidence(
                        &segment.session_id,
                        None,
                        Some(&segment.id),
                        "transcript",
                        &text,
                        segment.started_at_ms,
                        Some(segment.ended_at_ms),
                        &snapshot.adapter,
                    )
                {
                    submit_embedding(&model_state, evidence_id, text).await;
                }
                let _ = tokio::fs::remove_file(path).await;
            });
        }
        ArtifactKind::Accessibility => {
            let attached = attach_accessibility_artifact(
                &state.store,
                session_id,
                started_at_ms,
                content_type,
                &bytes,
            )?;
            if attached.is_none() {
                eprintln!(
                    "accessibility snapshot had no screen moment within the two-second alignment window"
                );
            }
            tokio::fs::remove_file(path).await?;
        }
    }
    Ok(())
}

#[derive(Default, serde::Deserialize)]
struct AccessibilityMetadata {
    application_name: Option<String>,
    bundle_identifier: Option<String>,
}

fn attach_accessibility_artifact(
    store: &Vault,
    session_id: &str,
    captured_at_ms: i64,
    content_type: &str,
    bytes: &[u8],
) -> Result<Option<String>, StoreError> {
    let metadata = serde_json::from_slice::<AccessibilityMetadata>(bytes).unwrap_or_default();
    store.attach_accessibility_snapshot(
        session_id,
        captured_at_ms,
        content_type,
        bytes,
        metadata.application_name.as_deref(),
        metadata.bundle_identifier.as_deref(),
    )
}

async fn submit_embedding(state: &Arc<AppState>, evidence_id: String, text: String) {
    let Ok(job_id) = state.models.submit(ModelInput::Embedding { text }).await else {
        return;
    };
    let Ok(snapshot) = state.models.wait(&job_id).await else {
        return;
    };
    if snapshot.state == JobState::Done
        && let Some(ModelOutput::Embedding { vector }) = snapshot.output
    {
        let _ = state
            .store
            .insert_embedding(&evidence_id, &vector, &snapshot.adapter);
    }
}

async fn search_hits(
    store: &Vault,
    models: &ModelQueue,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>, StoreError> {
    let candidate_limit = limit.saturating_mul(4).clamp(limit, 400);
    let full_text = match store.search(query, candidate_limit) {
        Ok(hits) => hits,
        Err(error) => {
            eprintln!("full-text search unavailable; continuing with semantic search: {error}");
            Vec::new()
        }
    };
    let job_id = match models
        .submit(ModelInput::Embedding {
            text: query.to_owned(),
        })
        .await
    {
        Ok(job_id) => job_id,
        Err(error) => {
            eprintln!("semantic search unavailable; returning FTS results: {error}");
            return Ok(limit_hits(full_text, limit));
        }
    };
    let snapshot = match models.wait(&job_id).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!(
                "semantic search job {job_id} could not be read; returning FTS results: {error}"
            );
            return Ok(limit_hits(full_text, limit));
        }
    };
    let ModelOutput::Embedding { vector } = (match snapshot.output {
        Some(output) if snapshot.state == JobState::Done => output,
        _ => {
            eprintln!(
                "semantic search job {job_id} did not complete; returning FTS results: {}",
                snapshot
                    .last_error
                    .unwrap_or_else(|| format!("state was {:?}", snapshot.state))
            );
            return Ok(limit_hits(full_text, limit));
        }
    }) else {
        eprintln!(
            "semantic search job {job_id} returned the wrong output type; returning FTS results"
        );
        return Ok(limit_hits(full_text, limit));
    };
    let semantic = match store.semantic_search(&vector, &snapshot.adapter, candidate_limit) {
        Ok(hits) => hits,
        Err(error) => {
            eprintln!("semantic search scoring failed; returning FTS results: {error}");
            return Ok(limit_hits(full_text, limit));
        }
    };
    Ok(fuse_search_results(full_text, semantic, limit))
}

fn limit_hits(mut hits: Vec<SearchHit>, limit: usize) -> Vec<SearchHit> {
    hits.truncate(limit);
    hits
}

async fn summarize(state: &Arc<AppState>, session_id: &str) -> Response {
    let text = match state.store.session_text(session_id) {
        Ok(text) if !text.is_empty() => text,
        Ok(_) => return Response::failure("the session has no OCR or transcript evidence yet"),
        Err(error) => return Response::failure(error.to_string()),
    };
    let prompt =
        format!("Summarize this local computer activity with concrete evidence:\n\n{text}");
    let job_id = match state
        .models
        .submit(ModelInput::Llm {
            prompt,
            system: Some(
                "You are AfterRay. Be concise and never invent missing evidence.".to_owned(),
            ),
        })
        .await
    {
        Ok(id) => id,
        Err(error) => return Response::failure(error.to_string()),
    };
    match state.models.wait(&job_id).await {
        Ok(snapshot) if snapshot.state == JobState::Done => Response::success(snapshot),
        Ok(snapshot) => Response::failure(
            snapshot
                .last_error
                .unwrap_or_else(|| "summary job did not complete".to_owned()),
        ),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn model_library() -> afterray_protocol::ModelLibrary {
    let directory = default_model_dir();
    afterray_protocol::ModelLibrary {
        directory: directory.display().to_string(),
        packs: vec![
            inspect_pack(
                "asr",
                "Qwen3 ASR",
                "asr",
                env_or_join("AFTERRAY_ASR_MODEL", &directory, "Qwen3-ASR-1.7B-8bit"),
                true,
                Some("mlx-community/Qwen3-ASR-1.7B-8bit · ~2.5 GB · ZH/EN/JA"),
                Some(2_460_000_000),
            ),
            inspect_pack(
                "asr-whisper",
                "Whisper ASR (fallback)",
                "asr",
                env_or_join(
                    "AFTERRAY_WHISPER_MODEL",
                    &directory,
                    "ggml-large-v3-turbo-q5_0.bin",
                ),
                false,
                Some("optional whisper.cpp large-v3-turbo q5 · AFTERRAY_ASR_BACKEND=whisper"),
                Some(547_000_000),
            ),
            inspect_pack(
                "embedding",
                "Text embeddings",
                "embedding",
                env_or_join(
                    "AFTERRAY_EMBEDDING_MODEL",
                    &directory,
                    "nomic-embed-text-v1.5.Q4_K_M.gguf",
                ),
                true,
                Some("nomic-embed-text v1.5 Q4"),
                Some(84_000_000),
            ),
            inspect_pack(
                "llm",
                "Local LLM",
                "llm",
                env_or_join("AFTERRAY_LLM_MODEL", &directory, "gemma-4-26b-a4b-it-4bit"),
                false,
                Some("Gemma 4 26B-A4B 4bit · about 15 GB"),
                Some(15_000_000_000),
            ),
        ],
    }
}

fn default_model_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("AFTERRAY_MODEL_DIR") {
        return PathBuf::from(path);
    }
    if let Some(path) = std::env::var_os("AFTERRAY_ASR_MODEL") {
        if let Some(parent) = Path::new(&path).parent() {
            return parent.to_path_buf();
        }
    }
    if let Some(path) = std::env::var_os("AFTERRAY_WHISPER_MODEL") {
        if let Some(parent) = Path::new(&path).parent() {
            return parent.to_path_buf();
        }
    }
    if let Some(path) = std::env::var_os("AFTERRAY_DATA_DIR") {
        let data = PathBuf::from(path);
        if let Some(parent) = data.parent() {
            return parent.join("models");
        }
    }
    PathBuf::from(".afterray/models")
}

fn env_or_join(key: &str, directory: &Path, file_name: &str) -> PathBuf {
    std::env::var_os(key)
        .map(PathBuf::from)
        .unwrap_or_else(|| directory.join(file_name))
}

fn inspect_pack(
    id: &str,
    name: &str,
    capability: &str,
    path: PathBuf,
    required: bool,
    note: Option<&str>,
    expected_bytes: Option<u64>,
) -> afterray_protocol::ModelPack {
    let (present, bytes) = inspect_model_path(&path);
    afterray_protocol::ModelPack {
        id: id.to_owned(),
        name: name.to_owned(),
        capability: capability.to_owned(),
        path: path.display().to_string(),
        present,
        bytes,
        required,
        note: note.map(ToOwned::to_owned),
        expected_bytes,
    }
}

fn inspect_model_path(path: &Path) -> (bool, u64) {
    if path.is_file() {
        return (
            true,
            std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0),
        );
    }
    if path.is_dir() {
        return (true, directory_size(path));
    }
    (false, 0)
}

fn directory_size(path: &Path) -> u64 {
    let mut total = 0;
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            total += directory_size(&path);
        } else if let Ok(meta) = entry.metadata() {
            total += meta.len();
        }
    }
    total
}

fn into_response<T: serde::Serialize, E: std::fmt::Display>(result: Result<T, E>) -> Response {
    match result {
        Ok(data) => Response::success(data),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn now_ms() -> i64 {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_models::{ModelAdapter, ModelCapability, ProcessAdapter, ProcessAdapterConfig};
    use tokio::io::AsyncReadExt;

    #[test]
    fn stale_capture_cleanup_only_removes_files() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("screen.jpg"), b"frame").unwrap();
        std::fs::write(directory.path().join("microphone.m4a"), b"audio").unwrap();
        std::fs::create_dir(directory.path().join("unexpected-directory")).unwrap();

        assert_eq!(clear_stale_capture_files(directory.path()).unwrap(), 2);
        assert!(directory.path().join("unexpected-directory").is_dir());
        assert_eq!(clear_stale_capture_files(directory.path()).unwrap(), 0);
    }

    fn test_vault() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_unstarred_moments: 100,
            },
            [9_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    fn queue(adapters: Vec<Arc<dyn ModelAdapter>>) -> ModelQueue {
        ModelQueue::new(adapters, QueueConfig::default()).unwrap()
    }

    #[tokio::test]
    async fn search_returns_fts_when_embedding_adapter_is_unavailable() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "needle in local memory",
                1,
                None,
                "ocr-model",
            )
            .unwrap();

        let hits = search_hits(&vault, &queue(Vec::new()), "needle", 10)
            .await
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].text, "needle in local memory");
    }

    #[tokio::test]
    async fn search_embeds_query_and_fuses_semantic_results() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let exact_id = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "needle exact words",
                1,
                None,
                "ocr-model",
            )
            .unwrap();
        let semantic_id = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "conceptual local context",
                2,
                None,
                "ocr-model",
            )
            .unwrap();
        vault
            .insert_embedding(&exact_id, &[0.0, 1.0], "test-embedding")
            .unwrap();
        vault
            .insert_embedding(&semantic_id, &[1.0, 0.0], "test-embedding")
            .unwrap();

        let script = r#"
import json, sys
json.load(sys.stdin)
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "embedding", "vector": [1.0, 0.0]},
  "retryable": False
}))
"#;
        let mut config = ProcessAdapterConfig::new(
            "test-embedding",
            ModelCapability::Embedding,
            "/usr/bin/python3",
        );
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let models = queue(vec![Arc::new(ProcessAdapter::new(config))]);
        let hits = search_hits(&vault, &models, "needle", 10).await.unwrap();

        assert_eq!(hits.len(), 2);
        assert!(hits.iter().any(|hit| hit.text == "needle exact words"));
        assert!(
            hits.iter()
                .any(|hit| hit.text == "conceptual local context")
        );
    }

    #[tokio::test]
    async fn read_artifact_writes_json_header_then_raw_bytes() {
        let payload = ArtifactPayload {
            id: "a1".to_owned(),
            content_type: "image/jpeg".to_owned(),
            bytes: b"raw-jpeg".to_vec(),
        };
        let (server, client) = UnixStream::pair().unwrap();
        let (_ignored, mut write) = server.into_split();
        write_artifact_response(&mut write, Ok(payload))
            .await
            .unwrap();
        drop(write);

        let (read, _unused) = client.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: Response = serde_json::from_str(&line).unwrap();
        assert!(response.ok);
        let meta: afterray_protocol::ArtifactMeta =
            serde_json::from_value(response.data.unwrap()).unwrap();
        assert_eq!(meta.id, "a1");
        assert_eq!(meta.content_type, "image/jpeg");
        assert_eq!(meta.byte_length, 8);
        let mut body = vec![0_u8; 8];
        reader.read_exact(&mut body).await.unwrap();
        assert_eq!(body, b"raw-jpeg");
    }

    #[tokio::test]
    async fn missing_artifact_writes_json_error_without_body() {
        let (server, client) = UnixStream::pair().unwrap();
        let (_ignored, mut write) = server.into_split();
        write_artifact_response(
            &mut write,
            Err(StoreError::ArtifactNotFound("missing".into())),
        )
        .await
        .unwrap();
        drop(write);

        let (read, _unused) = client.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: Response = serde_json::from_str(&line).unwrap();
        assert!(!response.ok);
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).await.unwrap();
        assert!(rest.is_empty());
    }
}
