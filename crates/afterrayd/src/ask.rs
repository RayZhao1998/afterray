use afterray_models::{JobState, ModelInput, ModelOutput, ModelQueue, QueueError};
use afterray_protocol::{
    AskAnswer, AskCitation, ModelLibrary, Moment, Response, SearchHit, local_calendar_day_bounds_ms,
};
use afterray_store::Vault;
use chrono::Local;
use std::fmt::Write as _;

use crate::search_hits;

const CONTEXT_CHAR_CAP: usize = 10_000;
const SEARCH_HIT_LIMIT: usize = 6;
const CITATION_LIMIT: usize = 3;
const EXCERPT_CHAR_CAP: usize = 180;
const IDLE_GAP_MS: i64 = 30_000;
const CAPTURE_INTERVAL_MS: i64 = 10_000;

const ASK_SYSTEM_PROMPT: &str = "You are AfterRay, a local memory assistant for this computer. \
Answer only from the provided evidence. If the evidence does not contain the answer, say you do not know. \
When you refer to a specific time or event, cite its moment id. Be concise. Never invent missing evidence.";

const MODEL_MISSING_MESSAGE: &str = "The local language model is not installed. Open Settings to download the LLM pack, then ask again.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ActivitySpan {
    pub start_ms: i64,
    pub end_ms: i64,
    pub application_name: String,
    pub bundle_identifier: Option<String>,
    pub moment_id: String,
    pub excerpt: String,
}

#[must_use]
pub(crate) fn llm_pack_present(library: &ModelLibrary) -> bool {
    library
        .packs
        .iter()
        .any(|pack| pack.id == "llm" && pack.present)
}

pub(crate) fn resolve_ask_range(
    from_ms: Option<i64>,
    to_ms: Option<i64>,
    now_ms: i64,
) -> (i64, i64) {
    let (today_start, today_end) = local_calendar_day_bounds_ms(now_ms);
    let from = from_ms.unwrap_or(today_start);
    let to = to_ms.unwrap_or(today_end);
    if from <= to { (from, to) } else { (to, from) }
}

pub(crate) fn moments_in_range(moments: &[Moment], from_ms: i64, to_ms: i64) -> Vec<Moment> {
    moments
        .iter()
        .filter(|moment| moment.captured_at_ms >= from_ms && moment.captured_at_ms <= to_ms)
        .cloned()
        .collect()
}

pub(crate) fn hits_in_range(hits: &[SearchHit], from_ms: i64, to_ms: i64) -> Vec<SearchHit> {
    hits.iter()
        .filter(|hit| hit.captured_at_ms >= from_ms && hit.captured_at_ms <= to_ms)
        .cloned()
        .collect()
}

pub(crate) fn synthesize_activity_spans(moments: &[Moment]) -> Vec<ActivitySpan> {
    if moments.is_empty() {
        return Vec::new();
    }
    let mut spans = Vec::new();
    let mut run_start = 0;
    for index in 1..=moments.len() {
        let at_end = index == moments.len();
        let idle_ahead = !at_end
            && moments[index].captured_at_ms - moments[index - 1].captured_at_ms > IDLE_GAP_MS;
        let identity_changed =
            !at_end && app_identity(&moments[index]) != app_identity(&moments[run_start]);
        if !(at_end || idle_ahead || identity_changed) {
            continue;
        }
        let last = &moments[index - 1];
        let end_ms = if at_end {
            last.captured_at_ms.saturating_add(CAPTURE_INTERVAL_MS)
        } else if idle_ahead {
            last.captured_at_ms
                .saturating_add(CAPTURE_INTERVAL_MS)
                .min(moments[index].captured_at_ms)
        } else {
            moments[index].captured_at_ms
        };
        let first = &moments[run_start];
        spans.push(ActivitySpan {
            start_ms: first.captured_at_ms,
            end_ms,
            application_name: first
                .application_name
                .clone()
                .unwrap_or_else(|| "Unknown app".to_owned()),
            bundle_identifier: first.bundle_identifier.clone(),
            moment_id: first.id.clone(),
            excerpt: first_excerpt(&moments[run_start..index]),
        });
        run_start = index;
    }
    spans
}

