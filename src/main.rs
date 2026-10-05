use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{CommandFactory, Parser, Subcommand};
use fyde_sdk::{Client, ClientConfig, LogLevel, ProgressEvent, Storage, init_dev_scrapers};
use serde::Deserialize;
use serde_json::Value;

/// Runs, or publishes to a fyde server, the Lua scraper scripts under
/// `scripts/`. Ported from `demo-rust-fyde`.
#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Runs one or more Lua scraper scripts against `fyde-sdk`'s `scrapers`
    /// service, outside of a full `Client`/server connection: cookies and
    /// session data persist as JSON files (`fyde_sdk::init_dev_scrapers`
    /// always selects its `scrapers::StorageConfig::File` backend — there is
    /// no local SQLite database here to pick `Sqlite` instead), and scraped
    /// documents are saved as plain files instead of being encrypted and
    /// uploaded.
    Run(RunArgs),

    /// Publishes every scraper's `script.lua` under `scripts/` to a fyde
    /// server's scripts service, as a public script, authenticating with a
    /// real account via a full `fyde_sdk::Client` backed by an in-memory
    /// database (there's nothing worth persisting locally for a one-off
    /// publish run).
    Publish(PublishArgs),
}

#[derive(Parser)]
struct RunArgs {
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
    /// each scraper's `settings.json` sets it to - recording all
    /// `fyde.http.get`/`post_form` response bodies in the run's debug
    /// report. Use while actively debugging a scraper's HTTP traffic.
    #[arg(long)]
    dev: bool,
}

#[derive(Parser)]
struct PublishArgs {
    /// Base URL of the fyde server to publish the scripts to.
    #[arg(long, default_value = "http://127.0.0.1:40051")]
    server: String,

    /// Username of the account to authenticate the publish as.
    #[arg(long)]
    username: String,

    /// Password of the account to authenticate the publish as.
    #[arg(long)]
    password: String,
}

/// One scraper's entry in `--secrets`. `parameters` is injected as-is (as a
/// Lua table) into the script's `run(parameters)` entrypoint - this program
/// never looks inside it, so each Lua script is free to read whatever
/// fields it needs (conventionally `username`/`password`) back out of it.
#[derive(Deserialize)]
struct ScraperConfig {
    parameters: Value,
}

/// A scraper's `scripts/<name>/settings.json`, next to its `script.lua` -
/// settings specific to the script itself rather than a secret, so (unlike
/// `--secrets`) it's committed alongside the script.
#[derive(Deserialize)]
struct ScraperSettings {
    /// Whether `fyde.http` applies `wreq`'s Chrome TLS/HTTP2 fingerprint
    /// emulation for this scraper. Enabled by default for every scraper
    /// except `ameli`, whose WAF blocks `wreq`'s TLS fingerprint outright
    /// regardless of emulation (see `scripts/ameli/script.lua`'s header
    /// comment).
    wreq_emulation: bool,
    /// Opts this scraper's `fyde.http` calls into recording response
    /// bodies in the run's debug report (see `ScrapersService::run`'s
    /// `debug_http_dump` parameter) - moved here from `--secrets` since
    /// it's a property of the scraper, not a secret. Defaults to `false`
    /// when omitted, and `--dev` forces it on regardless.
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

    let cli = Cli::parse();

    match cli.command {
        Some(Command::Run(args)) => run(args).await,
        Some(Command::Publish(args)) => publish(args).await,
        None => {
            Cli::command().print_help()?;
            Ok(())
        }
    }
}

/// Runs every scraper named on the command line, in order.
async fn run(args: RunArgs) -> Result<()> {
    if args.scrapers.is_empty() {
        RunArgs::command().print_help()?;
        return Ok(());
    }

    for scraper_name in &args.scrapers {
        run_scraper(&args, scraper_name).await?;
    }

    Ok(())
}

