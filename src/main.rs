use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{CommandFactory, Parser};
use fyde_sdk::{ProgressEvent, init_dev_scrapers};
use serde::Deserialize;
use serde_json::Value;

/// Runs one or more Lua scraper scripts against `fyde-sdk`'s `scrapers`
/// service, outside of a full `Client`/server connection: cookies and
/// session data persist as JSON files (`fyde_sdk::init_dev_scrapers` always
/// selects its `scrapers::StorageConfig::File` backend — there is no local
/// SQLite database here to pick `Sqlite` instead), and scraped documents are
/// saved as plain files instead of being encrypted and uploaded. Ported from
/// `demo-rust-fyde`.
#[derive(Parser)]
struct Args {
    /// Names of the scrapers to run, each the name of a folder under
    /// `scripts/` containing a `script.lua` (e.g. `didaxis impots` runs
    /// `scripts/didaxis/script.lua` and `scripts/impots/script.lua`, in
    /// order). Prints the full `--help` text if none are given.
    scrapers: Vec<String>,

    /// Directory documents get saved into (gitignored).
    #[arg(long, default_value = "data/documents")]
    documents_dir: PathBuf,

    /// Directory scraper cookies/session data persist to across runs, as
    /// one JSON file per scraper under a `cookies`/`session` subdirectory
    /// respectively (gitignored; created on first run).
    #[arg(long, default_value = "data/")]
    storage: PathBuf,

    /// JSON file to read each scraper's parameters from, keyed by scraper
    /// name (the script's parent directory name). Gitignored - never commit
    /// real credentials in it.
    #[arg(long, default_value = "secret.json")]
    secrets: PathBuf,

    /// Force `debug_http_dump` on for every scraper run, regardless of what
    /// each entry in `--secrets` sets it to - recording all
    /// `fyde.http.get`/`post_form` response bodies in the run's debug
    /// report. Use while actively debugging a scraper's HTTP traffic.
    #[arg(long)]
    dev: bool,
}

/// One scraper's entry in `--secrets`. `parameters` is injected as-is (as a
/// Lua table) into the script's `run(parameters)` entrypoint - this program
/// never looks inside it, so each Lua script is free to read whatever
/// fields it needs (conventionally `username`/`password`) back out of it.
#[derive(Deserialize)]
struct ScraperConfig {
    parameters: Value,
    #[serde(default)]
    debug_http_dump: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    // `fyde.log.*` (see ../sdk/src/domains/scrapers/host/log.rs) forwards to
    // this crate's own `tracing` subscriber rather than printing directly -
    // a full `fyde_sdk::Client` installs one of these as part of `init`,
    // but this program never calls that, so it must install its own.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();

    if args.scrapers.is_empty() {
        Args::command().print_help()?;
        return Ok(());
    }

    for scraper_name in &args.scrapers {
        run_scraper(&args, scraper_name).await?;
    }

    Ok(())
}

/// Runs a single scraper by name: reads `scripts/<scraper_name>/script.lua`,
/// loads its parameters from `--secrets`, and runs it through its own
/// `fyde_sdk::init_dev_scrapers` instance (which saves the run's debug
/// report itself, under `--storage`'s `reports` subdirectory).
async fn run_scraper(args: &Args, scraper_name: &str) -> Result<()> {
    let script_path = PathBuf::from("scripts")
        .join(scraper_name)
        .join("script.lua");
    let script = std::fs::read_to_string(&script_path)
        .with_context(|| format!("reading Lua script {}", script_path.display()))?;

    let (parameters, debug_http_dump) = load_parameters(&args.secrets, scraper_name)?;
    let debug_http_dump = debug_http_dump || args.dev;

    let on_progress: Arc<dyn Fn(ProgressEvent) + Send + Sync> =
        Arc::new(|event| print_progress(&event));
    let on_question: Arc<dyn Fn(String) -> String + Send + Sync> = Arc::new(ask);

    let scrapers = init_dev_scrapers(
        args.storage.clone(),
        args.documents_dir.clone(),
        Some(on_progress),
        Some(on_question),
    )
    .await
    .context("initializing the scrapers service")?;

    scrapers
        .run(scraper_name, &script, parameters, debug_http_dump)
        .await
        .context("running the scraper's `run` function")
}

/// Reads `--secrets` (a map of scraper name -> `{"parameters": {...},
/// "debug_http_dump": bool}`) and returns `scraper_name`'s `parameters`
/// value (ready to inject into the script as-is) alongside its
/// `debug_http_dump` flag (`false` when the entry omits it).
fn load_parameters(path: &PathBuf, scraper_name: &str) -> Result<(Value, bool)> {
    let text = std::fs::read_to_string(path).with_context(|| {
        format!(
            "reading {} (create it with a \"{{scraper_name}}\": {{\"parameters\": {{...}}}} entry for {})",
            path.display(),
            scraper_name
        )
    })?;
    let mut secrets: HashMap<String, ScraperConfig> = serde_json::from_str(&text)
        .with_context(|| format!("parsing {} as JSON", path.display()))?;

    let config = secrets.remove(scraper_name).with_context(|| {
        format!(
            "no \"{}\" entry in {} (add one with a \"parameters\" object for this scraper)",
            scraper_name,
            path.display()
        )
    })?;

    Ok((config.parameters, config.debug_http_dump))
}

/// Prints `fyde.progress.step`/`fyde.progress.update` calls to the
/// terminal. The sdk's own host only forwards them to a callback (see
/// `fyde-sdk`'s `ClientConfig::on_scraper_progress` doc comment) — this is
/// that callback.
fn print_progress(event: &ProgressEvent) {
    match event {
        ProgressEvent::Step { name } => tracing::info!("==> {name}"),
        ProgressEvent::Update {
            current,
            total,
            message,
        } => tracing::info!("    [{current}/{total}] {message}"),
    }
}

/// `fyde.input.ask(question)`'s handler: prints `question` and blocks on a
/// line of stdin, returning the trimmed response. Used for values that
/// can't be known up front, like an MFA code.
fn ask(question: String) -> String {
    print!("{question} ");
    let _ = std::io::stdout().flush();

    let mut answer = String::new();
    let _ = std::io::stdin().read_line(&mut answer);

    answer.trim().to_string()
}