fn app_identity(moment: &Moment) -> (Option<&str>, Option<&str>) {
    (
        moment.application_name.as_deref(),
        moment.bundle_identifier.as_deref(),
    )
}

fn first_excerpt(moments: &[Moment]) -> String {
    moments
        .iter()
        .find_map(|moment| {
            nonempty_excerpt(moment.ocr_text.as_deref())
                .or_else(|| nonempty_excerpt(moment.transcript_text.as_deref()))
        })
        .unwrap_or_default()
}

fn nonempty_excerpt(text: Option<&str>) -> Option<String> {
    let trimmed = text?.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(truncate_chars(trimmed, EXCERPT_CHAR_CAP))
    }
}

pub(crate) fn truncate_chars(text: &str, max_chars: usize) -> String {
    if max_chars == 0 {
        return String::new();
    }
    let count = text.chars().count();
    if count <= max_chars {
        return text.to_owned();
    }
    if max_chars == 1 {
        return "…".to_owned();
    }
    let taken: String = text.chars().take(max_chars - 1).collect();
    format!("{taken}…")
}

pub(crate) fn build_ask_context(
    question: &str,
    from_ms: i64,
    to_ms: i64,
    spans: &[ActivitySpan],
    hits: &[SearchHit],
) -> String {
    let mut body = String::new();
    body.push_str("Question: ");
    body.push_str(question.trim());
    body.push_str("\n\nTime range (local): ");
    body.push_str(&format_local_ms(from_ms));
    body.push_str(" – ");
    body.push_str(&format_local_ms(to_ms));
    body.push('\n');

    if spans.is_empty() {
        if !push_capped(&mut body, "\nActivity: none recorded in this range.\n") {
            return body;
        }
    } else if !push_capped(&mut body, "\nActivity:\n") {
        return body;
    } else {
        for span in spans {
            let line = format!(
                "- [{}–{}] {} moment={}\n",
                format_clock_ms(span.start_ms),
                format_clock_ms(span.end_ms),
                span.application_name,
                span.moment_id
            );
            if !push_capped(&mut body, &line) {
                return body;
            }
            if !span.excerpt.is_empty() {
                let excerpt = format!("  excerpt: {}\n", span.excerpt);
                if !push_capped(&mut body, &excerpt) {
                    return body;
                }
            }
        }
    }

    if hits.is_empty() {
        let _ = push_capped(&mut body, "\nEvidence: no search hits in this range.\n");
    } else if push_capped(&mut body, "\nEvidence:\n") {
        for hit in hits.iter().take(SEARCH_HIT_LIMIT) {
            let line = format!(
                "- moment={} at {} ({}): {}\n",
                hit.moment_id,
                format_clock_ms(hit.captured_at_ms),
                hit.source,
                truncate_chars(hit.text.trim(), EXCERPT_CHAR_CAP)
            );
            if !push_capped(&mut body, &line) {
                return body;
            }
        }
    }
    body
}

fn push_capped(buffer: &mut String, addition: &str) -> bool {
    if buffer.chars().count() >= CONTEXT_CHAR_CAP {
        return false;
    }
    let remaining = CONTEXT_CHAR_CAP.saturating_sub(buffer.chars().count());
    if addition.chars().count() <= remaining {
        buffer.push_str(addition);
        true
    } else {
        buffer.push_str(&truncate_chars(addition, remaining));
        false
    }
}

