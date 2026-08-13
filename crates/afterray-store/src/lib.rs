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
#[cfg(target_os = "macos")]
use core_foundation::{base::TCFType, string::CFString};
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
#[cfg(target_os = "macos")]
use security_framework::{
    access_control::{ProtectionMode, SecAccessControl},
    passwords::{
        PasswordOptions, delete_generic_password_options, generic_password,
        set_generic_password_options,
    },
};
#[cfg(target_os = "macos")]
use security_framework_sys::base::errSecItemNotFound;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::Write as _,
    path::{Path, PathBuf},
    sync::Mutex,
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

pub const SCHEMA_VERSION: u32 = 5;
const LEGACY_ARTIFACT_MAGIC: &[u8; 4] = b"ARV0";
const ARTIFACT_MAGIC: &[u8; 4] = b"ARV1";
const ARTIFACT_FORMAT_VERSION: i64 = 1;
const NONCE_LENGTH: usize = 24;
const WRAPPED_DEK_LENGTH: usize = 32 + 16;
const ARTIFACT_HEADER_LENGTH: usize = 4 + NONCE_LENGTH;
const DATABASE_KEY_CONTEXT: &str = "dev.afterray.vault.database-key.v1";
const ARTIFACT_WRAP_KEY_CONTEXT: &str = "dev.afterray.vault.artifact-wrap-key.v1";
const KEYCHAIN_SERVICE: &str = "dev.afterray.v0.vault";
type ArtifactRecordMetadata = (String, i64, Option<Vec<u8>>, Option<Vec<u8>>);
pub type VaultKey = Zeroizing<[u8; 32]>;

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
    #[error("the existing Vault key is missing from macOS Keychain")]
    MissingVaultKey,
    #[error("artifact not found: {0}")]
    ArtifactNotFound(String),
    #[error("key provider: {0}")]
    KeyProvider(String),
    #[error("invalid embedding: {0}")]
    InvalidEmbedding(String),
}

pub trait KeyProvider: Send + Sync {
    fn load(&self) -> Result<Option<VaultKey>, StoreError>;
    fn create(&self) -> Result<VaultKey, StoreError>;

    fn load_or_create(&self) -> Result<VaultKey, StoreError> {
        self.load()?.map_or_else(|| self.create(), Ok)
    }
}

#[derive(Debug, Default)]
pub struct MacOsKeychainProvider;

impl KeyProvider for MacOsKeychainProvider {
    fn load(&self) -> Result<Option<VaultKey>, StoreError> {
        let account = std::env::var("USER").unwrap_or_else(|_| "afterray".to_owned());
        load_keychain_key(&account)
    }

    fn create(&self) -> Result<VaultKey, StoreError> {
        let account = std::env::var("USER").unwrap_or_else(|_| "afterray".to_owned());
        create_keychain_key(&account)
    }
}

/// Developer ID helper tools cannot use the Data Protection keychain or
/// `SecAccessControl`: both require entitlements that AMFI rejects without a
/// provisioning profile (`errSecMissingEntitlement` or a launch-time kill).
/// The file-based keychain with `WhenUnlockedThisDeviceOnly` and iCloud sync
/// disabled meets the same device-bound, unlocked-only contract.
#[cfg(target_os = "macos")]
const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;

/// `kSecAttrAccessible` / `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
/// security-framework does not expose this attribute key through a safe API.
#[cfg(target_os = "macos")]
const SEC_ATTR_ACCESSIBLE: &str = "pdmn";
#[cfg(target_os = "macos")]
const SEC_ATTR_ACCESSIBLE_WHEN_UNLOCKED_THIS_DEVICE_ONLY: &str = "aku";

