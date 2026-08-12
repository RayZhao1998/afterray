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
    Timeline {
        #[arg(long)]
        since_ms: Option<i64>,
    },
    Search {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    Favorite {
        #[command(subcommand)]
        command: FavoriteCommand,
    },
    Models,
    Jobs {
        #[command(subcommand)]
        command: JobsCommand,
    },
    Summarize {
        session_id: String,
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let socket = cli
        .socket
        .unwrap_or_else(|| std::env::temp_dir().join("afterray-v0.sock"));
    let request = match cli.command {
        Command::Daemon {
            command: DaemonCommand::Start,
        } => {
            let status = ProcessCommand::new("afterrayd")
                .env("AFTERRAY_SOCKET", &socket)
                .status()
                .context("start afterrayd; ensure it is installed or available on PATH")?;
            if !status.success() {
                anyhow::bail!("afterrayd exited with {status}");
            }
            return Ok(());
        }
        Command::Status => Request::Status,
        Command::Record {
            command: RecordCommand::Start,
        } => Request::RecordStart,
        Command::Record {
            command: RecordCommand::Stop,
        } => Request::RecordStop,
        Command::Sessions {
            command: SessionsCommand::List,
        } => Request::SessionsList,
        Command::Moments { session_id } => Request::MomentsList { session_id },
        Command::Timeline { since_ms: None } => Request::TimelineList,
        Command::Timeline {
            since_ms: Some(since_ms),
        } => Request::TimelineSince { since_ms },
        Command::Search { query, limit } => Request::Search { query, limit },
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
        Command::Models => Request::ModelsStatus,
        Command::Jobs {
            command: JobsCommand::List,
        } => Request::JobsList,
        Command::Jobs {
            command: JobsCommand::Retry { job_id },
        } => Request::JobRetry { job_id },
        Command::Summarize { session_id } => Request::Summarize { session_id },
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
