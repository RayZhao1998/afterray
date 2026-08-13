use crate::missing_model;
use afterray_models::AdapterError;
use llama_cpp_2::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{AddBos, LlamaModel, params::LlamaModelParams},
    sampling::LlamaSampler,
};
use std::{num::NonZeroU32, path::Path, sync::OnceLock};

fn backend() -> Result<&'static LlamaBackend, AdapterError> {
    static BACKEND: OnceLock<Result<LlamaBackend, String>> = OnceLock::new();
    match BACKEND.get_or_init(|| LlamaBackend::init().map_err(|error| error.to_string())) {
        Ok(backend) => Ok(backend),
        Err(error) => Err(AdapterError::Process(error.clone())),
    }
}

pub fn generate(
    model_path: &Path,
    prompt: &str,
    system: Option<&str>,
) -> Result<String, AdapterError> {
    if !model_path.is_file() {
        return Err(missing_model(
            model_path,
            "set AFTERRAY_LLM_MODEL or download the LLM pack",
        ));
    }
    let backend = backend()?;
    let params = LlamaModelParams::default().with_n_gpu_layers(1_000);
    let model = LlamaModel::load_from_file(backend, model_path, &params)
        .map_err(|error| AdapterError::Process(format!("could not load LLM: {error}")))?;
    let ctx_params = LlamaContextParams::default().with_n_ctx(NonZeroU32::new(4_096));
    let mut ctx = model
        .new_context(backend, ctx_params)
        .map_err(|error| AdapterError::Process(format!("LLM context failed: {error}")))?;

    let mut composed = String::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        composed.push_str("System:\n");
        composed.push_str(system);
        composed.push_str("\n\nUser:\n");
    }
    composed.push_str(prompt);

    let tokens = model
        .str_to_token(&composed, AddBos::Always)
        .map_err(|error| AdapterError::Process(format!("could not tokenize prompt: {error}")))?;
    if tokens.is_empty() {
        return Err(AdapterError::InvalidOutput(
            "LLM produced no prompt tokens".into(),
        ));
    }

    let mut batch = LlamaBatch::new(512, 1);
    let last = tokens.len() - 1;
    for (index, token) in tokens.iter().enumerate() {
        batch
            .add(
                *token,
                i32::try_from(index).unwrap_or(0),
                &[0],
                index == last,
            )
            .map_err(|error| AdapterError::Process(format!("LLM batch failed: {error}")))?;
    }
    ctx.decode(&mut batch)
        .map_err(|error| AdapterError::Process(format!("LLM prefill failed: {error}")))?;

    let mut sampler = LlamaSampler::greedy();
    let max_tokens = std::env::var("AFTERRAY_LLM_MAX_TOKENS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(512_u32);
    let mut pieces = String::new();
    let mut decoder = encoding_rs::UTF_8.new_decoder();
    let mut n_cur = i32::try_from(tokens.len()).unwrap_or(0);
    let eos = model.token_eos();
    for _ in 0..max_tokens {
        let token = sampler.sample(&ctx, -1);
        sampler.accept(token);
        if token == eos {
            break;
        }
        let piece = model
            .token_to_piece(token, &mut decoder, false, None)
            .map_err(|error| AdapterError::Process(format!("LLM decode failed: {error}")))?;
        pieces.push_str(&piece);
        batch.clear();
        batch
            .add(token, n_cur, &[0], true)
            .map_err(|error| AdapterError::Process(format!("LLM batch failed: {error}")))?;
        n_cur += 1;
        ctx.decode(&mut batch)
            .map_err(|error| AdapterError::Process(format!("LLM decode failed: {error}")))?;
    }
    Ok(pieces.trim().to_owned())
}
