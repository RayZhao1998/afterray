use afterray_protocol::{ModelLibrary, ModelPack};
use std::path::{Path, PathBuf};

/// Hugging Face snapshot (many files) or a single downloadable weight file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackSource {
    HuggingFaceSnapshot { repository: String },
    HuggingFaceFile { repository: String, file: String },
}

/// One user-visible model pack. Paths and repositories can be overridden
/// with `AFTERRAY_*` environment variables so the daemon never hard-codes a
/// single checkpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackSpec {
    pub id: String,
    pub name: String,
    pub capability: String,
    pub path: PathBuf,
    pub required: bool,
    pub note: String,
    pub expected_bytes: u64,
    pub source: PackSource,
}

impl PackSpec {
    #[must_use]
    pub fn inspect(&self) -> ModelPack {
        let (present, bytes) = inspect_model_path(&self.path);
        ModelPack {
            id: self.id.clone(),
            name: self.name.clone(),
            capability: self.capability.clone(),
            path: self.path.display().to_string(),
            present,
            bytes,
            required: self.required,
            note: Some(self.note.clone()),
            expected_bytes: Some(self.expected_bytes),
        }
    }
}

#[must_use]
pub fn model_directory() -> PathBuf {
    if let Some(path) = std::env::var_os("AFTERRAY_MODEL_DIR") {
        return PathBuf::from(path);
    }
    if let Some(path) = std::env::var_os("AFTERRAY_ASR_MODEL") {
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

#[must_use]
pub fn default_catalog() -> Vec<PackSpec> {
    catalog_in(&model_directory())
}

#[must_use]
pub fn catalog_in(directory: &Path) -> Vec<PackSpec> {
    vec![
        PackSpec {
            id: "asr".into(),
            name: "Qwen3 ASR".into(),
            capability: "asr".into(),
            path: env_or_join("AFTERRAY_ASR_MODEL", directory, "Qwen3-ASR-1.7B"),
            required: true,
            note: format!(
                "{} · official safetensors · ZH/EN/JA · Rust/Candle",
                env_or("AFTERRAY_ASR_REPOSITORY", "Qwen/Qwen3-ASR-1.7B")
            ),
            expected_bytes: 4_200_000_000,
            source: PackSource::HuggingFaceSnapshot {
                repository: env_or("AFTERRAY_ASR_REPOSITORY", "Qwen/Qwen3-ASR-1.7B"),
            },
        },
        PackSpec {
            id: "embedding".into(),
            name: "Text embeddings".into(),
            capability: "embedding".into(),
            path: env_or_join(
                "AFTERRAY_EMBEDDING_MODEL",
                directory,
                "nomic-embed-text-v1.5.Q4_K_M.gguf",
            ),
            required: true,
            note: "nomic-embed-text v1.5 Q4 · llama.cpp".into(),
            expected_bytes: 84_000_000,
            source: PackSource::HuggingFaceFile {
                repository: env_or(
                    "AFTERRAY_EMBEDDING_REPOSITORY",
                    "nomic-ai/nomic-embed-text-v1.5-GGUF",
                ),
                file: env_or(
                    "AFTERRAY_EMBEDDING_FILE",
                    "nomic-embed-text-v1.5.Q4_K_M.gguf",
                ),
            },
        },
        llm_pack_from(
            directory,
            &env_or("AFTERRAY_LLM_REPOSITORY", FALLBACK_LLM_REPOSITORY),
            &env_or("AFTERRAY_LLM_FILE", FALLBACK_LLM_FILE),
            std::env::var_os("AFTERRAY_LLM_MODEL")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
        ),
    ]
}

/// Known-good instruct GGUF used until Qwen3.8-27B weights are published.
/// Production retargets with `AFTERRAY_LLM_REPOSITORY` + `AFTERRAY_LLM_FILE`
/// (and optionally `AFTERRAY_LLM_MODEL`) — no protocol change.
pub const FALLBACK_LLM_REPOSITORY: &str = "Qwen/Qwen2.5-3B-Instruct-GGUF";
pub const FALLBACK_LLM_FILE: &str = "qwen2.5-3b-instruct-q4_k_m.gguf";

/// Approximate size of the fallback 3B Q4 GGUF. Kept as `expected_bytes` so
/// today's download progress stays accurate.
const FALLBACK_LLM_EXPECTED_BYTES: u64 = 2_000_000_000;

/// Approximate on-disk size of a 27B Q4 GGUF. Documented for Settings; not
/// used as download `expected_bytes` so the 3B fallback still reports
/// correctly. Qwen3.8-Max 2.4T is not a local target.
pub const QWEN38_27B_Q4_EXPECTED_BYTES: u64 = 16_000_000_000;

/// Builds the optional assistant pack. `file` is both the Hugging Face
/// filename and the local basename unless `model_path` overrides the path.
#[must_use]
pub fn llm_pack_from(
    directory: &Path,
    repository: &str,
    file: &str,
    model_path: Option<PathBuf>,
) -> PackSpec {
    PackSpec {
        id: "llm".into(),
        name: "Qwen3.8 27B".into(),
        capability: "llm".into(),
        path: model_path.unwrap_or_else(|| directory.join(file)),
        required: false,
        note: format!(
            "Powers overlay Q&A · optional for capture. Qwen3.8-27B (~{} GB Q4, not Qwen3.8-Max) via AFTERRAY_LLM_REPOSITORY / AFTERRAY_LLM_FILE when the GGUF lands. Download fallback is Qwen2.5-3B Instruct Q4.",
            QWEN38_27B_Q4_EXPECTED_BYTES / 1_000_000_000
        ),
        expected_bytes: FALLBACK_LLM_EXPECTED_BYTES,
        source: PackSource::HuggingFaceFile {
            repository: repository.to_owned(),
            file: file.to_owned(),
        },
    }
}

#[must_use]
pub fn library() -> ModelLibrary {
    library_in(&model_directory())
}

#[must_use]
pub fn library_in(directory: &Path) -> ModelLibrary {
    ModelLibrary {
        directory: directory.display().to_string(),
        packs: catalog_in(directory)
            .into_iter()
            .map(|spec| spec.inspect())
            .collect(),
        download: None,
    }
}

#[must_use]
pub fn spec_by_id(id: &str) -> Option<PackSpec> {
    default_catalog().into_iter().find(|spec| spec.id == id)
}

/// Lists packs that should be downloaded.
///
/// # Errors
///
/// Returns an error when `pack_id` is not in the catalog.
pub fn specs_for_download(pack_id: Option<&str>) -> Result<Vec<PackSpec>, String> {
    specs_for_download_in(&model_directory(), pack_id)
}

/// Lists packs under `directory` that should be downloaded.
///
/// # Errors
///
/// Returns an error when `pack_id` is not in the catalog.
pub fn specs_for_download_in(
    directory: &Path,
    pack_id: Option<&str>,
) -> Result<Vec<PackSpec>, String> {
    let catalog = catalog_in(directory);
    match pack_id {
        None => Ok(catalog
            .into_iter()
            .filter(|spec| !inspect_model_path(&spec.path).0)
            .collect()),
        Some(id) => catalog
            .into_iter()
            .find(|spec| spec.id == id)
            .map(|spec| vec![spec])
            .ok_or_else(|| format!("unknown model pack `{id}`")),
    }
}

#[must_use]
pub fn inspect_model_path(path: &Path) -> (bool, u64) {
    if path.is_file() {
        return (
            true,
            std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0),
        );
    }
    if path.is_dir() {
        return (snapshot_is_ready(path), directory_size(path));
    }
    (false, 0)
}

fn snapshot_is_ready(path: &Path) -> bool {
    if !path.join("config.json").is_file() {
        return false;
    }
    let has_tokenizer = path.join("tokenizer.json").is_file()
        || path.join("tokenizer.model").is_file()
        || path.join("vocab.json").is_file();
    has_tokenizer && has_complete_weight(path)
}

fn has_complete_weight(path: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(path) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let child = entry.path();
        if child.is_dir() {
            return has_complete_weight(&child);
        }
        let name = child
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if name.ends_with(".partial") {
            return false;
        }
        Path::new(name).extension().is_some_and(|ext| {
            ext.eq_ignore_ascii_case("safetensors")
                || ext.eq_ignore_ascii_case("gguf")
                || ext.eq_ignore_ascii_case("bin")
        })
    })
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

