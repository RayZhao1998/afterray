//! Background Dual GOP packer. Encode is never on the capture hot path.

use afterray_codec::{
    Av1Encoder, CONTENT_TYPE_IVF_AV01, DEFAULT_KEYINT, EncodedGop, GopFrameInput, Rav1eEncoder,
    jpeg_to_i420, parse_ivf, slice_ivf,
};
use afterray_protocol::{ArtifactPayload, GopReadMode};
use afterray_store::{
    GopCommitFrame, GopCommitRequest, PackCandidate, PackPolicy, StoreError, Vault, fold_pack_runs,
};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

#[derive(Debug, Clone)]
pub struct GopPackerConfig {
    pub archive: bool,
    pub keep_stills: bool,
    pub require_ac: bool,
    pub policy: PackPolicy,
}

impl GopPackerConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let keyint = std::env::var("AFTERRAY_GOP_KEYINT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(DEFAULT_KEYINT);
        let keyint = if keyint == 6 || keyint == 12 { keyint } else { DEFAULT_KEYINT };
        let hot_window_seconds = std::env::var("AFTERRAY_GOP_HOT_WINDOW_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(7_200_u64)
            .clamp(3_600, 7_200);
        Self {
            archive: env_flag("AFTERRAY_GOP_ARCHIVE", false),
            keep_stills: env_flag("AFTERRAY_GOP_KEEP_STILLS", true),
            require_ac: env_flag("AFTERRAY_GOP_REQUIRE_AC", true),
            policy: PackPolicy {
                hot_window_ms: i64::try_from(hot_window_seconds.saturating_mul(1000))
                    .unwrap_or(7_200_000),
                hot_min_stills: std::env::var("AFTERRAY_GOP_HOT_MIN_STILLS")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(360),
                ocr_grace_ms: i64::from(
                    std::env::var("AFTERRAY_GOP_OCR_GRACE_SECONDS")
                        .ok()
                        .and_then(|value| value.parse().ok())
                        .unwrap_or(600_u32),
                ) * 1000,
                keyint,
            },
        }
    }
}

fn env_flag(name: &str, default: bool) -> bool {
    std::env::var(name)
        .ok()
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes"))
        .unwrap_or(default)
}

pub struct GopPacker {
    pub config: GopPackerConfig,
    encode_busy: AtomicBool,
}

impl GopPacker {
    #[must_use]
    pub fn new(config: GopPackerConfig) -> Self {
        Self {
            config,
            encode_busy: AtomicBool::new(false),
        }
    }

    #[must_use]
    pub fn encode_busy(&self) -> bool {
        self.encode_busy.load(Ordering::SeqCst)
    }

    pub fn pack_one(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        if !self.config.archive {
            return Ok(None);
        }
        if self.config.require_ac && !afterray_platform_macos::on_ac_power() {
            return Ok(None);
        }
        if self
            .encode_busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(None);
        }
        let result = self.pack_one_inner(vault, now_ms);
        self.encode_busy.store(false, Ordering::SeqCst);
        result
    }

    fn pack_one_inner(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        let candidates = vault.list_pack_candidates(now_ms, &self.config.policy)?;
        let runs = fold_pack_runs(&candidates, self.config.policy.keyint);
        let Some(run) = runs.into_iter().find(|run| run.len() >= 2) else {
            return Ok(None);
        };
        let moment_ids: Vec<String> = run.iter().map(|frame| frame.id.clone()).collect();
        let payload = json!({
            "moment_ids": moment_ids,
            "keyint": self.config.policy.keyint,
            "encoder": "rav1e",
        });
        let job_id = vault.insert_pack_job(now_ms, &payload.to_string())?;
        match encode_run(vault, &run) {
            Ok(encoded) => {
                let frames: Vec<GopCommitFrame> = encoded
                    .frames
                    .iter()
                    .map(|frame| GopCommitFrame {
                        index: frame.index,
                        is_keyframe: frame.is_keyframe,
                        byte_offset: frame.byte_offset,
                        byte_length: frame.byte_length,
                        content_hash: frame.content_hash,
                    })
                    .collect();
                let content_hash = hash_hex(blake3::hash(&encoded.ivf).as_bytes());
                match vault.commit_gop(GopCommitRequest {
                    moment_ids: &moment_ids,
                    ivf: &encoded.ivf,
                    codec: encoded.codec,
                    encoder: &encoded.encoder,
                    encoder_version: &encoded.encoder_version,
                    width: encoded.width,
                    height: encoded.height,
                    keyint: encoded.keyint,
                    content_hash: &content_hash,
                    frames: &frames,
                }) {
                    Ok(segment_id) => {
                        if let Err(error) = verify_gop(vault, &segment_id, &encoded) {
                            let _ = vault.finish_pack_job(
                                &job_id,
                                now_ms,
                                Some(&segment_id),
                                Some(&error.to_string()),
                            );
                            return Err(error);
                        }
                        vault.finish_pack_job(&job_id, now_ms, Some(&segment_id), None)?;
                        if !self.config.keep_stills
                            && let Err(error) = vault.drop_unpinned_stills(&segment_id)
                        {
                            eprintln!("gop packer: drop stills failed for {segment_id}: {error}");
                        }
                        Ok(Some(segment_id))
                    }
                    Err(StoreError::GopStale) => {
                        vault.finish_pack_job(
                            &job_id,
                            now_ms,
                            None,
                            Some("retention raced the commit"),
                        )?;
                        Ok(None)
                    }
                    Err(error) => {
                        vault.finish_pack_job(&job_id, now_ms, None, Some(&error.to_string()))?;
                        Err(error.into())
                    }
                }
            }
            Err(error) => {
                vault.finish_pack_job(&job_id, now_ms, None, Some(&error.to_string()))?;
                Err(error)
            }
        }
    }
}

