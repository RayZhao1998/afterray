use crate::missing_model;
use afterray_models::AdapterError;
use llama_cpp_2::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{AddBos, LlamaModel, params::LlamaModelParams},
};
use std::{num::NonZeroU32, path::Path, sync::OnceLock};

fn backend() -> Result<&'static LlamaBackend, AdapterError> {
    static BACKEND: OnceLock<Result<LlamaBackend, String>> = OnceLock::new();
    match BACKEND.get_or_init(|| LlamaBackend::init().map_err(|error| error.to_string())) {
        Ok(backend) => Ok(backend),
        Err(error) => Err(AdapterError::Process(error.clone())),
    }
}

pub fn embed_text(model_path: &Path, text: &str) -> Result<Vec<f32>, AdapterError> {
    if !model_path.is_file() {
        return Err(missing_model(
            model_path,
            "set AFTERRAY_EMBEDDING_MODEL or download the embedding pack",
        ));
    }
    let backend = backend()?;
    let params = LlamaModelParams::default().with_n_gpu_layers(1_000);
    let model = LlamaModel::load_from_file(backend, model_path, &params).map_err(|error| {
        AdapterError::Process(format!("could not load embedding model: {error}"))
    })?;
    // nomic-bert is an encoder: llama.cpp refuses to split the sequence, so
    // n_ubatch must be able to hold every token we submit.
    let max_tokens = 2_048_u32;
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(NonZeroU32::new(max_tokens))
        .with_n_batch(max_tokens)
        .with_n_ubatch(max_tokens)
        .with_embeddings(true);
    let mut ctx = model
        .new_context(backend, ctx_params)
        .map_err(|error| AdapterError::Process(format!("embedding context failed: {error}")))?;
    let mut tokens = model
        .str_to_token(text, AddBos::Always)
        .map_err(|error| AdapterError::Process(format!("could not tokenize text: {error}")))?;
    if tokens.is_empty() {
        return Err(AdapterError::InvalidOutput(
            "embedding model produced no tokens".into(),
        ));
    }
    tokens.truncate(usize::try_from(max_tokens).unwrap_or(tokens.len()));
    let mut batch = LlamaBatch::new(tokens.len(), 1);
    for (index, token) in tokens.into_iter().enumerate() {
        batch
            .add(token, i32::try_from(index).unwrap_or(0), &[0], true)
            .map_err(|error| AdapterError::Process(format!("embedding batch failed: {error}")))?;
    }
    ctx.decode(&mut batch)
        .map_err(|error| AdapterError::Process(format!("embedding decode failed: {error}")))?;
    let vector = ctx
        .embeddings_seq_ith(0)
        .map_err(|error| AdapterError::Process(format!("embedding extract failed: {error}")))?;
    Ok(normalize(vector))
}

fn normalize(vector: &[f32]) -> Vec<f32> {
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if norm == 0.0 {
        vector.to_vec()
    } else {
        vector.iter().map(|value| value / norm).collect()
    }
}
