use afterray_models::{download_packs, library_in, model_directory, specs_for_download_in};
use afterray_protocol::{Request, Response};
use anyhow::Context;
use clap::{Parser, Subcommand};
use std::{path::PathBuf, process::Command as ProcessCommand};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[derive(Parser)]
#[command(name = "afterray", version, about = "AfterRay V0 control client")]
struct Cli {
    #[arg(long, env = "AFTERRAY_SOCKET")]
    socket: Option<PathBuf>,
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Daemon {
        #[command(subcommand)]
        command: DaemonCommand,
    },
    Status,
    Record {
        #[command(subcommand)]
        command: RecordCommand,
    },
    Sessions {
        #[command(subcommand)]
        command: SessionsCommand,
    },
    Moments {
        session_id: String,
    },
    /// Fetch one moment by id (agent-friendly).
    Moment {
        moment_id: String,
    },
    Timeline {
        #[arg(long)]
        since_ms: Option<i64>,
    },
    Search {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long = "from-ms")]
        from_ms: Option<i64>,
        #[arg(long = "to-ms")]
        to_ms: Option<i64>,
    },
    /// Read OCR / accessibility evidence for a moment.
    Evidence {
        #[command(subcommand)]
        command: EvidenceCommand,
    },
    Activity {
        #[arg(long)]
        from_ms: i64,
        #[arg(long)]
        to_ms: i64,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    Memories {
        #[arg(long)]
        from_ms: i64,
        #[arg(long)]
        to_ms: i64,
        #[arg(long, default_value_t = 40)]
        limit: usize,
    },
    History {
        #[command(subcommand)]
        command: HistoryCommand,
    },
    Favorite {
        #[command(subcommand)]
        command: FavoriteCommand,
    },
    Models,
    Download {
        #[arg(long)]
        pack: Option<String>,
        #[arg(long, env = "AFTERRAY_MODEL_DIR")]
        dir: Option<PathBuf>,
    },
    Jobs {
        #[command(subcommand)]
        command: JobsCommand,
    },
    Summarize {
        session_id: String,
    },
    Ask {
        question: String,
        #[arg(long = "from-ms")]
        from_ms: Option<i64>,
        #[arg(long = "to-ms")]
        to_ms: Option<i64>,
    },
    Gop {
        segment_id: String,
    },
    Pack {
        #[command(subcommand)]
        command: PackCommand,
    },
}

#[derive(Subcommand)]
enum RecordCommand {
    Start,
    Stop,
}

#[derive(Subcommand)]
enum DaemonCommand {
    Start,
    Stop,
}

#[derive(Subcommand)]
enum SessionsCommand {
    List,
}

#[derive(Subcommand)]
enum FavoriteCommand {
    Add { moment_id: String },
    Remove { moment_id: String },
}

#[derive(Subcommand)]
enum JobsCommand {
    List,
    Retry { job_id: String },
}

#[derive(Subcommand)]
enum PackCommand {
    Status,
}

#[derive(Subcommand)]
enum EvidenceCommand {
    /// OCR text and bounding boxes for a moment.
    Ocr { moment_id: String },
    /// Accessibility digest (default) or full tree JSON.
    Ax {
        moment_id: String,
        /// Include the full accessibility tree JSON (large).
        #[arg(long)]
        full: bool,
    },
}

#[derive(Subcommand)]
enum HistoryCommand {
    Clear {
        #[arg(long, value_enum)]
        scope: HistoryScopeArg,
    },
}

#[derive(Clone, clap::ValueEnum)]
enum HistoryScopeArg {
    LastHour,
    Today,
    All,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let socket = cli
        .socket
        .unwrap_or_else(|| std::env::temp_dir().join("afterray-v0.sock"));
    let Some(request) = request_from_command(cli.command, &socket).await? else {
        return Ok(());
    };
    let response = send(&socket, &request).await?;
    if cli.json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else if response.ok {
        println!("{}", serde_json::to_string_pretty(&response.data)?);
    } else {
        anyhow::bail!(
            response
                .error
                .unwrap_or_else(|| "unknown daemon error".to_owned())
        );
    }
    Ok(())
}

