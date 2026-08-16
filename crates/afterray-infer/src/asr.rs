use crate::{missing_model, sanitize_asr_text};
use afterray_models::AdapterError;
use std::path::Path;

const LANGUAGE_NAMES: &[(&str, &str)] = &[
    ("zh", "chinese"),
    ("zh-cn", "chinese"),
    ("zh-hans", "chinese"),
    ("cmn", "chinese"),
    ("yue", "cantonese"),
    ("zh-hk", "cantonese"),
    ("zh-yue", "cantonese"),
    ("en", "english"),
    ("ja", "japanese"),
    ("jp", "japanese"),
    ("ko", "korean"),
];

pub fn transcribe(
    model_dir: &Path,
    audio_path: &Path,
    language: Option<&str>,
) -> Result<(String, Option<String>), AdapterError> {
    if !model_dir.join("config.json").is_file() && !model_dir.is_file() {
        return Err(missing_model(
            model_dir,
            "set AFTERRAY_ASR_MODEL or download the Qwen3 ASR pack",
        ));
    }
    afterray_models::prepare_configured_qwen3_asr(model_dir).map_err(|error| {
        AdapterError::MissingModel(format!("Qwen3-ASR is not prepared: {error}"))
    })?;
    let samples = crate::audio::load_mono_16k(audio_path)?;
    if samples.is_empty() {
        return Ok((String::new(), language.map(ToOwned::to_owned)));
    }
    let language_name = language.and_then(canonical_language);
    let result = run_qwen3(model_dir, &samples, language_name.as_deref())?;
    Ok((
        sanitize_asr_text(&result.text),
        Some(result.language)
            .filter(|value| !value.is_empty())
            .or(language_name),
    ))
}

fn canonical_language(language: &str) -> Option<String> {
    let key = language.trim().to_ascii_lowercase();
    LANGUAGE_NAMES
        .iter()
        .find(|(alias, _)| *alias == key)
        .map(|(_, name)| (*name).to_owned())
        .or_else(|| {
            if language.trim().is_empty() {
                None
            } else {
                Some(language.trim().to_owned())
            }
        })
}

fn run_qwen3(
    model_dir: &Path,
    samples: &[f32],
    language: Option<&str>,
) -> Result<qwen3_asr::TranscribeResult, AdapterError> {
    let engine =
        qwen3_asr::AsrInference::load(model_dir, qwen3_asr::best_device()).map_err(|error| {
            afterray_models::invalidate_qwen3_asr_ready(model_dir);
            AdapterError::MissingModel(format!("could not load Qwen3-ASR: {error}"))
        })?;
    let mut options = qwen3_asr::TranscribeOptions::default();
    if let Some(language) = language {
        options.language = Some(language.to_owned());
    }
    engine
        .transcribe_samples(samples, options)
        .map_err(|error| AdapterError::Process(format!("Qwen3-ASR failed: {error}")))
}