#[cfg(target_os = "macos")]
fn load_keychain_key(account: &str) -> Result<Option<VaultKey>, StoreError> {
    if let Some(key) = read_keychain_item(protected_keychain_query_options(account))? {
        let _ = remove_file_keychain_item(account);
        return Ok(Some(key));
    }
    if let Some(key) = read_keychain_item(file_keychain_query_options(account))? {
        promote_keychain_item(account, &key)?;
        return Ok(Some(key));
    }
    match generic_password(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        account,
    )) {
        Ok(existing) => {
            let mut existing = Zeroizing::new(existing);
            let key = decode_key(&existing)?;
            existing.zeroize();
            persist_keychain_item(account, &key)?;
            remove_legacy_keychain_item(account)?;
            Ok(Some(key))
        }
        Err(error) if is_item_not_found(error) => Ok(None),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn read_keychain_item(options: PasswordOptions) -> Result<Option<VaultKey>, StoreError> {
    match generic_password(options) {
        Ok(existing) => {
            let existing = Zeroizing::new(existing);
            Ok(Some(decode_key(&existing)?))
        }
        Err(error) if is_item_not_found(error) || is_missing_entitlement(error) => Ok(None),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn persist_keychain_item(account: &str, key: &VaultKey) -> Result<(), StoreError> {
    match set_generic_password_options(&**key, protected_keychain_create_options(account)?) {
        Ok(()) => Ok(()),
        Err(error) if is_missing_entitlement(error) => {
            set_generic_password_options(&**key, file_keychain_create_options(account))
                .map_err(|error| StoreError::KeyProvider(error.to_string()))
        }
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn promote_keychain_item(account: &str, key: &VaultKey) -> Result<(), StoreError> {
    match set_generic_password_options(&**key, protected_keychain_create_options(account)?) {
        Ok(()) => {
            let verified = read_keychain_item(protected_keychain_query_options(account))?
                .ok_or(StoreError::InvalidKey)?;
            if *verified != **key {
                return Err(StoreError::InvalidKey);
            }
            let _ = remove_file_keychain_item(account);
            Ok(())
        }
        Err(error) if is_missing_entitlement(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn remove_file_keychain_item(account: &str) -> Result<(), StoreError> {
    match delete_generic_password_options(file_keychain_query_options(account)) {
        Ok(()) => Ok(()),
        Err(error) if is_item_not_found(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn remove_legacy_keychain_item(account: &str) -> Result<(), StoreError> {
    match delete_generic_password_options(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        account,
    )) {
        Ok(()) => Ok(()),
        Err(error) if is_item_not_found(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn create_keychain_key(account: &str) -> Result<VaultKey, StoreError> {
    let mut key = Zeroizing::new([0_u8; 32]);
    rand::rng().fill_bytes(key.as_mut());
    persist_keychain_item(account, &key)?;
    Ok(key)
}

#[cfg(target_os = "macos")]
fn file_keychain_query_options(account: &str) -> PasswordOptions {
    let mut options = PasswordOptions::new_generic_password(KEYCHAIN_SERVICE, account);
    options.set_access_synchronized(Some(false));
    options
}

#[cfg(target_os = "macos")]
fn file_keychain_create_options(account: &str) -> PasswordOptions {
    let mut options = file_keychain_query_options(account);
    options.set_label("AfterRay Vault Key");
    #[allow(deprecated)]
    {
        options.query.push((
            CFString::from(SEC_ATTR_ACCESSIBLE),
            CFString::from(SEC_ATTR_ACCESSIBLE_WHEN_UNLOCKED_THIS_DEVICE_ONLY).into_CFType(),
        ));
    }
    options
}

#[cfg(target_os = "macos")]
fn protected_keychain_query_options(account: &str) -> PasswordOptions {
    let mut options = file_keychain_query_options(account);
    options.use_protected_keychain();
    options
}

#[cfg(target_os = "macos")]
fn protected_keychain_create_options(account: &str) -> Result<PasswordOptions, StoreError> {
    let access_control = SecAccessControl::create_with_protection(
        Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
        0,
    )
    .map_err(|error| StoreError::KeyProvider(error.to_string()))?;
    let mut options = protected_keychain_query_options(account);
    options.set_access_control(access_control);
    Ok(options)
}

#[cfg(target_os = "macos")]
fn is_item_not_found(error: security_framework::base::Error) -> bool {
    error.code() == errSecItemNotFound
}

#[cfg(target_os = "macos")]
fn is_missing_entitlement(error: security_framework::base::Error) -> bool {
    error.code() == ERR_SEC_MISSING_ENTITLEMENT
}

#[cfg(not(target_os = "macos"))]
fn load_keychain_key(_account: &str) -> Result<Option<VaultKey>, StoreError> {
    Err(StoreError::KeyProvider(
        "the production Vault key provider requires macOS Keychain".to_owned(),
    ))
}

#[cfg(not(target_os = "macos"))]
fn create_keychain_key(_account: &str) -> Result<VaultKey, StoreError> {
    Err(StoreError::KeyProvider(
        "the production Vault key provider requires macOS Keychain".to_owned(),
    ))
}

fn decode_key(value: &[u8]) -> Result<VaultKey, StoreError> {
    if value.len() == 32 {
        return value
            .try_into()
            .map(Zeroizing::new)
            .map_err(|_| StoreError::InvalidKey);
    }
    let decoded = BASE64.decode(value).map_err(|_| StoreError::InvalidKey)?;
    decoded
        .try_into()
        .map(Zeroizing::new)
        .map_err(|_| StoreError::InvalidKey)
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
    artifact_wrap_key: Zeroizing<[u8; 32]>,
    legacy_artifact_key: Mutex<Option<Zeroizing<[u8; 32]>>>,
    artifact_io: Mutex<()>,
    max_unstarred_moments: usize,
}

impl Vault {
    pub fn open(config: VaultConfig, provider: &dyn KeyProvider) -> Result<Self, StoreError> {
        let database_path = config.data_dir.join("afterray.sqlite3");
        let existing_vault = database_path
            .metadata()
            .is_ok_and(|metadata| metadata.len() > 0);
        let key = match provider.load()? {
            Some(key) => key,
            None if existing_vault => return Err(StoreError::MissingVaultKey),
            None => provider.create()?,
        };
        Self::open_with_key(config, *key)
    }

    pub fn open_with_key(config: VaultConfig, key: [u8; 32]) -> Result<Self, StoreError> {
        let master_key = Zeroizing::new(key);
        create_private_directory(&config.data_dir)?;
        let artifacts_dir = config.data_dir.join("artifacts");
        create_private_directory(&artifacts_dir)?;
        let database_key = Zeroizing::new(blake3::derive_key(DATABASE_KEY_CONTEXT, &*master_key));
        let database_path = config.data_dir.join("afterray.sqlite3");
        let connection =
            open_database_with_legacy_migration(&database_path, &database_key, &master_key)?;
        migrate(&connection)?;
        set_database_file_permissions(&database_path)?;
        Ok(Self {
            connection: Mutex::new(connection),
            artifacts_dir,
            artifact_wrap_key: Zeroizing::new(blake3::derive_key(
                ARTIFACT_WRAP_KEY_CONTEXT,
                &*master_key,
            )),
            legacy_artifact_key: Mutex::new(Some(Zeroizing::new(*master_key))),
            artifact_io: Mutex::new(()),
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

    /// Closes sessions left open by an interrupted daemon. Earlier sessions end
    /// when the next one starts; the newest ends at its last captured moment.
    pub fn close_orphaned_sessions_sync(&self, fallback_ms: i64) -> Result<usize, StoreError> {
        let changed = self.connection.lock().unwrap().execute(
            "UPDATE sessions
                SET ended_at_ms = COALESCE(
                    (SELECT MIN(next.started_at_ms)
                       FROM sessions next
                      WHERE next.started_at_ms > sessions.started_at_ms),
                    (SELECT MAX(moment.captured_at_ms)
                       FROM moments moment
                      WHERE moment.session_id = sessions.id),
                    ?1
                )
              WHERE ended_at_ms IS NULL",
            [fallback_ms],
        )?;
        Ok(changed)
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

    pub fn timeline_sync(&self) -> Result<Vec<Moment>, StoreError> {
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
             FROM moments m ORDER BY m.captured_at_ms, m.id",
        )?;
        let rows = statement.query_map([], moment_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn timeline_since_sync(&self, since_ms: i64) -> Result<Vec<Moment>, StoreError> {
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
             FROM moments m
             WHERE m.captured_at_ms >= ?1
             ORDER BY m.captured_at_ms, m.id",
        )?;
        let rows = statement.query_map([since_ms], moment_from_row)?;
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
            let _ = self.delete_artifact_record_and_file(&moment.image_artifact_id);
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
        let result = self.connection.lock().unwrap().execute(
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
        );
        if let Err(error) = result {
            let _ = self.delete_artifact_record_and_file(&segment.audio_artifact_id);
            return Err(error.into());
        }
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
            let _ = self.delete_artifact_record_and_file(&artifact_id);
            return Err(error.into());
        }
        if let Some(previous) = previous_artifact {
            self.delete_artifact_record_and_file(&previous)?;
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
        let _artifact_guard = self.artifact_io.lock().unwrap();
        let connection = self.connection.lock().unwrap();
        let metadata: Option<ArtifactRecordMetadata> = connection
            .query_row(
                "SELECT content_type, format_version, wrapped_key, wrapping_nonce
                   FROM artifacts WHERE id = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let (content_type, format_version, wrapped_key, wrapping_nonce) =
            metadata.ok_or_else(|| StoreError::ArtifactNotFound(id.to_owned()))?;
        drop(connection);
        if format_version < ARTIFACT_FORMAT_VERSION {
            let legacy_key = self
                .legacy_artifact_key
                .lock()
                .unwrap()
                .as_ref()
                .map(|key| Zeroizing::new(**key))
                .ok_or(StoreError::Crypto)?;
            let encrypted = fs::read(self.legacy_artifact_path(id))?;
            let bytes = decrypt_legacy_artifact(&legacy_key, id, &content_type, &encrypted)?;
            return Ok(ArtifactPayload {
                id: id.to_owned(),
                content_type,
                bytes: bytes.to_vec(),
            });
        }
        if format_version != ARTIFACT_FORMAT_VERSION {
            return Err(StoreError::Crypto);
        }
        let wrapped_key = wrapped_key.ok_or(StoreError::Crypto)?;
        let wrapping_nonce = wrapping_nonce.ok_or(StoreError::Crypto)?;
        let encrypted = fs::read(self.artifact_path(id))?;
        let bytes = decrypt_artifact(
            &self.artifact_wrap_key,
            id,
            &content_type,
            &encrypted,
            &wrapped_key,
            &wrapping_nonce,
        )?;
        Ok(ArtifactPayload {
            id: id.to_owned(),
            content_type,
            bytes: bytes.to_vec(),
        })
    }

    fn put_artifact(&self, content_type: &str, bytes: &[u8]) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        let encrypted = encrypt_artifact(&self.artifact_wrap_key, &id, content_type, bytes)?;
        let final_path = self.artifact_path(&id);
        let _artifact_guard = self.artifact_io.lock().unwrap();
        atomic_write_private(&final_path, &encrypted.bytes)?;
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO artifacts (
                 id, content_type, byte_length, format_version, wrapped_key, wrapping_nonce
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                id,
                content_type,
                i64::try_from(bytes.len()).unwrap_or(i64::MAX),
                ARTIFACT_FORMAT_VERSION,
                encrypted.wrapped_dek,
                encrypted.wrapping_nonce,
            ],
        );
        if let Err(error) = result {
            let _ = fs::remove_file(final_path);
            return Err(error.into());
        }
        Ok(id)
    }

    /// Re-encrypts legacy artifacts one at a time without blocking Vault startup.
    ///
    /// Callers may run this after the daemon has started accepting requests.
    pub fn migrate_legacy_artifacts(&self) -> Result<usize, StoreError> {
        let artifacts = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id, content_type FROM artifacts
                  WHERE format_version < ?1 ORDER BY id",
            )?;
            statement
                .query_map([ARTIFACT_FORMAT_VERSION], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        if artifacts.is_empty() {
            *self.legacy_artifact_key.lock().unwrap() = None;
            return Ok(0);
        }

        let legacy_key = self
            .legacy_artifact_key
            .lock()
            .unwrap()
            .as_ref()
            .map(|key| Zeroizing::new(**key))
            .ok_or(StoreError::Crypto)?;
        let total = artifacts.len();
        for (id, content_type) in artifacts {
            let _artifact_guard = self.artifact_io.lock().unwrap();
            let path = self.artifact_path(&id);
            let legacy_path = self.legacy_artifact_path(&id);
            let legacy_encrypted = fs::read(&legacy_path)?;
            let decrypted =
                decrypt_legacy_artifact(&legacy_key, &id, &content_type, &legacy_encrypted)?;
            let replacement =
                encrypt_artifact(&self.artifact_wrap_key, &id, &content_type, &decrypted)?;
            atomic_write_private(&path, &replacement.bytes)?;
            self.connection.lock().unwrap().execute(
                "UPDATE artifacts
                    SET format_version = ?2, wrapped_key = ?3, wrapping_nonce = ?4
                  WHERE id = ?1",
                params![
                    id,
                    ARTIFACT_FORMAT_VERSION,
                    replacement.wrapped_dek,
                    replacement.wrapping_nonce,
                ],
            )?;
            fs::remove_file(legacy_path)?;
        }
        *self.legacy_artifact_key.lock().unwrap() = None;
        Ok(total)
    }

    /// Completes file-level startup work after the daemon is already serving.
    pub fn run_artifact_maintenance(&self) -> Result<usize, StoreError> {
        let migrated = self.migrate_legacy_artifacts()?;
        self.cleanup_orphaned_artifact_files()?;
        Ok(migrated)
    }

    fn delete_artifact_record_and_file(&self, id: &str) -> Result<(), StoreError> {
        self.connection
            .lock()
            .unwrap()
            .execute("DELETE FROM artifacts WHERE id = ?1", [id])?;
        let _artifact_guard = self.artifact_io.lock().unwrap();
        match fs::remove_file(self.artifact_path(id)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn cleanup_orphaned_artifact_files(&self) -> Result<(), StoreError> {
        let _artifact_guard = self.artifact_io.lock().unwrap();
        for entry in fs::read_dir(&self.artifacts_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let file_name = entry.file_name();
            let Some(file_name) = file_name.to_str() else {
                continue;
            };
            if file_name.starts_with('.')
                && Path::new(file_name)
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("tmp"))
            {
                fs::remove_file(entry.path())?;
                continue;
            }
            let (id, on_disk_version) = if let Some(id) = file_name.strip_suffix(".arv0") {
                (id, 0_i64)
            } else if let Some(id) = file_name.strip_suffix(".arv1") {
                (id, ARTIFACT_FORMAT_VERSION)
            } else {
                continue;
            };
            let database_version: Option<i64> = self
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT format_version FROM artifacts WHERE id = ?1",
                    [id],
                    |row| row.get(0),
                )
                .optional()?;
            if database_version != Some(on_disk_version) {
                fs::remove_file(entry.path())?;
            }
        }
        Ok(())
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
        self.artifacts_dir.join(format!("{id}.arv1"))
    }

    fn legacy_artifact_path(&self, id: &str) -> PathBuf {
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
           byte_length INTEGER NOT NULL,
           format_version INTEGER NOT NULL DEFAULT 1,
           wrapped_key BLOB,
           wrapping_nonce BLOB
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
    migrate_query_indexes(connection)?;
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
    migrate_artifact_columns(connection)?;
    connection.execute("UPDATE schema_meta SET version = ?1", [SCHEMA_VERSION])?;
    Ok(())
}

fn migrate_artifact_columns(connection: &Connection) -> Result<(), StoreError> {
    let artifact_columns = {
        let mut statement = connection.prepare("PRAGMA table_info(artifacts)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
    };
    if !artifact_columns
        .iter()
        .any(|column| column == "format_version")
    {
        connection.execute(
            "ALTER TABLE artifacts ADD COLUMN format_version INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !artifact_columns
        .iter()
        .any(|column| column == "wrapped_key")
    {
        connection.execute("ALTER TABLE artifacts ADD COLUMN wrapped_key BLOB", [])?;
    }
    if !artifact_columns
        .iter()
        .any(|column| column == "wrapping_nonce")
    {
        connection.execute("ALTER TABLE artifacts ADD COLUMN wrapping_nonce BLOB", [])?;
    }
    Ok(())
}

fn migrate_query_indexes(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS moments_time_id ON moments(captured_at_ms, id);
         CREATE INDEX IF NOT EXISTS text_evidence_moment_source
           ON text_evidence(moment_id, source);
         CREATE INDEX IF NOT EXISTS text_evidence_audio_source
           ON text_evidence(audio_segment_id, source);
         CREATE INDEX IF NOT EXISTS audio_segments_session_time
           ON audio_segments(session_id, started_at_ms, ended_at_ms);",
    )?;
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
    wrapping_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<EncryptedArtifact, StoreError> {
    let mut dek = Zeroizing::new([0_u8; 32]);
    rand::rng().fill_bytes(dek.as_mut());
    let data_cipher = XChaCha20Poly1305::new((&*dek).into());
    let mut data_nonce = [0_u8; NONCE_LENGTH];
    rand::rng().fill_bytes(&mut data_nonce);
    let data_aad = artifact_aad(b"content", id, content_type);
    let ciphertext = data_cipher
        .encrypt(
            XNonce::from_slice(&data_nonce),
            Payload {
                msg: bytes,
                aad: &data_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;

    let wrapping_cipher = XChaCha20Poly1305::new(wrapping_key.into());
    let mut wrapping_nonce = [0_u8; NONCE_LENGTH];
    rand::rng().fill_bytes(&mut wrapping_nonce);
    let wrapping_aad = artifact_aad(b"wrapped-dek", id, content_type);
    let wrapped_dek = wrapping_cipher
        .encrypt(
            XNonce::from_slice(&wrapping_nonce),
            Payload {
                msg: &*dek,
                aad: &wrapping_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    debug_assert_eq!(wrapped_dek.len(), WRAPPED_DEK_LENGTH);

    let mut output = Vec::with_capacity(ARTIFACT_HEADER_LENGTH + ciphertext.len());
    output.extend_from_slice(ARTIFACT_MAGIC);
    output.extend_from_slice(&data_nonce);
    output.extend_from_slice(&ciphertext);
    Ok(EncryptedArtifact {
        bytes: output,
        wrapped_dek,
        wrapping_nonce,
    })
}

struct EncryptedArtifact {
    bytes: Vec<u8>,
    wrapped_dek: Vec<u8>,
    wrapping_nonce: [u8; NONCE_LENGTH],
}

fn decrypt_artifact(
    wrapping_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
    wrapped_dek: &[u8],
    wrapping_nonce: &[u8],
) -> Result<Zeroizing<Vec<u8>>, StoreError> {
    if bytes.len() < ARTIFACT_HEADER_LENGTH + 16
        || &bytes[..4] != ARTIFACT_MAGIC
        || wrapped_dek.len() != WRAPPED_DEK_LENGTH
        || wrapping_nonce.len() != NONCE_LENGTH
    {
        return Err(StoreError::Crypto);
    }
    let wrapping_cipher = XChaCha20Poly1305::new(wrapping_key.into());
    let wrapping_aad = artifact_aad(b"wrapped-dek", id, content_type);
    let mut dek = Zeroizing::new(
        wrapping_cipher
            .decrypt(
                XNonce::from_slice(wrapping_nonce),
                Payload {
                    msg: wrapped_dek,
                    aad: &wrapping_aad,
                },
            )
            .map_err(|_| StoreError::Crypto)?,
    );
    if dek.len() != 32 {
        return Err(StoreError::Crypto);
    }
    let data_cipher = XChaCha20Poly1305::new_from_slice(&dek).map_err(|_| StoreError::Crypto)?;
    let data_aad = artifact_aad(b"content", id, content_type);
    let plaintext = data_cipher
        .decrypt(
            XNonce::from_slice(&bytes[4..ARTIFACT_HEADER_LENGTH]),
            Payload {
                msg: &bytes[ARTIFACT_HEADER_LENGTH..],
                aad: &data_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    dek.zeroize();
    Ok(Zeroizing::new(plaintext))
}

fn decrypt_legacy_artifact(
    legacy_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<Zeroizing<Vec<u8>>, StoreError> {
    if bytes.len() < 4 + NONCE_LENGTH + 16 || &bytes[..4] != LEGACY_ARTIFACT_MAGIC {
        return Err(StoreError::Crypto);
    }
    let cipher = XChaCha20Poly1305::new(legacy_key.into());
    let aad = format!("{id}:{content_type}");
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&bytes[4..4 + NONCE_LENGTH]),
            Payload {
                msg: &bytes[4 + NONCE_LENGTH..],
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    Ok(Zeroizing::new(plaintext))
}

fn artifact_aad(purpose: &[u8], id: &str, content_type: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(purpose.len() + id.len() + content_type.len() + 16);
    aad.extend_from_slice(b"afterray-artifact-v1\0");
    aad.extend_from_slice(purpose);
    aad.push(0);
    aad.extend_from_slice(id.as_bytes());
    aad.push(0);
    aad.extend_from_slice(content_type.as_bytes());
    aad
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

fn open_database_with_legacy_migration(
    path: &Path,
    database_key: &[u8; 32],
    legacy_key: &[u8; 32],
) -> Result<Connection, StoreError> {
    let existing_database = path.metadata().is_ok_and(|metadata| metadata.len() > 0);
    match open_keyed_database(path, database_key) {
        Ok(connection) => Ok(connection),
        Err(_derived_error) if existing_database => {
            let legacy_connection =
                open_keyed_database(path, legacy_key).map_err(|_| StoreError::InvalidKey)?;
            legacy_connection.execute_batch(
                "PRAGMA wal_checkpoint(TRUNCATE);
                 PRAGMA journal_mode = DELETE;",
            )?;
            let mut sql = Zeroizing::new(format!(
                "PRAGMA rekey = \"x'{}'\";",
                encode_hex(database_key)
            ));
            let rekey_result = legacy_connection.execute_batch(&sql);
            sql.zeroize();
            rekey_result?;
            drop(legacy_connection);
            open_keyed_database(path, database_key).map_err(|_| StoreError::InvalidKey)
        }
        Err(error) => Err(error),
    }
}

fn open_keyed_database(path: &Path, key: &[u8; 32]) -> Result<Connection, StoreError> {
    let connection = Connection::open(path)?;
    let mut key_pragma = Zeroizing::new(format!("PRAGMA key = \"x'{}'\";", encode_hex(key)));
    let key_result = connection.execute_batch(&key_pragma);
    key_pragma.zeroize();
    key_result?;

    let cipher_version: Option<String> = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .optional()?;
    if cipher_version.as_deref().is_none_or(str::is_empty) {
        return Err(StoreError::InvalidKey);
    }
    connection
        .query_row("SELECT COUNT(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|_| StoreError::InvalidKey)?;
    connection.execute_batch(
        "PRAGMA cipher_memory_security = ON;
         PRAGMA foreign_keys = ON;
         PRAGMA secure_delete = ON;
         PRAGMA temp_store = MEMORY;
         PRAGMA journal_mode = WAL;",
    )?;
    set_database_file_permissions(path)?;
    Ok(connection)
}

fn set_database_file_permissions(path: &Path) -> Result<(), StoreError> {
    set_private_file_permissions(path)?;
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let sidecar = PathBuf::from(sidecar);
        if sidecar.exists() {
            set_private_file_permissions(&sidecar)?;
        }
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<(), StoreError> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn set_private_file_permissions(path: &Path) -> Result<(), StoreError> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn atomic_write_private(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    let parent = path.parent().ok_or_else(|| {
        StoreError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "artifact path has no parent directory",
        ))
    })?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            StoreError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "artifact path has no valid file name",
            ))
        })?;
    let temporary_path = parent.join(format!(".{file_name}.{}.tmp", Uuid::now_v7()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(&temporary_path)?;
    let write_result = (|| -> Result<(), std::io::Error> {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary_path, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    write_result.map_err(StoreError::Io)
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
mod pipeline_bench;

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

    #[cfg(target_os = "macos")]
    #[test]
    fn keychain_round_trip_works_without_data_protection_entitlement() {
        let account = format!("afterray-test-{}", Uuid::now_v7());
        let created = create_keychain_key(&account).expect("create vault key");
        let loaded = load_keychain_key(&account).expect("load vault key");
        let _ = remove_file_keychain_item(&account);
        let _ = remove_legacy_keychain_item(&account);
        assert_eq!(*created, *loaded.expect("created key should be readable"));
    }

    #[test]
    fn existing_vault_never_silently_creates_a_replacement_key() {
        struct MissingKeyProvider {
            create_called: std::sync::atomic::AtomicBool,
        }

        impl KeyProvider for MissingKeyProvider {
            fn load(&self) -> Result<Option<VaultKey>, StoreError> {
                Ok(None)
            }

            fn create(&self) -> Result<VaultKey, StoreError> {
                self.create_called
                    .store(true, std::sync::atomic::Ordering::Relaxed);
                Ok(Zeroizing::new([99_u8; 32]))
            }
        }

        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("afterray.sqlite3"), b"existing-vault").unwrap();
        let provider = MissingKeyProvider {
            create_called: std::sync::atomic::AtomicBool::new(false),
        };
        let result = Vault::open(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_unstarred_moments: 10,
            },
            &provider,
        );
        assert!(matches!(result, Err(StoreError::MissingVaultKey)));
        assert!(
            !provider
                .create_called
                .load(std::sync::atomic::Ordering::Relaxed)
        );
    }

    #[test]
    fn encrypted_artifact_round_trip_has_no_plaintext() {
        let (directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"private-screen-text")
            .unwrap();
        let on_disk = fs::read(vault.artifact_path(&moment.image_artifact_id)).unwrap();
        assert_eq!(&on_disk[..4], ARTIFACT_MAGIC);
        assert!(
            !on_disk
                .windows(19)
                .any(|window| window == b"private-screen-text")
        );
        let (wrapped_key, wrapping_nonce): (Vec<u8>, Vec<u8>) = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT wrapped_key, wrapping_nonce FROM artifacts WHERE id = ?1",
                [&moment.image_artifact_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(wrapped_key.len(), WRAPPED_DEK_LENGTH);
        assert_eq!(wrapping_nonce.len(), NONCE_LENGTH);
        assert!(
            !on_disk
                .windows(wrapped_key.len())
                .any(|window| window == wrapped_key)
        );
        let payload = vault.read_artifact(&moment.image_artifact_id).unwrap();
        assert_eq!(payload.bytes, b"private-screen-text");
        drop(directory);
    }

    #[test]
    fn artifact_ciphertext_is_bound_to_immutable_metadata() {
        let (_directory, vault) = test_vault(10);
        let encrypted = encrypt_artifact(
            &vault.artifact_wrap_key,
            "artifact-1",
            "image/jpeg",
            b"secret",
        )
        .unwrap();
        assert!(matches!(
            decrypt_artifact(
                &vault.artifact_wrap_key,
                "artifact-2",
                "image/jpeg",
                &encrypted.bytes,
                &encrypted.wrapped_dek,
                &encrypted.wrapping_nonce,
            ),
            Err(StoreError::Crypto)
        ));
        assert!(matches!(
            decrypt_artifact(
                &vault.artifact_wrap_key,
                "artifact-1",
                "audio/mp4",
                &encrypted.bytes,
                &encrypted.wrapped_dek,
                &encrypted.wrapping_nonce,
            ),
            Err(StoreError::Crypto)
        ));
    }

    #[test]
    fn legacy_database_key_is_rekeyed_to_domain_separated_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("afterray.sqlite3");
        let master_key = [19_u8; 32];
        let legacy = Connection::open(&path).unwrap();
        legacy
            .execute_batch(&format!(
                "PRAGMA key = \"x'{}'\";
                 CREATE TABLE legacy_marker (value TEXT NOT NULL);
                 INSERT INTO legacy_marker VALUES ('preserved');",
                encode_hex(&master_key)
            ))
            .unwrap();
        drop(legacy);

        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_unstarred_moments: 10,
            },
            master_key,
        )
        .unwrap();
        let marker: String = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT value FROM legacy_marker", [], |row| row.get(0))
            .unwrap();
        assert_eq!(marker, "preserved");
        drop(vault);

        assert!(open_keyed_database(&path, &master_key).is_err());
        let database_key = blake3::derive_key(DATABASE_KEY_CONTEXT, &master_key);
        assert!(open_keyed_database(&path, &database_key).is_ok());
    }

    #[test]
    fn legacy_artifact_is_migrated_without_plaintext() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            max_unstarred_moments: 10,
        };
        let master_key = [23_u8; 32];
        let vault = Vault::open_with_key(config.clone(), master_key).unwrap();
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"original")
            .unwrap();
        let id = moment.image_artifact_id;
        let legacy = encrypt_legacy_for_test(&master_key, &id, "image/jpeg", b"legacy-secret");
        fs::remove_file(vault.artifact_path(&id)).unwrap();
        fs::write(vault.legacy_artifact_path(&id), legacy).unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE artifacts
                    SET format_version = 0, wrapped_key = NULL, wrapping_nonce = NULL
                  WHERE id = ?1",
                [&id],
            )
            .unwrap();
        drop(vault);

        let migrated = Vault::open_with_key(config, master_key).unwrap();
        let payload_before_migration = migrated.read_artifact(&id).unwrap();
        assert_eq!(payload_before_migration.bytes, b"legacy-secret");
        assert_eq!(migrated.migrate_legacy_artifacts().unwrap(), 1);
        assert!(!migrated.legacy_artifact_path(&id).exists());
        assert_eq!(
            &fs::read(migrated.artifact_path(&id)).unwrap()[..4],
            ARTIFACT_MAGIC
        );
        let payload = migrated.read_artifact(&id).unwrap();
        assert_eq!(payload.bytes, b"legacy-secret");
    }

    fn encrypt_legacy_for_test(
        key: &[u8; 32],
        id: &str,
        content_type: &str,
        bytes: &[u8],
    ) -> Vec<u8> {
        let cipher = XChaCha20Poly1305::new(key.into());
        let nonce = [31_u8; NONCE_LENGTH];
        let aad = format!("{id}:{content_type}");
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: bytes,
                    aad: aad.as_bytes(),
                },
            )
            .unwrap();
        [LEGACY_ARTIFACT_MAGIC.as_slice(), &nonce, &ciphertext].concat()
    }

    #[test]
    fn timeline_spans_sessions_in_capture_order() {
        let (_directory, vault) = test_vault(10);
        let first_session = vault.create_session_sync(100).unwrap();
        let first = vault
            .insert_moment(&first_session.id, 110, "image/jpeg", b"first")
            .unwrap();
        let second_session = vault.create_session_sync(200).unwrap();
        let second = vault
            .insert_moment(&second_session.id, 210, "image/jpeg", b"second")
            .unwrap();

        let timeline = vault.timeline_sync().unwrap();
        assert_eq!(
            timeline
                .iter()
                .map(|moment| moment.id.as_str())
                .collect::<Vec<_>>(),
            [first.id.as_str(), second.id.as_str()]
        );
        assert_eq!(
            vault
                .timeline_since_sync(200)
                .unwrap()
                .iter()
                .map(|moment| moment.id.as_str())
                .collect::<Vec<_>>(),
            [second.id.as_str()]
        );
    }

    #[test]
    fn orphaned_sessions_close_at_next_start_or_last_moment() {
        let (_directory, vault) = test_vault(10);
        let first_session = vault.create_session_sync(100).unwrap();
        vault
            .insert_moment(&first_session.id, 150, "image/jpeg", b"first")
            .unwrap();
        let second_session = vault.create_session_sync(200).unwrap();
        vault
            .insert_moment(&second_session.id, 250, "image/jpeg", b"second")
            .unwrap();

        assert_eq!(vault.close_orphaned_sessions_sync(300).unwrap(), 2);
        let sessions = vault.sessions_sync().unwrap();
        let first = sessions
            .iter()
            .find(|session| session.id == first_session.id)
            .unwrap();
        let second = sessions
            .iter()
            .find(|session| session.id == second_session.id)
            .unwrap();
        assert_eq!(first.ended_at_ms, Some(200));
        assert_eq!(second.ended_at_ms, Some(250));
        assert_eq!(vault.close_orphaned_sessions_sync(400).unwrap(), 0);
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
