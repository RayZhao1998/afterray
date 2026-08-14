//! Builds T1 slot cards straight off a vault and prints the T2 prompt for each.
//!
//! This is the harness used to judge whether T1 extraction carries enough
//! signal and whether the prompt reads well, without touching a live daemon.
//!
//! ```sh
//! cargo run -p afterray-store --example slot_cards -- \
//!     --data-dir .afterray/v0-data --slots 4
//! ```
//!
//! `--json` emits one machine-readable record per slot (card + prompt) so a
//! summarising agent can be driven from the same output.

use afterray_store::{
    MacOsKeychainProvider, SLOT_DURATION_MS, T2_SYSTEM_PROMPT, Vault, VaultConfig, render_t2_prompt,
    slot_start_for,
};
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir = PathBuf::from(".afterray/v0-data");
    let mut slots = 4_usize;
    let mut at_ms: Option<i64> = None;
    let mut as_json = false;
    let mut only_ready = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = PathBuf::from(args.next().unwrap_or_default()),
            "--slots" => slots = args.next().unwrap_or_default().parse().unwrap_or(4),
            "--at-ms" => at_ms = args.next().and_then(|value| value.parse().ok()),
            "--json" => as_json = true,
            "--ready-only" => only_ready = true,
            other => eprintln!("ignoring unknown argument {other}"),
        }
    }

    let vault = Vault::open(
        VaultConfig {
            data_dir,
            ..VaultConfig::default()
        },
        &MacOsKeychainProvider,
    )?;

    let now_ms = at_ms.unwrap_or_else(|| {
        i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_millis())
                .unwrap_or_default(),
        )
        .unwrap_or_default()
    });

    let newest_start = slot_start_for(now_ms);
    let mut emitted = 0_usize;
    let mut index = 0_i64;
    // Walk backwards until we have `slots` cards, skipping empty windows.
    while emitted < slots && index < 96 {
        let slot_start = newest_start - index * SLOT_DURATION_MS;
        index += 1;
        let card = vault.slot_card(slot_start, 10_000)?;
        if card.facts.moment_count == 0 {
            continue;
        }
        if only_ready && card.state != afterray_store::SlotState::Ready {
            continue;
        }

        let episodes: Vec<(i64, String)> = vault
            .memories(card.slot_start_ms, card.slot_end_ms, 24)?
            .into_iter()
            .map(|memory| (memory.start_ms, memory.summary))
            .collect();
        let neighbours: Vec<(i64, String)> = vault
            .memories(
                card.slot_start_ms - SLOT_DURATION_MS,
                card.slot_start_ms,
                4,
            )?
            .into_iter()
            .map(|memory| (memory.start_ms, memory.summary))
            .collect();
        let user = render_t2_prompt(&card, &episodes, &neighbours);

        if as_json {
            let record = serde_json::json!({
                "card": card,
                "system": T2_SYSTEM_PROMPT,
                "user": user,
                "episode_count": episodes.len(),
            });
            println!("{}", serde_json::to_string(&record)?);
        } else {
            println!("════════════════════════════════════════════════════════════");
            println!(
                "slot {} {}  state={:?}  moments={}  ocr={}  theme={}",
                card.local_day,
                slot_label(card.slot_start_ms, card.slot_end_ms),
                card.state,
                card.facts.moment_count,
                card.facts.ocr_moment_count,
                card.theme_key.as_deref().unwrap_or("-"),
            );
            println!("────────────────────────── T2 prompt (user half) ───────────");
            println!("{user}");
        }
        emitted += 1;
    }

    if emitted == 0 {
        eprintln!("no slot in the scanned range held any captured moment");
    }
    Ok(())
}

fn slot_label(start_ms: i64, end_ms: i64) -> String {
    use chrono::Local;
    let format = |ms: i64| {
        chrono::DateTime::from_timestamp_millis(ms).map_or_else(
            || "??:??".to_owned(),
            |instant| instant.with_timezone(&Local).format("%H:%M").to_string(),
        )
    };
    format!("{}–{}", format(start_ms), format(end_ms))
}
