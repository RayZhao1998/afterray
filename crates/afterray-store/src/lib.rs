#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::needless_pass_by_value,
    clippy::too_many_arguments,
    clippy::cast_possible_truncation
)]

use afterray_core::{CoreError, Store};
use afterray_protocol::{ArtifactPayload, AudioSegment, AudioTrack, Moment, SearchHit, Session};
use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use std::{collections::HashMap, fs, path::PathBuf, process::Command, sync::Mutex};
use uuid::Uuid;

pub const SCHEMA_VERSION: u32 = 3;
const ARTIFACT_MAGIC: &[u8; 4] = b"ARV0";
const KEYCHAIN_SERVICE: &str = "dev.afterray.v0.vault";

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("crypto operation failed")]
    Crypto,
    #[error("invalid vault key")]
    InvalidKey,
    #[error("artifact not found: {0}")]
    ArtifactNotFound(String),
    #[error("key provider: {0}")]
    KeyProvider(String),
    #[error("invalid embedding: {0}")]
    InvalidEmbedding(String),
}

pub trait KeyProvider: Send + Sync {
    fn load_or_create(&self) -> Result<[u8; 32], StoreError>;
}

#[derive(Debug, Default)]
pub struct MacOsKeychainProvider;

impl KeyProvider for MacOsKeychainProvider {
    fn load_or_create(&self) -> Result<[u8; 32], StoreError> {
        let account = std::env::var("USER").unwrap_or_else(|_| "afterray".to_owned());
        let existing = Command::new("/usr/bin/security")
            .args([
                "find-generic-password",
                "-a",
                &account,
                "-s",
                KEYCHAIN_SERVICE,
                "-w",
            ])
            .output()?;
        if existing.status.success() {
            return decode_key(String::from_utf8_lossy(&existing.stdout).trim());
        }

        let mut key = [0_u8; 32];
        rand::rng().fill_bytes(&mut key);
        let encoded = BASE64.encode(key);
        let status = Command::new("/usr/bin/security")
            .args([
                "add-generic-password",
                "-U",
                "-a",
                &account,
                "-s",
                KEYCHAIN_SERVICE,
                "-w",
                &encoded,
            ])
            .status()?;
        if !status.success() {
            return Err(StoreError::KeyProvider(
                "unable to create the AfterRay keychain item".to_owned(),
            ));
        }
        Ok(key)
    }
}

fn decode_key(value: &str) -> Result<[u8; 32], StoreError> {
    let decoded = BASE64.decode(value).map_err(|_| StoreError::InvalidKey)?;
    decoded.try_into().map_err(|_| StoreError::InvalidKey)
}

#[derive(Debug, Clone)]
pub struct VaultConfig {
    pub data_dir: PathBuf,
    pub max_unstarred_moments: usize,
}

impl Default for VaultConfig {
    fn default() -> Self {
        Self {
            data_dir: default_data_dir(),
            max_unstarred_moments: 10_000,
        }
    }
}

pub struct Vault {
    connection: Mutex<Connection>,
    artifacts_dir: PathBuf,
    key: [u8; 32],
    max_unstarred_moments: usize,
}

impl Vault {
    pub fn open(config: VaultConfig, provider: &dyn KeyProvider) -> Result<Self, StoreError> {
        let key = provider.load_or_create()?;
        Self::open_with_key(config, key)
    }

