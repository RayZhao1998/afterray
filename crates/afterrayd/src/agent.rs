//! Minimal read-only tool loop for Ask and memory generation.

use afterray_models::{JobState, ModelInput, ModelOutput, ModelQueue, QueueError};
use serde_json::Value;

use crate::tools::{ToolHost, tool_catalog_text};

const MAX_ROUNDS: usize = 5;
const MAX_HISTORY_CHARS: usize = 14_000;

#[derive(Debug)]
pub enum AgentError {
    MissingModel,
    Failed(String),
}

impl std::fmt::Display for AgentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingModel => write!(f, "language model is not available"),
            Self::Failed(message) => write!(f, "{message}"),
        }
    }
}

/// Runs a short tool-using loop. The model must answer with TOOL/ARGS or FINAL.
pub async fn run_readonly_agent(
    models: &ModelQueue,
    tools: &ToolHost<'_>,
    system: &str,
    user: &str,
) -> Result<String, AgentError> {
    let mut transcript = format!("User task:\n{user}\n");
    let system = format!("{system}\n\n{}", tool_catalog_text());

    for round in 0..MAX_ROUNDS {
        let prompt = if transcript.chars().count() > MAX_HISTORY_CHARS {
            let kept: String = transcript
                .chars()
                .skip(transcript.chars().count() - MAX_HISTORY_CHARS)
                .collect();
            format!("…(earlier tool transcript truncated)…\n{kept}")
        } else {
            transcript.clone()
        };

        let text = match generate(models, &prompt, &system).await {
            Ok(text) => text,
            Err(AgentError::MissingModel) => return Err(AgentError::MissingModel),
            Err(error) => return Err(error),
        };

        if let Some(answer) = parse_final(&text) {
            return Ok(answer);
        }
        if let Some((name, args)) = parse_tool_call(&text) {
            let result = match tools.invoke(&name, &args).await {
                Ok(result) => result,
                Err(error) => format!("ERROR: {error}"),
            };
            let _ = writeln_tool(&mut transcript, &name, &args, &result);
            if round + 1 == MAX_ROUNDS {
                return Ok(format!(
                    "I reached the tool limit before finishing. Last tool `{name}` returned:\n{result}"
                ));
            }
            continue;
        }
        // Local models sometimes ignore the schema — accept bare text as the answer.
        if !text.trim().is_empty() {
            return Ok(text.trim().to_owned());
        }
        return Err(AgentError::Failed("model returned empty output".into()));
    }
    Err(AgentError::Failed("agent loop exhausted".into()))
}

async fn generate(models: &ModelQueue, prompt: &str, system: &str) -> Result<String, AgentError> {
    let job_id = match models
        .submit(ModelInput::Llm {
            prompt: prompt.to_owned(),
            system: Some(system.to_owned()),
        })
        .await
    {
        Ok(id) => id,
        Err(QueueError::MissingAdapter(_)) => return Err(AgentError::MissingModel),
        Err(error) => return Err(AgentError::Failed(error.to_string())),
    };
    let snapshot = models
        .wait(&job_id)
        .await
        .map_err(|error| AgentError::Failed(error.to_string()))?;
    if snapshot.state != JobState::Done {
        let error = snapshot
            .last_error
            .unwrap_or_else(|| format!("llm job ended as {:?}", snapshot.state));
        if error.to_ascii_lowercase().contains("missing")
            || error.to_ascii_lowercase().contains("not configured")
        {
            return Err(AgentError::MissingModel);
        }
        return Err(AgentError::Failed(error));
    }
    match snapshot.output {
        Some(ModelOutput::Llm { text }) if !text.trim().is_empty() => Ok(text),
        Some(ModelOutput::Llm { .. }) => Err(AgentError::Failed("empty llm text".into())),
        _ => Err(AgentError::Failed("wrong llm output type".into())),
    }
}

fn parse_final(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let upper = trimmed.to_ascii_uppercase();
    if let Some(rest) = upper.strip_prefix("FINAL") {
        let original_rest = &trimmed[trimmed.len() - rest.len()..];
        let body = original_rest
            .trim_start_matches([':', ' ', '\n', '\r', '\t'])
            .trim();
        if body.is_empty() {
            return None;
        }
        return Some(body.to_owned());
    }
    None
}

fn parse_tool_call(text: &str) -> Option<(String, Value)> {
    let trimmed = text.trim();
    let mut name: Option<String> = None;
    let mut args_raw: Option<String> = None;
    for line in trimmed.lines() {
        let line = line.trim();
        let upper = line.to_ascii_uppercase();
        if let Some(rest) = upper.strip_prefix("TOOL") {
            let original = line[line.len() - rest.len()..].trim_start_matches([':', ' ', '\t']);
            if !original.is_empty() {
                name = Some(original.to_owned());
            }
        } else if let Some(rest) = upper.strip_prefix("ARGS") {
            let original = line[line.len() - rest.len()..].trim_start_matches([':', ' ', '\t']);
            args_raw = Some(original.to_owned());
        }
    }
    // Multi-line ARGS: everything after first ARGS line
    if args_raw.is_none() {
        if let Some(pos) = trimmed.to_ascii_uppercase().find("ARGS") {
            let after = &trimmed[pos + 4..];
            let after = after.trim_start_matches([':', ' ', '\n', '\r', '\t']);
            if after.starts_with('{') {
                args_raw = Some(after.to_owned());
            }
        }
    }
    let name = name?;
    let args_raw = args_raw.unwrap_or_else(|| "{}".to_owned());
    // Take first JSON object if model appended prose
    let json_slice = extract_json_object(&args_raw).unwrap_or(args_raw.as_str());
    let args = serde_json::from_str(json_slice).unwrap_or_else(|_| Value::Object(Default::default()));
    Some((name, args))
}

fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0i32;
    for (idx, ch) in text[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + idx + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

fn writeln_tool(transcript: &mut String, name: &str, args: &Value, result: &str) {
    use std::fmt::Write as _;
    let _ = writeln!(transcript, "\nAssistant called TOOL {name}");
    let _ = writeln!(transcript, "ARGS {args}");
    let _ = writeln!(transcript, "Tool result:\n{result}\n");
    let _ = writeln!(
        transcript,
        "Continue. Call another TOOL or answer with FINAL."
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_final_block() {
        assert_eq!(
            parse_final("FINAL\nYou used Safari.").as_deref(),
            Some("You used Safari.")
        );
        assert_eq!(
            parse_final("FINAL: short answer").as_deref(),
            Some("short answer")
        );
    }

    #[test]
    fn parses_tool_call() {
        let (name, args) = parse_tool_call(
            "TOOL get_ocr\nARGS {\"moment_id\":\"m1\"}\n",
        )
        .unwrap();
        assert_eq!(name, "get_ocr");
        assert_eq!(args, json!({"moment_id":"m1"}));
    }

    #[test]
    fn extracts_json_with_trailing_prose() {
        let raw = r#"{"moment_id":"abc"} then more text"#;
        assert_eq!(extract_json_object(raw), Some(r#"{"moment_id":"abc"}"#));
    }
}
