//! Read-only history tools shared by CLI handlers and the internal agent loop.

use afterray_models::ModelQueue;
use afterray_protocol::{AxEvidence, Moment, OcrEvidence, OcrRegion};
use afterray_store::{Vault, parse_accessibility_digest};
use serde_json::{Value, json};

use crate::search_hits;

const DEFAULT_SEARCH_LIMIT: usize = 8;
const DEFAULT_LIST_LIMIT: usize = 40;
const MAX_TOOL_CHARS: usize = 6_000;

#[derive(Clone)]
pub struct ToolHost<'a> {
    pub store: &'a Vault,
    pub models: &'a ModelQueue,
}

impl ToolHost<'_> {
    pub async fn invoke(&self, name: &str, args: &Value) -> Result<String, String> {
        let result = match name {
            "search_evidence" => self.search_evidence(args).await,
            "list_activity" => self.list_activity(args),
            "list_memories" => self.list_memories(args),
            "list_moments" => self.list_moments(args),
            "get_transcript" => self.get_transcript(args),
            "get_slot_card" => self.get_slot_card(args),
            "get_moment" => self.get_moment(args),
            "get_ocr" => self.get_ocr(args),
            "get_ax_digest" => self.get_ax_digest(args),
            "get_ax_tree" => self.get_ax_tree(args),
            other => Err(format!("unknown tool `{other}`")),
        }?;
        Ok(truncate_tool_output(&result))
    }

    async fn search_evidence(&self, args: &Value) -> Result<String, String> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .ok_or_else(|| "search_evidence requires query".to_owned())?
            .trim();
        if query.is_empty() {
            return Err("search_evidence query must not be empty".into());
        }
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_SEARCH_LIMIT, |n| n as usize)
            .clamp(1, 20);
        let from_ms = args.get("from_ms").and_then(Value::as_i64);
        let to_ms = args.get("to_ms").and_then(Value::as_i64);
        let mut hits = search_hits(self.store, self.models, query, limit.saturating_mul(2))
            .await
            .map_err(|e| e.to_string())?;
        if let (Some(from), Some(to)) = (from_ms, to_ms) {
            let (from, to) = if from <= to { (from, to) } else { (to, from) };
            hits.retain(|hit| hit.captured_at_ms >= from && hit.captured_at_ms <= to);
        }
        hits.truncate(limit);
        Ok(serde_json::to_string_pretty(&hits).unwrap_or_else(|_| "[]".into()))
    }

    fn list_activity(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = range_args(args, DEFAULT_LIST_LIMIT, 200)?;
        let spans = self
            .store
            .activity_spans(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        Ok(serde_json::to_string_pretty(&spans).unwrap_or_else(|_| "[]".into()))
    }

    fn list_memories(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = range_args(args, DEFAULT_LIST_LIMIT, 100)?;
        let memories = self
            .store
            .memories(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        Ok(serde_json::to_string_pretty(&memories).unwrap_or_else(|_| "[]".into()))
    }

    /// Moments in a window: the bridge from "three o'clock yesterday" to
    /// the ids every other evidence tool needs.
    fn list_moments(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = range_args(args, DEFAULT_LIST_LIMIT, 200)?;
        let moments = self
            .store
            .moment_ids_in_range(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        let rows: Vec<Value> = moments
            .into_iter()
            .map(|(id, at_ms)| json!({"moment_id": id, "captured_at_ms": at_ms}))
            .collect();
        Ok(serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".into()))
    }

    /// Speech in a window. Transcripts hang off audio segments rather than
    /// moments, so without this a meeting is unreachable by time alone.
    fn get_transcript(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = range_args(args, 60, 400)?;
        let rows = self
            .store
            .transcripts_in_range(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if rows.is_empty() {
            return Ok("[] // no speech was recorded in this window".to_owned());
        }
        let items: Vec<Value> = rows
            .into_iter()
            .map(|(at_ms, track, text)| json!({"at_ms": at_ms, "track": track, "text": text}))
            .collect();
        Ok(serde_json::to_string_pretty(&items).unwrap_or_else(|_| "[]".into()))
    }

    /// The deterministic 30-minute card: application time, the run
    /// timeline with its deduplicated screen text, and revisits. One call
    /// covers a half hour that would otherwise take dozens of frame reads.
    fn get_slot_card(&self, args: &Value) -> Result<String, String> {
        let at_ms = args
            .get("at_ms")
            .and_then(Value::as_i64)
            .ok_or_else(|| "get_slot_card requires at_ms".to_owned())?;
        let card = self
            .store
            .slot_card(at_ms, 10_000)
            .map_err(|e| e.to_string())?;
        Ok(afterray_store::render_t2_prompt(&card, &[], "the user's language"))
    }

    fn get_moment(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let moment = self
            .store
            .moment_by_id(&moment_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("moment `{moment_id}` not found"))?;
        Ok(serde_json::to_string_pretty(&moment).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ocr(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ocr_evidence(self.store, &moment_id)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ax_digest(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ax_evidence(self.store, &moment_id, true)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ax_tree(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ax_evidence(self.store, &moment_id, false)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }
}

pub fn ocr_evidence(store: &Vault, moment_id: &str) -> Result<OcrEvidence, String> {
    let row = store
        .ocr_evidence_for_moment(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no OCR for moment `{moment_id}`"))?;
    let (text, layout_json) = row;
    let regions = layout_json
        .as_deref()
        .and_then(|raw| serde_json::from_str::<Vec<OcrRegion>>(raw).ok())
        .unwrap_or_default();
    Ok(OcrEvidence {
        moment_id: moment_id.to_owned(),
        text,
        regions,
    })
}

pub fn ax_evidence(store: &Vault, moment_id: &str, digest_only: bool) -> Result<AxEvidence, String> {
    let bytes = store
        .accessibility_bytes_for_moment(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no accessibility snapshot for moment `{moment_id}`"))?;
    let digest = parse_accessibility_digest(&bytes);
    let digest_value = serde_json::to_value(&json_digest(&digest)).ok();
    let tree_json = if digest_only {
        None
    } else {
        Some(String::from_utf8_lossy(&bytes).into_owned())
    };
    Ok(AxEvidence {
        moment_id: moment_id.to_owned(),
        digest: digest_value,
        tree_json,
    })
}

pub fn moment_detail(store: &Vault, moment_id: &str) -> Result<Moment, String> {
    store
        .moment_by_id(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("moment `{moment_id}` not found"))
}

fn json_digest(digest: &afterray_store::AccessibilityDigest) -> Value {
    json!({
        "application_name": digest.application_name,
        "bundle_identifier": digest.bundle_identifier,
        "window_title": digest.window_title,
        "url": digest.url,
        "document": digest.document,
        "focused_role": digest.focused_role,
        "focused_title": digest.focused_title,
        "focused_value": digest.focused_value,
        "selected_text": digest.selected_text,
        "headings": digest.headings,
        "visible_text": digest.visible_text,
        "compact": digest.compact_text(),
        "sufficient": digest_looks_sufficient(digest),
    })
}

/// Heuristic: enough structure to describe activity without OCR.
#[must_use]
pub fn digest_looks_sufficient(digest: &afterray_store::AccessibilityDigest) -> bool {
    if afterray_store::is_idle_digest(digest) {
        return false;
    }
    let has_place = digest.url.is_some()
        || digest.document.is_some()
        || digest
            .window_title
            .as_ref()
            .is_some_and(|t| t.len() >= 3 && t != "Weixin" && t != "WeChat");
    let has_focus = digest
        .focused_value
        .as_ref()
        .is_some_and(|v| v.chars().count() >= 8);
    let has_visible = digest.visible_text.iter().any(|t| t.chars().count() >= 8);
    has_place || has_focus || has_visible
}

fn require_moment_id(args: &Value) -> Result<String, String> {
    args.get("moment_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "moment_id is required".to_owned())
}

fn range_args(args: &Value, default_limit: usize, max_limit: usize) -> Result<(i64, i64, usize), String> {
    let from_ms = args
        .get("from_ms")
        .and_then(Value::as_i64)
        .ok_or_else(|| "from_ms is required".to_owned())?;
    let to_ms = args
        .get("to_ms")
        .and_then(Value::as_i64)
        .ok_or_else(|| "to_ms is required".to_owned())?;
    let (from_ms, to_ms) = if from_ms <= to_ms {
        (from_ms, to_ms)
    } else {
        (to_ms, from_ms)
    };
    let limit = args
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(default_limit, |n| n as usize)
        .clamp(1, max_limit);
    Ok((from_ms, to_ms, limit))
}

fn truncate_tool_output(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAX_TOOL_CHARS {
        return text.to_owned();
    }
    let taken: String = text.chars().take(MAX_TOOL_CHARS.saturating_sub(1)).collect();
    format!("{taken}…")
}

/// Catalog shown to the LLM in agent prompts.
#[must_use]
pub fn tool_catalog_text() -> &'static str {
    r#"Tools (call at most one per reply). Timestamps are Unix milliseconds.

Start wide, then narrow:
- get_slot_card: {"at_ms":0}
    A whole 30-minute window at once: which apps for how long, a timeline of
    what was open, the screen text each stretch introduced, and what the
    person kept returning to. Usually the cheapest way to answer "what was I
    doing around <time>".
- list_activity: {"from_ms":0,"to_ms":0,"limit":40}
    Application and document spans over a range — good for spotting when
    something started or stopped.
- search_evidence: {"query":"…","from_ms":0,"to_ms":0,"limit":8}
    Full-text and semantic search across captured screen text.
- list_memories: {"from_ms":0,"to_ms":0,"limit":40}
    Short notes already written for each stretch of activity.
- list_moments: {"from_ms":0,"to_ms":0,"limit":40}
    Capture ids and their timestamps — use when you know a time but need an
    id for the tools below.

Then, for one captured instant:
- get_moment: {"moment_id":"…"}       metadata, and transcript_text if any
- get_ocr: {"moment_id":"…"}          text read off the screen, with boxes
- get_ax_digest: {"moment_id":"…"}    compact accessibility summary
- get_ax_tree: {"moment_id":"…"}      full accessibility JSON (large; rare)

And for speech:
- get_transcript: {"from_ms":0,"to_ms":0,"limit":60}
    Everything said in a window, across microphone and system audio.

Reply format (exactly one):
TOOL <name>
ARGS <json object>

or

FINAL
<answer text>"#
}