    pub fn open_with_key(config: VaultConfig, key: [u8; 32]) -> Result<Self, StoreError> {
        fs::create_dir_all(&config.data_dir)?;
        let artifacts_dir = config.data_dir.join("artifacts");
        fs::create_dir_all(&artifacts_dir)?;
        let connection = Connection::open(config.data_dir.join("afterray.sqlite3"))?;
        let sql_key = encode_hex(&key);
        connection.execute_batch(&format!(
            "PRAGMA key = \"x'{sql_key}'\"; PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;"
        ))?;
        let cipher_version: Option<String> = connection
            .query_row("PRAGMA cipher_version", [], |row| row.get(0))
            .optional()?;
        if cipher_version.as_deref().is_none_or(str::is_empty) {
            return Err(StoreError::InvalidKey);
        }
        migrate(&connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
            artifacts_dir,
            key,
            max_unstarred_moments: config.max_unstarred_moments,
        })
    }

    pub fn create_session_sync(&self, started_at_ms: i64) -> Result<Session, StoreError> {
        let session = Session {
            id: Uuid::now_v7().to_string(),
            started_at_ms,
            ended_at_ms: None,
        };
        self.connection.lock().unwrap().execute(
            "INSERT INTO sessions (id, started_at_ms) VALUES (?1, ?2)",
            params![session.id, session.started_at_ms],
        )?;
        Ok(session)
    }

    pub fn end_session_sync(&self, id: &str, ended_at_ms: i64) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE sessions SET ended_at_ms = ?2 WHERE id = ?1",
            params![id, ended_at_ms],
        )?;
        Ok(())
    }

    pub fn sessions_sync(&self) -> Result<Vec<Session>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT id, started_at_ms, ended_at_ms FROM sessions ORDER BY started_at_ms DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(Session {
                id: row.get(0)?,
                started_at_ms: row.get(1)?,
                ended_at_ms: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn moments_sync(&self, session_id: &str) -> Result<Vec<Moment>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT m.id, m.session_id, m.captured_at_ms, m.image_artifact_id, m.is_favorite,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    (SELECT group_concat(te.text, '\n')
                       FROM text_evidence te
                       JOIN audio_segments audio ON audio.id = te.audio_segment_id
                      WHERE audio.session_id = m.session_id
                        AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                        AND te.source = 'transcript'),
                    (SELECT audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    m.accessibility_artifact_id,
                    m.application_name,
                    m.bundle_identifier
             FROM moments m WHERE m.session_id = ?1 ORDER BY m.captured_at_ms",
        )?;
        let rows = statement.query_map([session_id], moment_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn insert_moment(
        &self,
        session_id: &str,
        captured_at_ms: i64,
        content_type: &str,
        image: &[u8],
    ) -> Result<Moment, StoreError> {
        let artifact_id = self.put_artifact(content_type, image)?;
        let moment = Moment {
            id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            captured_at_ms,
            image_artifact_id: artifact_id.clone(),
            is_favorite: false,
            ocr_text: None,
            transcript_text: None,
            audio_artifact_id: None,
            accessibility_artifact_id: None,
            application_name: None,
            bundle_identifier: None,
        };
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO moments (id, session_id, captured_at_ms, image_artifact_id, is_favorite)
             VALUES (?1, ?2, ?3, ?4, 0)",
            params![
                moment.id,
                moment.session_id,
                moment.captured_at_ms,
                artifact_id
            ],
        );
        if let Err(error) = result {
            let _ = fs::remove_file(self.artifact_path(&moment.image_artifact_id));
            return Err(error.into());
        }
        self.enforce_retention()?;
        Ok(moment)
    }

    pub fn insert_audio_segment(
        &self,
        session_id: &str,
        track: AudioTrack,
        started_at_ms: i64,
        ended_at_ms: i64,
        content_type: &str,
        audio: &[u8],
    ) -> Result<AudioSegment, StoreError> {
        let artifact_id = self.put_artifact(content_type, audio)?;
        let segment = AudioSegment {
            id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            track,
            started_at_ms,
            ended_at_ms,
            audio_artifact_id: artifact_id.clone(),
        };
        self.connection.lock().unwrap().execute(
            "INSERT INTO audio_segments
             (id, session_id, track, started_at_ms, ended_at_ms, audio_artifact_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                segment.id,
                segment.session_id,
                track_name(segment.track),
                segment.started_at_ms,
                segment.ended_at_ms,
                artifact_id
            ],
        )?;
        Ok(segment)
    }

    pub fn attach_accessibility_snapshot(
        &self,
        session_id: &str,
        captured_at_ms: i64,
        content_type: &str,
        snapshot: &[u8],
        application_name: Option<&str>,
        bundle_identifier: Option<&str>,
    ) -> Result<Option<String>, StoreError> {
        let candidate = self
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, captured_at_ms, accessibility_artifact_id
                   FROM moments
                  WHERE session_id = ?1
                  ORDER BY ABS(captured_at_ms - ?2), captured_at_ms DESC
                  LIMIT 1",
                params![session_id, captured_at_ms],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((moment_id, moment_time, previous_artifact)) = candidate else {
            return Ok(None);
        };
        if moment_time.abs_diff(captured_at_ms) > 2_000 {
            return Ok(None);
        }

        let artifact_id = self.put_artifact(content_type, snapshot)?;
        let update_result = {
            let connection = self.connection.lock().unwrap();
            connection.execute(
                "UPDATE moments
                    SET accessibility_artifact_id = ?2,
                        application_name = ?3,
                        bundle_identifier = ?4
                  WHERE id = ?1",
                params![moment_id, artifact_id, application_name, bundle_identifier],
            )
        };
        if let Err(error) = update_result {
            let _ = self
                .connection
                .lock()
                .unwrap()
                .execute("DELETE FROM artifacts WHERE id = ?1", [&artifact_id]);
            let _ = fs::remove_file(self.artifact_path(&artifact_id));
            return Err(error.into());
        }
        if let Some(previous) = previous_artifact {
            self.connection
                .lock()
                .unwrap()
                .execute("DELETE FROM artifacts WHERE id = ?1", [&previous])?;
            let _ = fs::remove_file(self.artifact_path(&previous));
        }
        Ok(Some(artifact_id))
    }

    pub fn audio_segments_sync(&self, session_id: &str) -> Result<Vec<AudioSegment>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT id, session_id, track, started_at_ms, ended_at_ms, audio_artifact_id
             FROM audio_segments WHERE session_id = ?1 ORDER BY started_at_ms",
        )?;
        let rows = statement.query_map([session_id], |row| {
            let track: String = row.get(2)?;
            Ok(AudioSegment {
                id: row.get(0)?,
                session_id: row.get(1)?,
                track: if track == "microphone" {
                    AudioTrack::Microphone
                } else {
                    AudioTrack::System
                },
                started_at_ms: row.get(3)?,
                ended_at_ms: row.get(4)?,
                audio_artifact_id: row.get(5)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn set_favorite(&self, moment_id: &str, favorite: bool) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE moments SET is_favorite = ?2 WHERE id = ?1",
            params![moment_id, favorite],
        )?;
        if !favorite {
            self.enforce_retention()?;
        }
        Ok(())
    }

    pub fn insert_text_evidence(
        &self,
        session_id: &str,
        moment_id: Option<&str>,
        audio_segment_id: Option<&str>,
        source: &str,
        text: &str,
        started_at_ms: i64,
        ended_at_ms: Option<i64>,
        model_version: &str,
    ) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        let connection = self.connection.lock().unwrap();
        connection.execute(
            "INSERT INTO text_evidence
             (id, session_id, moment_id, audio_segment_id, source, text, started_at_ms, ended_at_ms, model_version)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                id,
                session_id,
                moment_id,
                audio_segment_id,
                source,
                text,
                started_at_ms,
                ended_at_ms,
                model_version
            ],
        )?;
        connection.execute(
            "INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)",
            params![id, text],
        )?;
        Ok(id)
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT COALESCE(
                       te.moment_id,
                       (SELECT m.id FROM moments m
                        WHERE m.session_id = te.session_id
                          AND m.captured_at_ms <= te.started_at_ms
                        ORDER BY m.captured_at_ms DESC, m.id ASC
                        LIMIT 1),
                       ''
                    ),
                    te.session_id, te.started_at_ms, te.source, te.text,
                    bm25(evidence_fts)
             FROM evidence_fts
             JOIN text_evidence te ON te.id = evidence_fts.evidence_id
             WHERE evidence_fts MATCH ?1
             ORDER BY bm25(evidence_fts), te.started_at_ms DESC, te.id ASC
             LIMIT ?2",
        )?;
        let rows =
            statement.query_map(params![query, i64::try_from(limit).unwrap_or(20)], |row| {
                Ok(SearchHit {
                    moment_id: row.get(0)?,
                    session_id: row.get(1)?,
                    captured_at_ms: row.get(2)?,
                    source: row.get(3)?,
                    text: row.get(4)?,
                    score: (-row.get::<_, f64>(5)?) as f32,
                })
            })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn insert_embedding(
        &self,
        evidence_id: &str,
        vector: &[f32],
        model_version: &str,
    ) -> Result<(), StoreError> {
        validate_embedding(vector)?;
        self.connection.lock().unwrap().execute(
            "INSERT OR REPLACE INTO embeddings (evidence_id, vector_json, model_version)
             VALUES (?1, ?2, ?3)",
            params![
                evidence_id,
                serde_json::to_string(vector)
                    .map_err(|error| StoreError::InvalidEmbedding(error.to_string()))?,
                model_version
            ],
        )?;
        Ok(())
    }

    /// Finds evidence recorded with the same embedding adapter as the query.
    ///
    /// V0 performs the cosine scan in Rust. This is intentionally simple and
    /// keeps the storage contract portable until corpus size justifies an ANN
    /// index.
    pub fn semantic_search(
        &self,
        query_vector: &[f32],
        model_version: &str,
        limit: usize,
    ) -> Result<Vec<SearchHit>, StoreError> {
        validate_embedding(query_vector)?;
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT COALESCE(
                       te.moment_id,
                       (SELECT m.id FROM moments m
                        WHERE m.session_id = te.session_id
                          AND m.captured_at_ms <= te.started_at_ms
                        ORDER BY m.captured_at_ms DESC, m.id ASC
                        LIMIT 1),
                       ''
                    ),
                    te.session_id, te.started_at_ms, te.source, te.text, e.vector_json
             FROM embeddings e
             JOIN text_evidence te ON te.id = e.evidence_id
             WHERE e.model_version = ?1
             ORDER BY te.started_at_ms DESC, te.id ASC",
        )?;
        let rows = statement.query_map([model_version], |row| {
            Ok((
                SearchHit {
                    moment_id: row.get(0)?,
                    session_id: row.get(1)?,
                    captured_at_ms: row.get(2)?,
                    source: row.get(3)?,
                    text: row.get(4)?,
                    score: 0.0,
                },
                row.get::<_, String>(5)?,
            ))
        })?;

        let mut hits = Vec::new();
        for row in rows {
            let (mut hit, encoded) = row?;
            let vector: Vec<f32> = serde_json::from_str(&encoded)
                .map_err(|error| StoreError::InvalidEmbedding(error.to_string()))?;
            // Old vectors can have another dimension after a model upgrade.
            if vector.len() != query_vector.len() {
                continue;
            }
            let Some(score) = cosine_similarity(query_vector, &vector) else {
                continue;
            };
            hit.score = score;
            hits.push(hit);
        }
        sort_hits(&mut hits);
        hits.truncate(limit);
        Ok(hits)
    }

    pub fn session_text(&self, session_id: &str) -> Result<String, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT source, text FROM text_evidence WHERE session_id = ?1 ORDER BY started_at_ms",
        )?;
        let rows = statement.query_map([session_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut output = String::new();
        for row in rows {
            let (source, text) = row?;
            output.push_str(&source);
            output.push_str(": ");
            output.push_str(&text);
            output.push('\n');
        }
        Ok(output)
    }

    pub fn read_artifact(&self, id: &str) -> Result<ArtifactPayload, StoreError> {
        let connection = self.connection.lock().unwrap();
        let content_type: Option<String> = connection
            .query_row(
                "SELECT content_type FROM artifacts WHERE id = ?1",
                [id],
                |row| row.get(0),
            )
            .optional()?;
        let content_type =
            content_type.ok_or_else(|| StoreError::ArtifactNotFound(id.to_owned()))?;
        drop(connection);
        let encrypted = fs::read(self.artifact_path(id))?;
        let bytes = decrypt_artifact(&self.key, id, &content_type, &encrypted)?;
        Ok(ArtifactPayload {
            id: id.to_owned(),
            content_type,
            bytes_base64: BASE64.encode(bytes),
        })
    }

    fn put_artifact(&self, content_type: &str, bytes: &[u8]) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        let encrypted = encrypt_artifact(&self.key, &id, content_type, bytes)?;
        let final_path = self.artifact_path(&id);
        let temporary_path = self.artifacts_dir.join(format!(".{id}.tmp"));
        fs::write(&temporary_path, encrypted)?;
        fs::rename(&temporary_path, &final_path)?;
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO artifacts (id, content_type, byte_length) VALUES (?1, ?2, ?3)",
            params![
                id,
                content_type,
                i64::try_from(bytes.len()).unwrap_or(i64::MAX)
            ],
        );
        if let Err(error) = result {
            let _ = fs::remove_file(final_path);
            return Err(error.into());
        }
        Ok(id)
    }

    fn enforce_retention(&self) -> Result<(), StoreError> {
        let max = i64::try_from(self.max_unstarred_moments).unwrap_or(i64::MAX);
        let mut connection = self.connection.lock().unwrap();
        let count: i64 = connection.query_row(
            "SELECT COUNT(*) FROM moments WHERE is_favorite = 0",
            [],
            |row| row.get(0),
        )?;
        let excess = count.saturating_sub(max).max(0);
        if excess == 0 {
            return Ok(());
        }
        let transaction = connection.transaction()?;
        let candidates = {
            let mut statement = transaction.prepare(
                "SELECT id, image_artifact_id, accessibility_artifact_id
                   FROM moments WHERE is_favorite = 0
                 ORDER BY captured_at_ms ASC LIMIT ?1",
            )?;
            statement
                .query_map([excess], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (moment_id, artifact_id, accessibility_artifact_id) in &candidates {
            transaction.execute(
                "DELETE FROM evidence_fts WHERE evidence_id IN
                 (SELECT id FROM text_evidence WHERE moment_id = ?1)",
                [moment_id],
            )?;
            transaction.execute("DELETE FROM moments WHERE id = ?1", [moment_id])?;
            transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
            if let Some(accessibility_artifact_id) = accessibility_artifact_id {
                transaction.execute(
                    "DELETE FROM artifacts WHERE id = ?1",
                    [accessibility_artifact_id],
                )?;
            }
        }
        let audio_candidates = {
            let mut statement = transaction.prepare(
                "SELECT audio.id, audio.audio_artifact_id
                   FROM audio_segments audio
                  WHERE NOT EXISTS (
                    SELECT 1 FROM moments m
                     WHERE m.session_id = audio.session_id
                       AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                  )",
            )?;
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (segment_id, artifact_id) in &audio_candidates {
            transaction.execute(
                "DELETE FROM evidence_fts WHERE evidence_id IN
                 (SELECT id FROM text_evidence WHERE audio_segment_id = ?1)",
                [segment_id],
            )?;
            transaction.execute("DELETE FROM audio_segments WHERE id = ?1", [segment_id])?;
            transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
        }
        transaction.commit()?;
        drop(connection);
        for (_, artifact_id, accessibility_artifact_id) in candidates {
            let _ = fs::remove_file(self.artifact_path(&artifact_id));
            if let Some(accessibility_artifact_id) = accessibility_artifact_id {
                let _ = fs::remove_file(self.artifact_path(&accessibility_artifact_id));
            }
        }
        for (_, artifact_id) in audio_candidates {
            let _ = fs::remove_file(self.artifact_path(&artifact_id));
        }
        Ok(())
    }

    fn artifact_path(&self, id: &str) -> PathBuf {
        self.artifacts_dir.join(format!("{id}.arv0"))
    }
}

/// Deterministically combines exact and semantic rankings.
///
/// The returned score is a reciprocal-rank-fusion score, not a BM25 or cosine
/// score. An identical evidence hit appears only once even when both retrieval
/// paths find it.
#[must_use]
pub fn fuse_search_results(
    full_text: Vec<SearchHit>,
    semantic: Vec<SearchHit>,
    limit: usize,
) -> Vec<SearchHit> {
    const RRF_K: f32 = 60.0;
    let mut fused: HashMap<SearchHitKey, (SearchHit, f32)> = HashMap::new();
    for (rank, hit) in full_text.into_iter().enumerate() {
        add_rank(&mut fused, hit, rank, RRF_K);
    }
    for (rank, hit) in semantic.into_iter().enumerate() {
        add_rank(&mut fused, hit, rank, RRF_K);
    }
    let mut hits = fused
        .into_values()
        .map(|(mut hit, score)| {
            hit.score = score;
            hit
        })
        .collect::<Vec<_>>();
    sort_hits(&mut hits);
    hits.truncate(limit);
    hits
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct SearchHitKey {
    moment_id: String,
    session_id: String,
    captured_at_ms: i64,
    source: String,
    text: String,
}

impl From<&SearchHit> for SearchHitKey {
    fn from(hit: &SearchHit) -> Self {
        Self {
            moment_id: hit.moment_id.clone(),
            session_id: hit.session_id.clone(),
            captured_at_ms: hit.captured_at_ms,
            source: hit.source.clone(),
            text: hit.text.clone(),
        }
    }
}

fn add_rank(
    fused: &mut HashMap<SearchHitKey, (SearchHit, f32)>,
    hit: SearchHit,
    rank: usize,
    rrf_k: f32,
) {
    let rank = u16::try_from(rank).map_or(f32::from(u16::MAX), f32::from);
    let increment = 1.0 / (rrf_k + rank + 1.0);
    fused
        .entry(SearchHitKey::from(&hit))
        .and_modify(|(_, score)| *score += increment)
        .or_insert((hit, increment));
}

fn validate_embedding(vector: &[f32]) -> Result<(), StoreError> {
    if vector.is_empty() {
        return Err(StoreError::InvalidEmbedding(
            "vector must not be empty".to_owned(),
        ));
    }
    if vector.iter().any(|value| !value.is_finite()) {
        return Err(StoreError::InvalidEmbedding(
            "vector contains a non-finite value".to_owned(),
        ));
    }
    Ok(())
}

fn cosine_similarity(left: &[f32], right: &[f32]) -> Option<f32> {
    let (mut dot, mut left_norm, mut right_norm) = (0.0_f64, 0.0_f64, 0.0_f64);
    for (&left_value, &right_value) in left.iter().zip(right) {
        let left_value = f64::from(left_value);
        let right_value = f64::from(right_value);
        dot += left_value * right_value;
        left_norm += left_value * left_value;
        right_norm += right_value * right_value;
    }
    if left_norm == 0.0 || right_norm == 0.0 {
        return None;
    }
    Some((dot / (left_norm.sqrt() * right_norm.sqrt())) as f32)
}

fn sort_hits(hits: &mut [SearchHit]) {
    hits.sort_by(|left, right| {
        right
            .score
            .total_cmp(&left.score)
            .then_with(|| right.captured_at_ms.cmp(&left.captured_at_ms))
            .then_with(|| left.session_id.cmp(&right.session_id))
            .then_with(|| left.moment_id.cmp(&right.moment_id))
            .then_with(|| left.source.cmp(&right.source))
            .then_with(|| left.text.cmp(&right.text))
    });
}

#[async_trait]
impl Store for Vault {
    async fn create_session(&self, started_at_ms: i64) -> Result<Session, CoreError> {
        self.create_session_sync(started_at_ms)
            .map_err(to_core_error)
    }

    async fn end_session(&self, id: &str, ended_at_ms: i64) -> Result<(), CoreError> {
        self.end_session_sync(id, ended_at_ms)
            .map_err(to_core_error)
    }

    async fn sessions(&self) -> Result<Vec<Session>, CoreError> {
        self.sessions_sync().map_err(to_core_error)
    }

    async fn moments(&self, session_id: &str) -> Result<Vec<Moment>, CoreError> {
        self.moments_sync(session_id).map_err(to_core_error)
    }

    async fn audio_segments(&self, session_id: &str) -> Result<Vec<AudioSegment>, CoreError> {
        self.audio_segments_sync(session_id).map_err(to_core_error)
    }
}

fn migrate(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);
         INSERT INTO schema_meta (version)
           SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);
         CREATE TABLE IF NOT EXISTS sessions (
           id TEXT PRIMARY KEY,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER
         );
         CREATE TABLE IF NOT EXISTS artifacts (
           id TEXT PRIMARY KEY,
           content_type TEXT NOT NULL,
           byte_length INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS moments (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           captured_at_ms INTEGER NOT NULL,
           image_artifact_id TEXT NOT NULL REFERENCES artifacts(id),
           is_favorite INTEGER NOT NULL DEFAULT 0,
           accessibility_artifact_id TEXT REFERENCES artifacts(id),
           application_name TEXT,
           bundle_identifier TEXT
         );
         CREATE INDEX IF NOT EXISTS moments_session_time ON moments(session_id, captured_at_ms);
         CREATE TABLE IF NOT EXISTS audio_segments (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           track TEXT NOT NULL,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER NOT NULL,
           audio_artifact_id TEXT NOT NULL REFERENCES artifacts(id)
         );
         CREATE TABLE IF NOT EXISTS text_evidence (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           moment_id TEXT REFERENCES moments(id) ON DELETE CASCADE,
           audio_segment_id TEXT REFERENCES audio_segments(id) ON DELETE CASCADE,
           source TEXT NOT NULL,
           text TEXT NOT NULL,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER,
           model_version TEXT NOT NULL
         );
         CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(evidence_id UNINDEXED, text);
         CREATE TABLE IF NOT EXISTS embeddings (
           evidence_id TEXT PRIMARY KEY REFERENCES text_evidence(id) ON DELETE CASCADE,
           vector_json TEXT NOT NULL,
           model_version TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS embeddings_model_version ON embeddings(model_version);
         CREATE TABLE IF NOT EXISTS jobs (
           id TEXT PRIMARY KEY,
           capability TEXT NOT NULL,
           source_id TEXT NOT NULL,
           state TEXT NOT NULL,
           attempts INTEGER NOT NULL DEFAULT 0,
           error TEXT
         );",
    )?;
    let has_accessibility_artifact = {
        let mut statement = connection.prepare("PRAGMA table_info(moments)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|column| column == "accessibility_artifact_id")
    };
    if !has_accessibility_artifact {
        connection.execute(
            "ALTER TABLE moments ADD COLUMN accessibility_artifact_id TEXT REFERENCES artifacts(id)",
            [],
        )?;
    }
    let moment_columns = {
        let mut statement = connection.prepare("PRAGMA table_info(moments)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
    };
    if !moment_columns
        .iter()
        .any(|column| column == "application_name")
    {
        connection.execute("ALTER TABLE moments ADD COLUMN application_name TEXT", [])?;
    }
    if !moment_columns
        .iter()
        .any(|column| column == "bundle_identifier")
    {
        connection.execute("ALTER TABLE moments ADD COLUMN bundle_identifier TEXT", [])?;
    }
    connection.execute("UPDATE schema_meta SET version = ?1", [SCHEMA_VERSION])?;
    Ok(())
}

fn moment_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Moment> {
    Ok(Moment {
        id: row.get(0)?,
        session_id: row.get(1)?,
        captured_at_ms: row.get(2)?,
        image_artifact_id: row.get(3)?,
        is_favorite: row.get::<_, i64>(4)? != 0,
        ocr_text: row.get(5)?,
        transcript_text: row.get(6)?,
        audio_artifact_id: row.get(7)?,
        accessibility_artifact_id: row.get(8)?,
        application_name: row.get(9)?,
        bundle_identifier: row.get(10)?,
    })
}

fn encrypt_artifact(
    key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, StoreError> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let mut nonce_bytes = [0_u8; 24];
    rand::rng().fill_bytes(&mut nonce_bytes);
    let aad = format!("{id}:{content_type}");
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce_bytes),
            Payload {
                msg: bytes,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    let mut output =
        Vec::with_capacity(ARTIFACT_MAGIC.len() + nonce_bytes.len() + ciphertext.len());
    output.extend_from_slice(ARTIFACT_MAGIC);
    output.extend_from_slice(&nonce_bytes);
    output.extend_from_slice(&ciphertext);
    Ok(output)
}

fn decrypt_artifact(
    key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, StoreError> {
    if bytes.len() < 28 || &bytes[..4] != ARTIFACT_MAGIC {
        return Err(StoreError::Crypto);
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    let aad = format!("{id}:{content_type}");
    cipher
        .decrypt(
            XNonce::from_slice(&bytes[4..28]),
            Payload {
                msg: &bytes[28..],
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| StoreError::Crypto)
}

fn track_name(track: AudioTrack) -> &'static str {
    match track {
        AudioTrack::System => "system",
        AudioTrack::Microphone => "microphone",
    }
}

fn encode_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn to_core_error(error: StoreError) -> CoreError {
    CoreError::Store(error.to_string())
}

#[must_use]
pub fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("AfterRay")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_vault(max: usize) -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_unstarred_moments: max,
            },
            [7_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    #[test]
    fn encrypted_artifact_round_trip_has_no_plaintext() {
        let (directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"private-screen-text")
            .unwrap();
        let on_disk = fs::read(vault.artifact_path(&moment.image_artifact_id)).unwrap();
        assert!(
            !on_disk
                .windows(19)
                .any(|window| window == b"private-screen-text")
        );
        let payload = vault.read_artifact(&moment.image_artifact_id).unwrap();
        assert_eq!(
            BASE64.decode(payload.bytes_base64).unwrap(),
            b"private-screen-text"
        );
        drop(directory);
    }

    #[test]
    fn accessibility_snapshot_attaches_within_two_seconds() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", b"screen")
            .unwrap();
        let artifact = vault
            .attach_accessibility_snapshot(
                &session.id,
                11_500,
                "application/vnd.afterray.ax+json",
                br#"{"root":{"role":"AXWindow"}}"#,
                Some("Xcode"),
                Some("com.apple.dt.Xcode"),
            )
            .unwrap();
        assert!(artifact.is_some());
        let loaded = vault.moments_sync(&session.id).unwrap();
        assert_eq!(loaded[0].id, moment.id);
        assert_eq!(loaded[0].accessibility_artifact_id, artifact);
        assert_eq!(loaded[0].application_name.as_deref(), Some("Xcode"));

        let too_late = vault
            .attach_accessibility_snapshot(
                &session.id,
                12_001,
                "application/vnd.afterray.ax+json",
                b"{}",
                None,
                None,
            )
            .unwrap();
        assert!(too_late.is_none());
    }

    #[test]
    fn retention_skips_favorites() {
        let (_directory, vault) = test_vault(2);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"one")
            .unwrap();
        vault.set_favorite(&first.id, true).unwrap();
        let second = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"two")
            .unwrap();
        let third = vault
            .insert_moment(&session.id, 3, "image/jpeg", b"three")
            .unwrap();
        let fourth = vault
            .insert_moment(&session.id, 4, "image/jpeg", b"four")
            .unwrap();
        let moments = vault.moments_sync(&session.id).unwrap();
        let ids = moments
            .iter()
            .map(|moment| moment.id.as_str())
            .collect::<Vec<_>>();
        assert!(ids.contains(&first.id.as_str()));
        assert!(!ids.contains(&second.id.as_str()));
        assert!(ids.contains(&third.id.as_str()));
        assert!(ids.contains(&fourth.id.as_str()));
    }

    #[test]
    fn semantic_search_uses_cosine_and_matching_model_version() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 10, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 20, "image/jpeg", b"two")
            .unwrap();
        let first_evidence = vault
            .insert_text_evidence(
                &session.id,
                Some(&first.id),
                None,
                "ocr",
                "Rust ownership rules",
                10,
                None,
                "ocr-model",
            )
            .unwrap();
        let second_evidence = vault
            .insert_text_evidence(
                &session.id,
                Some(&second.id),
                None,
                "ocr",
                "weekly planning meeting",
                20,
                None,
                "ocr-model",
            )
            .unwrap();
        vault
            .insert_embedding(&first_evidence, &[1.0, 0.0], "embedding-model")
            .unwrap();
        vault
            .insert_embedding(&second_evidence, &[0.0, 1.0], "embedding-model")
            .unwrap();

        let hits = vault
            .semantic_search(&[0.9, 0.1], "embedding-model", 10)
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].moment_id, first.id);
        assert!(hits[0].score > hits[1].score);
        assert!(
            vault
                .semantic_search(&[0.9, 0.1], "another-model", 10)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn embedding_rejects_empty_and_non_finite_vectors() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let evidence = vault
            .insert_text_evidence(&session.id, None, None, "ocr", "test", 1, None, "ocr-model")
            .unwrap();
        assert!(matches!(
            vault.insert_embedding(&evidence, &[], "embedding-model"),
            Err(StoreError::InvalidEmbedding(_))
        ));
        assert!(matches!(
            vault.insert_embedding(&evidence, &[f32::NAN], "embedding-model"),
            Err(StoreError::InvalidEmbedding(_))
        ));
    }

    #[test]
    fn fusion_deduplicates_and_has_deterministic_order() {
        fn hit(id: &str, time: i64) -> SearchHit {
            SearchHit {
                moment_id: id.to_owned(),
                session_id: "session".to_owned(),
                captured_at_ms: time,
                source: "ocr".to_owned(),
                text: format!("text-{id}"),
                score: 0.0,
            }
        }

        let fused = fuse_search_results(
            vec![hit("a", 1), hit("b", 2)],
            vec![hit("b", 2), hit("c", 3)],
            10,
        );
        assert_eq!(fused.len(), 3);
        assert_eq!(fused[0].moment_id, "b");
        assert_eq!(
            fused
                .iter()
                .filter(|candidate| candidate.moment_id == "b")
                .count(),
            1
        );
        // A is rank 1 in FTS while C is rank 2 in semantic search.
        assert_eq!(fused[1].moment_id, "a");
        assert_eq!(fused[2].moment_id, "c");
    }
}