/// Reads every `scripts/<name>/script.lua` under the repo and publishes it
/// to `args.server`'s scripts service as a public script, authenticated as
/// `args.username`. Updates a script already owned by this account (by
/// matching on name) instead of failing, so the command can be re-run after
/// editing a script.
async fn publish(args: PublishArgs) -> Result<()> {
    let client = Client::init(ClientConfig {
        url: args.server.clone(),
        storage: Storage::Memory,
        log_level: LogLevel::Info,
        on_log: None,
        on_document_change: None,
        on_scraper_progress: None,
        on_scraper_question: None,
    })
    .await
    .with_context(|| format!("connecting to {}", args.server))?;

    client
        .users()
        .login(&args.username, &args.password, "fyde-scripts-publish")
        .await
        .with_context(|| format!("logging in as {}", args.username))?;

    let existing = client
        .scripts()
        .list_user_scripts()
        .await
        .context("listing this account's existing scripts")?;

    for scraper_name in list_scraper_names()? {
        let script_path = PathBuf::from("scripts")
            .join(&scraper_name)
            .join("script.lua");
        let script = std::fs::read_to_string(&script_path)
            .with_context(|| format!("reading Lua script {}", script_path.display()))?;

        match existing.iter().find(|s| s.name() == scraper_name) {
            Some(current) => {
                client
                    .scripts()
                    .update_script(current.id(), &scraper_name, true, Vec::new(), &script)
                    .await
                    .with_context(|| format!("updating script {scraper_name}"))?;
                tracing::info!("updated {scraper_name}");
            }
            None => {
                client
                    .scripts()
                    .create_script(&scraper_name, true, Vec::new(), &script)
                    .await
                    .with_context(|| format!("creating script {scraper_name}"))?;
                tracing::info!("created {scraper_name}");
            }
        }
    }

    Ok(())
}

/// Lists the name of every scraper under `scripts/` (i.e. every directory
/// directly under it containing a `script.lua`).
fn list_scraper_names() -> Result<Vec<String>> {
    let mut names = Vec::new();

    for entry in std::fs::read_dir("scripts").context("reading the scripts/ directory")? {
        let entry = entry.context("reading a scripts/ directory entry")?;
        if !entry.path().join("script.lua").is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        names.push(name);
    }

    names.sort();
    Ok(names)
}

/// Runs a single scraper by name: reads `scripts/<scraper_name>/script.lua`,
/// loads its parameters from `--secrets`, and runs it through its own
/// `fyde_sdk::init_dev_scrapers` instance (which saves the run's debug
/// report itself, under `--storage`'s `reports` subdirectory).
async fn run_scraper(args: &RunArgs, scraper_name: &str) -> Result<()> {
    let script_dir = PathBuf::from("scripts").join(scraper_name);
    let script_path = script_dir.join("script.lua");
    let script = std::fs::read_to_string(&script_path)
        .with_context(|| format!("reading Lua script {}", script_path.display()))?;

    let parameters = load_parameters(&args.secrets, scraper_name)?;
    let settings = load_settings(&script_dir, scraper_name)?;
    let debug_http_dump = settings.debug_http_dump || args.dev;

    let on_progress: Arc<dyn Fn(ProgressEvent) + Send + Sync> =
        Arc::new(|event| print_progress(&event));
    let on_question: Arc<dyn Fn(String) -> String + Send + Sync> = Arc::new(ask);

    let scrapers = init_dev_scrapers(
        args.storage.clone(),
        args.documents_dir.clone(),
        scraper_name,
        Some(on_progress),
        Some(on_question),
    )
    .await
    .context("initializing the scrapers service")?;

    scrapers
        .run(
            scraper_name,
            &script,
            parameters,
            debug_http_dump,
            settings.wreq_emulation,
        )
        .await
        .context("running the scraper's `run` function")
}

/// Reads `--secrets` (a map of scraper name -> `{"parameters": {...}}`) and
/// returns `scraper_name`'s `parameters` value, ready to inject into the
/// script as-is.
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

/// Reads `scripts/<scraper_name>/settings.json` (next to `script.lua`).
fn load_settings(script_dir: &Path, scraper_name: &str) -> Result<ScraperSettings> {
    let path = script_dir.join("settings.json");
    let text = std::fs::read_to_string(&path).with_context(|| {
        format!(
            "reading {} (add one with a \"wreq_emulation\" bool for {})",
            path.display(),
            scraper_name
        )
    })?;
    serde_json::from_str(&text).with_context(|| format!("parsing {} as JSON", path.display()))
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
