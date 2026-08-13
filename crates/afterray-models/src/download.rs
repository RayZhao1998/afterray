use crate::catalog::{PackSource, PackSpec, inspect_model_path};
use futures_util::StreamExt as _;
use serde::Deserialize;
use std::{
    fs, io,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncWriteExt as _;

#[derive(Debug, thiserror::Error)]
pub enum DownloadError {
    #[error("{0}")]
    Message(String),
    #[error("download I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("download request failed: {0}")]
    Http(String),
}

impl DownloadError {
    fn message(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DownloadProgress {
    pub completed_files: usize,
    pub total_files: usize,
    pub bytes: u64,
    pub expected_bytes: Option<u64>,
}

impl DownloadProgress {
    #[must_use]
    pub fn percent(self) -> Option<u8> {
        let expected = self.expected_bytes.filter(|value| *value > 0)?;
        let percent = self.bytes.saturating_mul(100) / expected;
        Some(u8::try_from(percent.min(100)).unwrap_or(100))
    }
}

/// Downloads every pack that is not already present.
///
/// # Errors
///
/// Returns a [`DownloadError`] when a listing or file transfer fails.
pub async fn download_packs(
    packs: &[PackSpec],
    mut on_progress: impl FnMut(&PackSpec, DownloadProgress),
) -> Result<(), DownloadError> {
    for pack in packs {
        download_pack(pack, |progress| on_progress(pack, progress)).await?;
    }
    Ok(())
}

/// Downloads one pack into `pack.path`.
///
/// # Errors
///
/// Returns a [`DownloadError`] when Hugging Face cannot be reached or the
/// destination cannot be written.
pub async fn download_pack(
    pack: &PackSpec,
    mut on_progress: impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
    if inspect_model_path(&pack.path).0 {
        let bytes = inspect_model_path(&pack.path).1;
        on_progress(DownloadProgress {
            completed_files: 1,
            total_files: 1,
            bytes,
            expected_bytes: Some(bytes.max(1)),
        });
        return Ok(());
    }
    match &pack.source {
        PackSource::HuggingFaceFile { repository, file } => {
            if let Some(parent) = pack.path.parent() {
                fs::create_dir_all(parent)?;
            }
            download_huggingface_file(repository, file, &pack.path, |bytes, expected| {
                on_progress(DownloadProgress {
                    completed_files: 0,
                    total_files: 1,
                    bytes,
                    expected_bytes: expected.or(Some(pack.expected_bytes)),
                });
            })
            .await?;
            let bytes = inspect_model_path(&pack.path).1;
            on_progress(DownloadProgress {
                completed_files: 1,
                total_files: 1,
                bytes,
                expected_bytes: Some(bytes.max(pack.expected_bytes)),
            });
        }
        PackSource::HuggingFaceSnapshot { repository } => {
            fs::create_dir_all(&pack.path)?;
            let files = list_huggingface_files(repository).await?;
            let total_files = files.len();
            if total_files == 0 {
                return Err(DownloadError::message(format!(
                    "Hugging Face repository `{repository}` listed no files"
                )));
            }
            let listed_total: u64 = files.iter().filter_map(|file| file.size).sum();
            let expected = if listed_total > 0 {
                Some(listed_total)
            } else {
                Some(pack.expected_bytes)
            };
            let mut finished_bytes = 0_u64;
            for (index, file) in files.iter().enumerate() {
                let destination = pack.path.join(&file.path);
                if destination.is_file() {
                    finished_bytes += file
                        .size
                        .unwrap_or_else(|| inspect_model_path(&destination).1);
                    on_progress(DownloadProgress {
                        completed_files: index + 1,
                        total_files,
                        bytes: finished_bytes,
                        expected_bytes: expected,
                    });
                    continue;
                }
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent)?;
                }
                download_huggingface_file(repository, &file.path, &destination, |written, _| {
                    on_progress(DownloadProgress {
                        completed_files: index,
                        total_files,
                        bytes: finished_bytes.saturating_add(written),
                        expected_bytes: expected,
                    });
                })
                .await?;
                finished_bytes += file
                    .size
                    .unwrap_or_else(|| inspect_model_path(&destination).1);
                on_progress(DownloadProgress {
                    completed_files: index + 1,
                    total_files,
                    bytes: finished_bytes,
                    expected_bytes: expected,
                });
            }
        }
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
struct HfTreeEntry {
    path: String,
    #[serde(rename = "type")]
    kind: String,
    size: Option<u64>,
    lfs: Option<HfLfs>,
}

#[derive(Debug, Deserialize)]
struct HfLfs {
    size: Option<u64>,
}

#[derive(Debug, Clone)]
struct HfFile {
    path: String,
    size: Option<u64>,
}

async fn list_huggingface_files(repository: &str) -> Result<Vec<HfFile>, DownloadError> {
    let url = format!("https://huggingface.co/api/models/{repository}/tree/main?recursive=1");
    let response = huggingface_client()?
        .get(url)
        .send()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
    if !response.status().is_success() {
        return Err(DownloadError::message(format!(
            "could not list `{repository}`: HTTP {}",
            response.status()
        )));
    }
    let entries: Vec<HfTreeEntry> = response
        .json()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
    Ok(entries
        .into_iter()
        .filter(|entry| entry.kind == "file")
        .map(|entry| HfFile {
            path: entry.path,
            size: entry.lfs.and_then(|lfs| lfs.size).or(entry.size),
        })
        .collect())
}

async fn download_huggingface_file(
    repository: &str,
    file: &str,
    destination: &Path,
    mut on_chunk: impl FnMut(u64, Option<u64>),
) -> Result<(), DownloadError> {
    let url = format!("https://huggingface.co/{repository}/resolve/main/{file}");
    let response = huggingface_client()?
        .get(&url)
        .send()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
    if !response.status().is_success() {
        return Err(DownloadError::message(format!(
            "download `{repository}/{file}` failed: HTTP {}",
            response.status()
        )));
    }
    let partial = partial_path(destination);
    if let Some(parent) = partial.parent() {
        fs::create_dir_all(parent)?;
    }
    let expected = response.content_length();
    let mut file = tokio::fs::File::create(&partial).await?;
    let mut stream = response.bytes_stream();
    let mut written = 0_u64;
    on_chunk(0, expected);
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| DownloadError::Http(error.to_string()))?;
        written = written.saturating_add(chunk.len() as u64);
        file.write_all(&chunk).await?;
        on_chunk(written, expected);
    }
    file.flush().await?;
    drop(file);
    fs::rename(partial, destination)?;
    Ok(())
}

fn huggingface_client() -> Result<reqwest::Client, DownloadError> {
    let mut headers = reqwest::header::HeaderMap::new();
    if let Ok(token) =
        std::env::var("HF_TOKEN").or_else(|_| std::env::var("HUGGING_FACE_HUB_TOKEN"))
    {
        let value = format!("Bearer {token}");
        headers.insert(
            reqwest::header::AUTHORIZATION,
            value
                .parse()
                .map_err(|_| DownloadError::message("HF_TOKEN is not a valid HTTP header value"))?,
        );
    }
    reqwest::Client::builder()
        .user_agent("afterray/0.0.1")
        .default_headers(headers)
        .redirect(reqwest::redirect::Policy::limited(16))
        .timeout(Duration::from_secs(60 * 30))
        .build()
        .map_err(|error| DownloadError::Http(error.to_string()))
}

fn partial_path(destination: &Path) -> PathBuf {
    let mut name = destination.file_name().unwrap_or_default().to_os_string();
    name.push(".partial");
    destination.with_file_name(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_files_sit_next_to_the_destination() {
        let path = Path::new("/tmp/models/weights.gguf");
        assert_eq!(
            partial_path(path),
            PathBuf::from("/tmp/models/weights.gguf.partial")
        );
    }

    #[test]
    fn percent_uses_expected_bytes() {
        let progress = DownloadProgress {
            completed_files: 0,
            total_files: 1,
            bytes: 42,
            expected_bytes: Some(100),
        };
        assert_eq!(progress.percent(), Some(42));
        assert_eq!(
            DownloadProgress {
                expected_bytes: None,
                ..progress
            }
            .percent(),
            None
        );
    }
}