async fn request_from_command(
    command: Command,
    socket: &PathBuf,
) -> anyhow::Result<Option<Request>> {
    Ok(Some(match command {
        Command::Daemon {
            command: DaemonCommand::Start,
        } => {
            let status = ProcessCommand::new("afterrayd")
                .env("AFTERRAY_SOCKET", socket)
                .status()
                .context("start afterrayd; ensure it is installed or available on PATH")?;
            if !status.success() {
                anyhow::bail!("afterrayd exited with {status}");
            }
            return Ok(None);
        }
        Command::Daemon {
            command: DaemonCommand::Stop,
        } => Request::Shutdown,
        Command::Status => Request::Status,
        Command::Record {
            command: RecordCommand::Start,
        } => Request::RecordStart,
        Command::Record {
            command: RecordCommand::Stop,
        } => Request::RecordStop { reason: None },
        Command::Sessions {
            command: SessionsCommand::List,
        } => Request::SessionsList,
        Command::Moments { session_id } => Request::MomentsList { session_id },
        Command::Moment { moment_id } => Request::MomentGet { moment_id },
        Command::Timeline { since_ms: None } => Request::TimelineList,
        Command::Timeline {
            since_ms: Some(since_ms),
        } => Request::TimelineSince { since_ms },
        Command::Search {
            query,
            limit,
            from_ms,
            to_ms,
        } => Request::Search {
            query,
            limit,
            from_ms,
            to_ms,
        },
        Command::Evidence {
            command: EvidenceCommand::Ocr { moment_id },
        } => Request::EvidenceOcr { moment_id },
        Command::Evidence {
            command: EvidenceCommand::Ax { moment_id, full },
        } => Request::EvidenceAx {
            moment_id,
            digest_only: !full,
        },
        Command::Activity {
            from_ms,
            to_ms,
            limit,
        } => Request::ActivitySpans {
            from_ms,
            to_ms,
            limit,
        },
        Command::Memories {
            from_ms,
            to_ms,
            limit,
        } => Request::MemoriesList {
            from_ms,
            to_ms,
            limit,
        },
        Command::History {
            command: HistoryCommand::Clear { scope },
        } => Request::ClearHistory {
            scope: match scope {
                HistoryScopeArg::LastHour => afterray_protocol::HistoryScope::LastHour,
                HistoryScopeArg::Today => afterray_protocol::HistoryScope::Today,
                HistoryScopeArg::All => afterray_protocol::HistoryScope::All,
            },
        },
        Command::Favorite {
            command: FavoriteCommand::Add { moment_id },
        } => Request::FavoriteSet {
            moment_id,
            favorite: true,
        },
        Command::Favorite {
            command: FavoriteCommand::Remove { moment_id },
        } => Request::FavoriteSet {
            moment_id,
            favorite: false,
        },
        Command::Download { pack, dir } => {
            run_local_download(pack, dir).await?;
            return Ok(None);
        }
        Command::Models => Request::ModelsStatus,
        Command::Jobs {
            command: JobsCommand::List,
        } => Request::JobsList,
        Command::Jobs {
            command: JobsCommand::Retry { job_id },
        } => Request::JobRetry { job_id },
        Command::Summarize { session_id } => Request::Summarize { session_id },
        Command::Ask {
            question,
            from_ms,
            to_ms,
        } => Request::Ask {
            question,
            from_ms,
            to_ms,
        },
        Command::Gop { segment_id } => Request::GopShow { segment_id },
        Command::Pack {
            command: PackCommand::Status,
        } => Request::PackStatus,
    }))
}

async fn run_local_download(pack: Option<String>, dir: Option<PathBuf>) -> anyhow::Result<()> {
    let directory = dir.unwrap_or_else(model_directory);
    let packs = specs_for_download_in(&directory, pack.as_deref()).map_err(anyhow::Error::msg)?;
    if packs.is_empty() {
        println!("{}", serde_json::to_string_pretty(&library_in(&directory))?);
        return Ok(());
    }
    download_packs(&packs, |spec, progress| {
        if let Some(percent) = progress.percent() {
            eprintln!("Downloading {} · {percent}%", spec.name);
        } else {
            eprintln!(
                "Downloading {} ({}/{} files)",
                spec.name, progress.completed_files, progress.total_files
            );
        }
    })
    .await?;
    println!("{}", serde_json::to_string_pretty(&library_in(&directory))?);
    Ok(())
}

async fn send(socket: &PathBuf, request: &Request) -> anyhow::Result<Response> {
    let mut stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connect to afterrayd at {}", socket.display()))?;
    let mut bytes = serde_json::to_vec(request)?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await?;
    Ok(serde_json::from_str(&line)?)
}