pub(crate) fn citations_from_evidence(
    spans: &[ActivitySpan],
    hits: &[SearchHit],
) -> Vec<AskCitation> {
    let mut citations = Vec::new();
    for hit in hits.iter().take(SEARCH_HIT_LIMIT) {
        if hit.moment_id.is_empty() {
            continue;
        }
        let label = spans
            .iter()
            .find(|span| span.moment_id == hit.moment_id)
            .map(|span| span.application_name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| {
                if hit.source.is_empty() {
                    "Moment".to_owned()
                } else {
                    hit.source.clone()
                }
            });
        citations.push(AskCitation {
            moment_id: hit.moment_id.clone(),
            captured_at_ms: hit.captured_at_ms,
            label,
            excerpt: truncate_chars(hit.text.trim(), EXCERPT_CHAR_CAP),
        });
        if citations.len() >= CITATION_LIMIT {
            return citations;
        }
    }
    for span in spans {
        if citations
            .iter()
            .any(|citation| citation.moment_id == span.moment_id)
        {
            continue;
        }
        citations.push(AskCitation {
            moment_id: span.moment_id.clone(),
            captured_at_ms: span.start_ms,
            label: span.application_name.clone(),
            excerpt: span.excerpt.clone(),
        });
        if citations.len() >= CITATION_LIMIT {
            break;
        }
    }
    citations
}

fn format_local_ms(ms: i64) -> String {
    datetime_local(ms).map_or_else(
        || ms.to_string(),
        |dt| dt.format("%Y-%m-%d %H:%M").to_string(),
    )
}

fn format_clock_ms(ms: i64) -> String {
    datetime_local(ms).map_or_else(|| ms.to_string(), |dt| dt.format("%H:%M").to_string())
}

fn datetime_local(ms: i64) -> Option<chrono::DateTime<Local>> {
    chrono::DateTime::from_timestamp_millis(ms).map(|dt| dt.with_timezone(&Local))
}

fn model_missing_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("model asset is missing")
        || lower.contains("missing model")
        || lower.contains("download the llm")
        || lower.contains("set afterray_llm_model")
}

fn missing_model_answer(spans: &[ActivitySpan]) -> AskAnswer {
    let mut answer = MODEL_MISSING_MESSAGE.to_owned();
    if !spans.is_empty() {
        answer.push_str("\n\nRecorded in this range:");
        for span in spans.iter().take(8) {
            let _ = write!(
                answer,
                "\n• {}–{} {}",
                format_clock_ms(span.start_ms),
                format_clock_ms(span.end_ms),
                span.application_name
            );
        }
    }
    AskAnswer {
        answer,
        citations: citations_from_evidence(spans, &[]),
        model_missing: true,
    }
}

