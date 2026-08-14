use afterray_models::{JobState, ModelInput, ModelOutput, ModelQueue};
use afterray_protocol::Memory;
use afterray_store::{
    AccessibilityDigest, Vault, digest_fingerprint, is_idle_digest, parse_accessibility_digest,
};
use std::sync::Mutex;
use uuid::Uuid;

const MIN_MEMORY_MS: i64 = 45_000;

const MEMORY_SYSTEM_PROMPT: &str = "You write one or two short sentences about what a person \
was doing on their Mac. Use only the accessibility evidence. Do not invent files, URLs, or tasks. \
Do not mention idle time, the desktop, or AfterRay itself.";

#[derive(Debug, Clone)]
struct OpenEpisode {
    start_ms: i64,
    last_ms: i64,
    moment_id: String,
    digest: AccessibilityDigest,
    fingerprint: String,
}

#[derive(Default)]
pub(crate) struct MemoryRuntime {
    open: Option<OpenEpisode>,
}

impl MemoryRuntime {
    fn observe(
        &mut self,
        store: &Vault,
        captured_at_ms: i64,
        moment_id: &str,
        digest: AccessibilityDigest,
    ) -> Option<OpenEpisode> {
        if is_idle_digest(&digest) {
            return self.open.take();
        }
        let fingerprint = digest_fingerprint(&digest);
        if let Some(latest) = store.latest_memory().ok().flatten()
            && latest.fingerprint == fingerprint
        {
            if let Some(open) = &mut self.open {
                open.last_ms = captured_at_ms.max(open.last_ms);
                open.moment_id = moment_id.to_owned();
            }
            return None;
        }
        match self.open.take() {
            Some(mut open) if open.digest.identity_key() == digest.identity_key() => {
                open.last_ms = captured_at_ms.max(open.last_ms);
                open.moment_id = moment_id.to_owned();
                open.digest = digest;
                open.fingerprint = fingerprint;
                self.open = Some(open);
                None
            }
            Some(previous) => {
                self.open = Some(OpenEpisode {
                    start_ms: captured_at_ms,
                    last_ms: captured_at_ms,
                    moment_id: moment_id.to_owned(),
                    digest,
                    fingerprint,
                });
                Some(previous)
            }
            None => {
                self.open = Some(OpenEpisode {
                    start_ms: captured_at_ms,
                    last_ms: captured_at_ms,
                    moment_id: moment_id.to_owned(),
                    digest,
                    fingerprint,
                });
                None
            }
        }
    }

    fn close(&mut self) -> Option<OpenEpisode> {
        self.open.take()
    }
}

pub(crate) async fn observe_and_maybe_commit(
    store: &Vault,
    models: &ModelQueue,
    runtime: &Mutex<MemoryRuntime>,
    captured_at_ms: i64,
    moment_id: &str,
    snapshot: &[u8],
    llm_present: bool,
) {
    let digest = parse_accessibility_digest(snapshot);
    let closed = runtime
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .observe(store, captured_at_ms, moment_id, digest);
    if let Some(episode) = closed {
        commit_episode(store, models, episode, llm_present).await;
    }
}

pub(crate) async fn flush(
    store: &Vault,
    models: &ModelQueue,
    runtime: &Mutex<MemoryRuntime>,
    llm_present: bool,
) {
    let closed = runtime
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .close();
    if let Some(episode) = closed {
        commit_episode(store, models, episode, llm_present).await;
    }
}

async fn commit_episode(
    store: &Vault,
    models: &ModelQueue,
    episode: OpenEpisode,
    llm_present: bool,
) {
    if episode.last_ms.saturating_sub(episode.start_ms) < MIN_MEMORY_MS {
        return;
    }
    if let Some(latest) = store.latest_memory().ok().flatten()
        && latest.fingerprint == episode.fingerprint
    {
        return;
    }
    let summary = if llm_present {
        summarize_episode(models, &episode)
            .await
            .unwrap_or_else(|| episode.digest.fallback_summary())
    } else {
        episode.digest.fallback_summary()
    };
    let memory = Memory {
        id: Uuid::now_v7().to_string(),
        start_ms: episode.start_ms,
        end_ms: episode.last_ms.max(episode.start_ms + MIN_MEMORY_MS),
        moment_id: Some(episode.moment_id),
        application_name: episode.digest.application_name,
        bundle_identifier: episode.digest.bundle_identifier,
        window_title: episode.digest.window_title,
        url: episode.digest.url,
        document: episode.digest.document,
        summary,
        fingerprint: episode.fingerprint,
    };
    if let Err(error) = store.insert_memory(&memory) {
        eprintln!("could not store memory: {error}");
    }
}

async fn summarize_episode(models: &ModelQueue, episode: &OpenEpisode) -> Option<String> {
    let minutes = ((episode.last_ms - episode.start_ms).max(1) + 30_000) / 60_000;
    let prompt = format!(
        "Duration: {minutes} minute(s)\n{}",
        episode.digest.compact_text()
    );
    let job_id = models
        .submit(ModelInput::Llm {
            prompt,
            system: Some(MEMORY_SYSTEM_PROMPT.to_owned()),
        })
        .await
        .ok()?;
    let snapshot = models.wait(&job_id).await.ok()?;
    if snapshot.state != JobState::Done {
        return None;
    }
    match snapshot.output {
        Some(ModelOutput::Llm { text }) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_owned())
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_store::{Vault, VaultConfig};

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

    #[test]
    fn duplicate_fingerprint_does_not_reopen() {
        let (_dir, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"one")
            .unwrap();
        let digest = AccessibilityDigest {
            application_name: Some("Safari".into()),
            bundle_identifier: Some("com.apple.Safari".into()),
            window_title: Some("Example".into()),
            url: Some("https://example.com/".into()),
            ..AccessibilityDigest::default()
        };
        vault
            .insert_memory(&Memory {
                id: "mem1".into(),
                start_ms: 0,
                end_ms: 60_000,
                moment_id: Some(first.id.clone()),
                application_name: digest.application_name.clone(),
                bundle_identifier: digest.bundle_identifier.clone(),
                window_title: digest.window_title.clone(),
                url: digest.url.clone(),
                document: None,
                summary: "Used Safari.".into(),
                fingerprint: digest_fingerprint(&digest),
            })
            .unwrap();
        let mut runtime = MemoryRuntime::default();
        let closed = runtime.observe(&vault, 70_000, &first.id, digest);
        assert!(closed.is_none());
    }
}
