mod report;

use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use fyde_sdk::{ProgressEvent, init_dev_scrapers};
use serde::Deserialize;
use serde_json::{Value, json};

use report::Report;

/// Runs a Lua scraper script against `fyde-sdk`'s `scrapers` service,
/// outside of a full `Client`/server connection: cookies and session data
/// persist as JSON files (`fyde_sdk::init_dev_scrapers` always selects its
/// `scrapers::StorageConfig::File` backend — there is no local SQLite
/// database here to pick `Sqlite` instead), and scraped documents are saved
/// as plain files instead of being encrypted and uploaded. Ported from
/// `demo-rust-fyde`.
#[derive(Parser)]
struct Args {
    /// Path to the Lua scraper script to run.
    #[arg(long, default_value = "scripts/didaxis/script.lua")]
    script: PathBuf,

    /// Directory documents get saved into (gitignored).
    #[arg(long, default_value = "documents")]
    documents_dir: PathBuf,

    /// Directory scraper cookies/session data persist to across runs, as
    /// one JSON file per scraper under a `cookies`/`session` subdirectory
    /// respectively (gitignored; created on first run).
    #[arg(long, default_value = "data/")]
    storage: PathBuf,

    /// Directory the per-run debug report gets written into (gitignored).
    /// Each run gets its own `<scraper>_<dd-mm-yy>_<hh-mm-ss>.json` file.
    #[arg(long, default_value = "reports")]
    report_dir: PathBuf,

    /// JSON file to read each scraper's parameters from, keyed by scraper
    /// name (the script's parent directory name). Gitignored - never commit
    /// real credentials in it.
    #[arg(long, default_value = "secret.json")]
    secrets: PathBuf,
}

/// One scraper's entry in `--secrets`. `parameters` is injected as-is (as a
/// Lua table) into the script's `run(parameters)` entrypoint - this program
/// never looks inside it, so each Lua script is free to read whatever
/// fields it needs (conventionally `username`/`password`) back out of it.
#[derive(Deserialize)]
struct ScraperConfig {
    parameters: Value,
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

    let script = std::fs::read_to_string(&args.script)
        .with_context(|| format!("reading Lua script {}", args.script.display()))?;

    let scraper_name = args
        .script
        .parent()
        .and_then(|dir| dir.file_name())
        .and_then(|name| name.to_str())
        .unwrap_or("scraper")
        .to_string();

    let parameters = load_parameters(&args.secrets, &scraper_name)?;

    let report = Report::start(&args.report_dir, &scraper_name);
    report.record(
        "run_started",
        json!({ "script": args.script.to_string_lossy() }),
    );

    let progress_report = report.clone();
    let on_progress: Arc<dyn Fn(ProgressEvent) + Send + Sync> = Arc::new(move |event| {
        print_progress(&event);
        progress_report.record_progress(&event);
    });
    let on_question: Arc<dyn Fn(String) -> String + Send + Sync> = Arc::new(ask);

    let scrapers = init_dev_scrapers(
        args.storage.clone(),
        args.documents_dir.clone(),
        Some(on_progress),
        Some(on_question),
    )
    .await
    .context("initializing the scrapers service")?;

    let result = scrapers.run(&scraper_name, &script, parameters).await;

    match &result {
        Ok(()) => report.record("run_finished", json!({ "status": "ok" })),
        Err(err) => report.record("error", json!({ "message": err.to_string() })),
    }

    result.context("running the scraper's `run` function")?;

    Ok(())
}

/// Reads `--secrets` (a map of scraper name -> `{"parameters": {...}}`) and
/// returns the `parameters` value for `scraper_name`, ready to inject into
/// the script as-is.
fn load_parameters(path: &PathBuf, scraper_name: &str) -> Result<Value> {
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

    Ok(config.parameters)
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