pub(crate) async fn handle_ask(
    store: &Vault,
    models: &ModelQueue,
    question: &str,
    from_ms: Option<i64>,
    to_ms: Option<i64>,
    now_ms: i64,
    llm_present: bool,
) -> Response {
    let question = question.trim();
    if question.is_empty() {
        return Response::failure("question must not be empty");
    }
    let (from_ms, to_ms) = resolve_ask_range(from_ms, to_ms, now_ms);

    let moments = match store.timeline_since_sync(from_ms) {
        Ok(moments) => moments_in_range(&moments, from_ms, to_ms),
        Err(error) => return Response::failure(error.to_string()),
    };
    let spans = synthesize_activity_spans(&moments);

    let search =
        match search_hits(store, models, question, SEARCH_HIT_LIMIT.saturating_mul(2)).await {
            Ok(hits) => hits_in_range(&hits, from_ms, to_ms),
            Err(error) => {
                eprintln!("ask search failed; continuing without hits: {error}");
                Vec::new()
            }
        };
    let hits: Vec<SearchHit> = search.into_iter().take(SEARCH_HIT_LIMIT).collect();
    let citations = citations_from_evidence(&spans, &hits);

    if !llm_present {
        return Response::success(missing_model_answer(&spans));
    }

    if spans.is_empty() && hits.is_empty() {
        return Response::success(AskAnswer {
            answer: "I don't have any recorded moments for this time range yet.".to_owned(),
            citations,
            model_missing: false,
        });
    }

    let prompt = build_ask_context(question, from_ms, to_ms, &spans, &hits);
    let job_id = match models
        .submit(ModelInput::Llm {
            prompt,
            system: Some(ASK_SYSTEM_PROMPT.to_owned()),
        })
        .await
    {
        Ok(id) => id,
        Err(QueueError::MissingAdapter(_)) => {
            return Response::success(missing_model_answer(&spans));
        }
        Err(error) => return Response::failure(error.to_string()),
    };

    match models.wait(&job_id).await {
        Ok(snapshot) if snapshot.state == JobState::Done => {
            let answer = match snapshot.output {
                Some(ModelOutput::Llm { text }) if !text.trim().is_empty() => {
                    text.trim().to_owned()
                }
                Some(ModelOutput::Llm { .. }) => {
                    "The local model returned an empty answer.".to_owned()
                }
                _ => return Response::failure("ask job returned the wrong output type"),
            };
            Response::success(AskAnswer {
                answer,
                citations,
                model_missing: false,
            })
        }
        Ok(snapshot) => {
            let error = snapshot
                .last_error
                .unwrap_or_else(|| "ask job did not complete".to_owned());
            if model_missing_error(&error) {
                Response::success(missing_model_answer(&spans))
            } else {
                Response::failure(error)
            }
        }
        Err(error) => Response::failure(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_models::{
        ModelAdapter, ModelCapability, ModelQueue, ProcessAdapter, ProcessAdapterConfig,
        QueueConfig,
    };
    use afterray_protocol::ModelPack;
    use afterray_store::{Vault, VaultConfig};
    use std::sync::Arc;

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

    fn queue(adapters: Vec<Arc<dyn ModelAdapter>>) -> ModelQueue {
        ModelQueue::new(adapters, QueueConfig::default()).unwrap()
    }

    fn moment(
        id: &str,
        captured_at_ms: i64,
        application_name: Option<&str>,
        ocr: Option<&str>,
    ) -> Moment {
        Moment {
            id: id.to_owned(),
            session_id: "s1".to_owned(),
            captured_at_ms,
            image_artifact_id: None,
            is_favorite: false,
            ocr_text: ocr.map(ToOwned::to_owned),
            transcript_text: None,
            audio_artifact_id: None,
            audio_started_at_ms: None,
            accessibility_artifact_id: None,
            application_name: application_name.map(ToOwned::to_owned),
            bundle_identifier: application_name.map(|name| format!("app.{name}")),
            gop: None,
            still_origin: "capture".to_owned(),
        }
    }

    #[test]
    fn llm_pack_present_requires_installed_llm() {
        let missing = ModelLibrary {
            directory: "/tmp".into(),
            packs: vec![ModelPack {
                id: "llm".into(),
                name: "Local LLM".into(),
                capability: "llm".into(),
                path: "/tmp/missing.gguf".into(),
                present: false,
                bytes: 0,
                required: false,
                note: None,
                expected_bytes: None,
            }],
            download: None,
        };
        assert!(!llm_pack_present(&missing));
        let mut present = missing.clone();
        present.packs[0].present = true;
        assert!(llm_pack_present(&present));
    }

    #[test]
    fn omitted_range_uses_local_today() {
        let now = 1_786_694_400_000;
        let (from, to) = resolve_ask_range(None, None, now);
        let (today_from, today_to) = local_calendar_day_bounds_ms(now);
        assert_eq!((from, to), (today_from, today_to));
        let (explicit_from, explicit_to) = resolve_ask_range(Some(10), Some(5), now);
        assert_eq!((explicit_from, explicit_to), (5, 10));
    }

    #[test]
    fn synthesizes_coarse_spans_and_splits_idle_gaps() {
        let moments = vec![
            moment("m1", 0, Some("Safari"), Some("inbox")),
            moment("m2", 10_000, Some("Safari"), None),
            moment("m3", 20_000, Some("Xcode"), Some("fn main")),
            moment("m4", 80_000, Some("Xcode"), Some("tests")),
        ];
        let spans = synthesize_activity_spans(&moments);
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[0].application_name, "Safari");
        assert_eq!(spans[0].moment_id, "m1");
        assert_eq!(spans[0].excerpt, "inbox");
        assert_eq!(spans[1].application_name, "Xcode");
        assert_eq!(spans[1].start_ms, 20_000);
        assert_eq!(spans[2].start_ms, 80_000);
        assert!(spans[1].end_ms <= 80_000);
    }

    #[test]
    fn context_stays_under_char_cap() {
        let spans: Vec<ActivitySpan> = (0..80)
            .map(|index| ActivitySpan {
                start_ms: i64::from(index) * 60_000,
                end_ms: i64::from(index) * 60_000 + 50_000,
                application_name: format!("App{index}"),
                bundle_identifier: None,
                moment_id: format!("m{index}"),
                excerpt: "x".repeat(200),
            })
            .collect();
        let hits: Vec<SearchHit> = (0..12)
            .map(|index| SearchHit {
                moment_id: format!("h{index}"),
                session_id: "s1".into(),
                captured_at_ms: i64::from(index) * 1_000,
                source: "ocr".into(),
                text: "y".repeat(400),
                score: 1.0,
            })
            .collect();
        let context = build_ask_context("what", 0, 10, &spans, &hits);
        assert!(context.chars().count() <= CONTEXT_CHAR_CAP);
        assert!(context.contains("Question: what"));
    }

    #[test]
    fn citations_prefer_search_hits() {
        let spans = [ActivitySpan {
            start_ms: 1,
            end_ms: 2,
            application_name: "Safari".into(),
            bundle_identifier: None,
            moment_id: "m1".into(),
            excerpt: "inbox".into(),
        }];
        let hits = [SearchHit {
            moment_id: "m2".into(),
            session_id: "s1".into(),
            captured_at_ms: 9,
            source: "ocr".into(),
            text: "design review notes".into(),
            score: 2.0,
        }];
        let citations = citations_from_evidence(&spans, &hits);
        assert_eq!(citations.len(), 2);
        assert_eq!(citations[0].moment_id, "m2");
        assert_eq!(citations[0].excerpt, "design review notes");
        assert_eq!(citations[1].moment_id, "m1");
    }

    #[tokio::test]
    async fn missing_llm_pack_returns_ok_with_flag() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(
            &vault,
            &queue(Vec::new()),
            "我今天做了什么",
            Some(0),
            Some(10),
            5,
            false,
        )
        .await;
        assert!(response.ok);
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(answer.model_missing);
        assert!(answer.answer.contains("Settings"));
    }

    #[tokio::test]
    async fn empty_question_fails() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(&vault, &queue(Vec::new()), "   ", None, None, 1, true).await;
        assert!(!response.ok);
    }

    #[tokio::test]
    async fn empty_range_returns_no_evidence_without_llm() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(
            &vault,
            &queue(Vec::new()),
            "what did I do",
            Some(0),
            Some(10),
            5,
            true,
        )
        .await;
        assert!(response.ok);
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(!answer.model_missing);
        assert!(answer.answer.contains("don't have any recorded moments"));
    }

    #[tokio::test]
    async fn ask_uses_mock_llm_and_range_hits() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1_000).unwrap();
        let first = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"one")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/vnd.afterray.ax+json",
                br#"{"app":"Safari"}"#,
                Some("Safari"),
                Some("com.apple.Safari"),
            )
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                Some(&first.id),
                None,
                "ocr",
                "reviewed the design doc",
                1_000,
                None,
                "ocr-model",
            )
            .unwrap();

        let script = r#"
import json, sys
req = json.load(sys.stdin)
assert "AfterRay" in (req.get("input") or {}).get("system", "") or True
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "llm", "text": "You reviewed a design doc."},
  "retryable": False
}))
"#;
        let mut config =
            ProcessAdapterConfig::new("test-llm", ModelCapability::Llm, "/usr/bin/python3");
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let models = queue(vec![Arc::new(ProcessAdapter::new(config))]);

        let response =
            handle_ask(&vault, &models, "design", Some(0), Some(2_000), 1_500, true).await;
        assert!(response.ok, "{response:?}");
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(!answer.model_missing);
        assert_eq!(answer.answer, "You reviewed a design doc.");
        assert!(!answer.citations.is_empty());
        assert_eq!(answer.citations[0].moment_id, first.id);
    }
}