fn env_or(key: &str, fallback: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}

fn env_or_join(key: &str, directory: &Path, file_name: &str) -> PathBuf {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map_or_else(|| directory.join(file_name), PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn catalog_has_asr_embedding_and_optional_llm() {
        let catalog = catalog_in(Path::new("/tmp/afterray-models"));
        let ids: Vec<_> = catalog.iter().map(|spec| spec.id.as_str()).collect();
        assert_eq!(ids, ["asr", "embedding", "llm"]);
        assert!(catalog[0].required);
        assert!(catalog[1].required);
        assert!(!catalog[2].required);
        assert_eq!(catalog[2].name, "Qwen3.8 27B");
        assert!(catalog[2].note.contains("overlay Q&A"));
        assert!(catalog[2].note.contains("optional"));
        assert_eq!(catalog[2].expected_bytes, FALLBACK_LLM_EXPECTED_BYTES);
        assert!(catalog[2].expected_bytes < QWEN38_27B_Q4_EXPECTED_BYTES);
        assert_eq!(
            catalog[2].path,
            Path::new("/tmp/afterray-models").join(FALLBACK_LLM_FILE)
        );
        assert!(matches!(
            catalog[0].source,
            PackSource::HuggingFaceSnapshot { .. }
        ));
        assert!(matches!(
            catalog[1].source,
            PackSource::HuggingFaceFile { .. }
        ));
        assert_eq!(
            catalog[2].source,
            PackSource::HuggingFaceFile {
                repository: FALLBACK_LLM_REPOSITORY.into(),
                file: FALLBACK_LLM_FILE.into(),
            }
        );
    }

    #[test]
    fn llm_repository_and_file_retarget_download_without_protocol_change() {
        let pack = llm_pack_from(
            Path::new("/tmp/afterray-models"),
            "org/Qwen3.8-27B-GGUF",
            "Qwen3.8-27B-Q4_K_M.gguf",
            None,
        );
        assert_eq!(pack.id, "llm");
        assert!(!pack.required);
        assert_eq!(
            pack.path,
            PathBuf::from("/tmp/afterray-models/Qwen3.8-27B-Q4_K_M.gguf")
        );
        assert_eq!(
            pack.source,
            PackSource::HuggingFaceFile {
                repository: "org/Qwen3.8-27B-GGUF".into(),
                file: "Qwen3.8-27B-Q4_K_M.gguf".into(),
            }
        );
        assert_eq!(pack.expected_bytes, FALLBACK_LLM_EXPECTED_BYTES);
    }

    #[test]
    fn llm_model_path_override_wins_over_file_name() {
        let pack = llm_pack_from(
            Path::new("/tmp/afterray-models"),
            FALLBACK_LLM_REPOSITORY,
            "Qwen3.8-27B-Q4_K_M.gguf",
            Some(PathBuf::from("/custom/weights.gguf")),
        );
        assert_eq!(pack.path, PathBuf::from("/custom/weights.gguf"));
        assert_eq!(
            pack.source,
            PackSource::HuggingFaceFile {
                repository: FALLBACK_LLM_REPOSITORY.into(),
                file: "Qwen3.8-27B-Q4_K_M.gguf".into(),
            }
        );
    }

    #[test]
    fn inspects_files_and_snapshots() {
        let root = std::env::temp_dir().join(format!("afterray-catalog-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("snap")).unwrap();
        fs::write(root.join("snap/config.json"), "{}").unwrap();
        fs::write(root.join("snap/tokenizer.json"), "{}").unwrap();
        fs::write(root.join("snap/model.safetensors"), [0_u8; 8]).unwrap();
        fs::create_dir_all(root.join("incomplete")).unwrap();
        fs::write(root.join("incomplete/config.json"), "{}").unwrap();
        fs::write(root.join("incomplete/model.safetensors.partial"), [0_u8; 8]).unwrap();
        fs::write(root.join("weights.gguf"), [0_u8; 32]).unwrap();

        assert_eq!(inspect_model_path(&root.join("weights.gguf")), (true, 32));
        let (present, bytes) = inspect_model_path(&root.join("snap"));
        assert!(present);
        assert!(bytes >= 2);
        assert!(!inspect_model_path(&root.join("incomplete")).0);
        assert_eq!(inspect_model_path(&root.join("missing")), (false, 0));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unknown_pack_is_an_error() {
        let error = specs_for_download(Some("nope")).unwrap_err();
        assert!(error.contains("unknown model pack"));
    }
}