fn encode_run(vault: &Vault, run: &[PackCandidate]) -> Result<EncodedGop, anyhow::Error> {
    let mut planes = Vec::with_capacity(run.len());
    let mut inputs = Vec::with_capacity(run.len());
    for frame in run {
        let still = vault.read_artifact(&frame.image_artifact_id)?;
        let (width, height, yuv) = jpeg_to_i420(&still.bytes)?;
        if width != frame.width || height != frame.height {
            anyhow::bail!(
                "decoded {}x{} but SOF was {}x{}",
                width,
                height,
                frame.width,
                frame.height
            );
        }
        planes.push((frame.id.clone(), frame.captured_at_ms, width, height, yuv));
    }
    for plane in &planes {
        inputs.push(GopFrameInput {
            moment_id: plane.0.as_str(),
            captured_at_ms: plane.1,
            width: plane.2,
            height: plane.3,
            yuv: plane.4.as_slice(),
        });
    }
    let started = Instant::now();
    let encoded = Rav1eEncoder::default().encode_closed_gop(&inputs)?;
    eprintln!(
        "gop pack: {} frames {}x{} in {:.1}s ({:.0} ms/frame)",
        encoded.frames.len(),
        encoded.width,
        encoded.height,
        started.elapsed().as_secs_f32(),
        started.elapsed().as_secs_f32() * 1000.0 / encoded.frames.len() as f32
    );
    Ok(encoded)
}

fn verify_gop(vault: &Vault, segment_id: &str, encoded: &EncodedGop) -> Result<(), anyhow::Error> {
    let payload = vault.read_gop_artifact(segment_id)?;
    let parsed = parse_ivf(&payload.bytes)?;
    if !payload.bytes.starts_with(afterray_codec::IVF_MAGIC) {
        anyhow::bail!("packed GOP is not IVF");
    }
    if parsed.frames.is_empty() {
        anyhow::bail!("packed GOP has no frames");
    }
    let expected = encoded.frames[0].content_hash;
    let actual = *blake3::hash(&parsed.frames[0].data).as_bytes();
    if expected != actual {
        anyhow::bail!("packed GOP keyframe hash mismatch");
    }
    Ok(())
}

pub fn read_gop_frame(
    vault: &Vault,
    segment_id: &str,
    index: u16,
    mode: GopReadMode,
) -> Result<ArtifactPayload, StoreError> {
    let frames = vault.live_gop_frames(segment_id)?;
    if !frames.iter().any(|frame| frame.index == index) {
        return Err(StoreError::GopNotFound(format!(
            "{segment_id}#{index}"
        )));
    }
    let payload = vault.read_gop_artifact(segment_id)?;
    let last = match mode {
        GopReadMode::Poster => 0,
        GopReadMode::Exact => usize::from(index),
    };
    let sliced = slice_ivf(&payload.bytes, last).map_err(|_| StoreError::Crypto)?;
    Ok(ArtifactPayload {
        id: payload.id.clone(),
        content_type: CONTENT_TYPE_IVF_AV01.to_owned(),
        bytes: sliced,
    })
}

fn hash_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}
