use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::{CommandFactory, Parser, Subcommand};
use fyde_sdk::{
    Client, ClientConfig, ErrorCode, LogLevel, LoginOutcome, ProgressEvent, ScriptParameter,
    ScriptParameterType, ScriptType, Storage, init_dev_scrapers,
};
use serde::Deserialize;
use serde_json::Value;

/// Runs, or publishes to a fyde server, the Lua scraper scripts under
/// `scrapers/`. Ported from `demo-rust-fyde`.
#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Runs one or more Lua scraper scripts against `fyde-sdk`'s `scrapers`
    /// service, outside of a full `Client`/server connection: cookies and
    /// session data persist as JSON files under `--storage`, and scraped
    /// documents are saved as plain files instead of being encrypted and
    /// uploaded.
    Run(RunArgs),

    /// Publishes every scraper's `script.lua` under `scrapers/` to a fyde
    /// server's scripts service, as a public script, authenticating with a
    /// real account via a full `fyde_sdk::Client` backed by an in-memory
    /// database (there's nothing worth persisting locally for a one-off
    /// publish run).
    Publish(PublishArgs),

    /// Loads every `scrapers/<name>/script.lua` through the same restricted
    /// Lua 5.4 stdlib `../sdk/src/domains/scrapers/service.rs`'s
    /// `sandboxed_lua` uses, without calling `run` - this only catches Lua
    /// syntax errors and confirms each script returns a table with a `run`
    /// function, with no network calls or `--secrets` needed, so it's safe
    /// to run in CI.
    Check,

    /// Lists every scraper under `scrapers/` (every directory containing a
    /// `script.lua`), with the display name and short description from its
    /// `manifest.json`.
    List,

    /// Prints the `status` object of one or more scrapers' `manifest.json`
    /// (every scraper under `scrapers/` when no name is given): its overall
    /// state, the result of each login/documents check, and its notes.
    Status(StatusArgs),

    /// Regenerates the status table in `README.md` (between its
    /// `<!-- status-table:start -->`/`<!-- status-table:end -->` markers)
    /// from every scraper's `manifest.json` `status`, one row per scraper.
    StatusTable,
}

#[derive(Parser)]
struct StatusArgs {
    /// Names of the scrapers to print the status of, each the name of a
    /// folder under `scrapers/`. Prints every scraper's when none are given.
    scrapers: Vec<String>,
}

#[derive(Parser)]
struct RunArgs {
    /// Names of the scrapers to run, each the name of a folder under
    /// `scrapers/` containing a `script.lua` (e.g. `didaxis impots` runs
    /// `scrapers/didaxis/script.lua` and `scrapers/impots/script.lua`, in
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
    /// each scraper's `manifest.json` sets it to - recording all
    /// `fyde.http.get`/`post_form` response bodies in the run's debug
    /// report. Use while actively debugging a scraper's HTTP traffic.
    #[arg(long)]
    dev: bool,

    /// Show the embedded browser window used by `fyde.browser` (e.g. for a
    /// script ported from `../doc-downloaders` that expects a human to log
    /// in by hand) instead of the invisible one it uses by default. Has no
    /// effect on a scraper that never calls `fyde.browser`, since the
    /// window is only ever created lazily on first use.
    #[arg(long)]
    visible: bool,
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

/// A scraper's `scrapers/<name>/manifest.json`, next to its `script.lua` -
/// settings specific to the script itself rather than a secret, so (unlike
/// `--secrets`) it's committed alongside the script.
#[derive(Deserialize)]
struct ScraperManifest {
    /// Display name for the published script, shown in a marketplace
    /// listing (e.g. "Didaxis") - distinct from the scraper's directory
    /// name under `scrapers/` (e.g. "didaxis"), which is only used locally
    /// to run it and to match it against an already-published script.
    name: String,
    /// The script's own description, written for display in a marketplace
    /// listing.
    description: String,
    /// A one-line summary, shorter than `description`, for display where
    /// space is limited (e.g. a marketplace list row).
    short_description: String,
    /// Whether `fyde.http` applies `wreq`'s Chrome TLS/HTTP2 fingerprint
    /// emulation for this scraper. Required; turned off only for a few
    /// scrapers (e.g. `ameli`, whose WAF blocks `wreq`'s TLS fingerprint
    /// outright regardless of emulation - see `scrapers/ameli/script.lua`'s
    /// header comment).
    wreq_emulation: bool,
    /// Opts this scraper's `fyde.http` calls into recording response
    /// bodies in the run's debug report (see `ScrapersService::run`'s
    /// `debug_http_dump` parameter). Defaults to `false` when omitted, and
    /// `--dev` forces it on regardless.
    #[serde(default)]
    debug_http_dump: bool,
    /// Whether `fyde.http` automatically follows HTTP redirects for this
    /// scraper (see `ScrapersService::run`'s `follow_redirects` parameter).
    /// Defaults to `true` when omitted, matching a real-browser-like
    /// client - set to `false` for a scraper that needs to inspect a
    /// redirect response itself (e.g. reading a `Location` header) instead
    /// of being carried straight to its target.
    #[serde(default = "default_follow_redirects")]
    follow_redirects: bool,
    /// The only hosts (or subdomains of them) this scraper's `fyde.http`/
    /// `fyde.browser:open` calls may reach (see `ScrapersService::run`'s
    /// `allowed_domains` parameter) - a call to any other host fails before
    /// it reaches the network, which stops the script right there since
    /// nothing here wraps a `fyde.http`/`fyde.browser` call in `pcall`.
    /// Defaults to empty (unrestricted) when omitted, but every scraper
    /// under `scrapers/` sets this explicitly to the real site(s) it talks
    /// to.
    #[serde(default)]
    allowed_domains: Vec<String>,
    /// What the script needs from the user before it can run (e.g. a login
    /// username/password), keyed by the name `run(parameters)` reads it
    /// back under - published with the script, so a client can ask for
    /// them when the script is installed. Defaults to none when omitted.
    #[serde(default)]
    parameters: HashMap<String, ManifestParameter>,
    /// How far this scraper has been confirmed to work - only read by the
    /// `status` command, never by a run.
    status: ScraperStatus,
}

/// One entry of a [`ScraperManifest`]'s `parameters`, in the manifest's own
/// JSON shape (`"type"` rather than [`ScriptParameter`]'s `parameter_type`,
/// optional `placeholder`/`required`/`secret`).
#[derive(Deserialize)]
struct ManifestParameter {
    label: String,
    #[serde(default)]
    placeholder: String,
    #[serde(rename = "type")]
    parameter_type: ScriptParameterType,
    #[serde(default)]
    required: bool,
    #[serde(default)]
    secret: bool,
}

impl From<ManifestParameter> for ScriptParameter {
    fn from(parameter: ManifestParameter) -> Self {
        ScriptParameter {
            label: parameter.label,
            placeholder: parameter.placeholder,
            parameter_type: parameter.parameter_type,
            required: parameter.required,
            secret: parameter.secret,
        }
    }
}

/// A scraper's `manifest.json` `status` object (see `README.md`'s Status
/// section for where each check's result comes from).
#[derive(Deserialize)]
struct ScraperStatus {
    state: ScraperState,
    /// When this status was last changed, as `YYYY-MM-DD`.
    last_updated: String,
    /// Whether `tests/login_smoke.sh` found the login page/endpoint.
    login_page_found: CheckResult,
    /// Whether `tests/login_smoke.sh`'s made-up credentials were reported
    /// as `INVALID_CREDENTIALS`.
    invalid_credentials_detected: CheckResult,
    /// Whether a run with real credentials got past the login.
    login_ok: CheckResult,
    /// Whether a run with real credentials saved the scraper's documents.
    documents_fetched: CheckResult,
    /// The bot protection(s) the site runs (e.g. "DataDome", "Akamai Bot
    /// Manager, reCAPTCHA"), `null` when none was found.
    #[serde(default)]
    antibot_name: Option<String>,
    /// Whether that bot protection gets in this scraper's way.
    antibot_status: AntibotStatus,
    /// Free-form details: what is and isn't confirmed, and why a smoke
    /// test failed (after "Smoke:").
    #[serde(default)]
    notes: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ScraperState {
    /// Login and documents both passed a run against the real site.
    Verified,
    /// A run against the real site failed.
    Broken,
    /// A host limitation stops the documents (or the login) even if the
    /// site behaves as expected.
    Blocked,
    /// Not run against the real site with real credentials yet.
    Wip,
}

impl ScraperState {
    fn label(&self) -> &'static str {
        match self {
            Self::Verified => "verified",
            Self::Broken => "broken",
            Self::Blocked => "blocked",
            Self::Wip => "wip",
        }
    }

    /// The emoji `status-table` shows for this state in `README.md`.
    fn icon(&self) -> &'static str {
        match self {
            Self::Verified => "✅",
            Self::Broken => "❌",
            Self::Blocked => "🚫",
            Self::Wip => "🚧",
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum CheckResult {
    Passed,
    Failed,
    NotTested,
    /// The check doesn't apply to this scraper (e.g. a passwordless login
    /// has no password to reject).
    NotApplicable,
}

impl CheckResult {
    fn label(&self) -> &'static str {
        match self {
            Self::Passed => "passed",
            Self::Failed => "failed",
            Self::NotTested => "not tested",
            Self::NotApplicable => "not applicable",
        }
    }

    /// The emoji `status-table` shows for this result in `README.md`.
    fn icon(&self) -> &'static str {
        match self {
            Self::Passed => "✅",
            Self::Failed => "❌",
            Self::NotTested => "❔",
            Self::NotApplicable => "➖",
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum AntibotStatus {
    /// No bot protection found on the pages this scraper talks to.
    Absent,
    /// A bot protection runs there, but doesn't stop this scraper.
    Present,
    /// A bot protection stops this scraper (403, unsolvable captcha...).
    Blocking,
    /// The check couldn't be made (site unreachable).
    Failed,
}

impl AntibotStatus {
    fn label(&self) -> &'static str {
        match self {
            Self::Absent => "absent",
            Self::Present => "present",
            Self::Blocking => "blocking",
            Self::Failed => "failed",
        }
    }

    /// The emoji `status-table` shows for this status in `README.md`.
    fn icon(&self) -> &'static str {
        match self {
            Self::Absent => "✅",
            Self::Present => "⚠️",
            Self::Blocking => "⛔",
            Self::Failed => "❔",
        }
    }
}

fn default_follow_redirects() -> bool {
    true
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
        Some(Command::Check) => check(),
        Some(Command::List) => list(),
        Some(Command::Status(args)) => status(args),
        Some(Command::StatusTable) => status_table(),
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

/// Reads every `scrapers/<name>/script.lua` under the repo and publishes it
/// to `args.server`'s scripts service as a public script, authenticated as
/// `args.username`. Updates a script this account already published (matched
/// on name among its enabled and the public scripts, skipping same-named ones
/// the server won't let it update) instead of creating a duplicate, so the
/// command can be re-run after editing a script.
async fn publish(args: PublishArgs) -> Result<()> {
    let client = Client::init(ClientConfig {
        url: args.server.clone(),
        client_name: "fyde-scripts".to_string(),
        storage: Storage::Memory,
        log_level: LogLevel::Info,
        on_log: None,
        on_document_change: None,
        on_scraper_progress: None,
        on_scraper_question: None,
    })
    .await
    .with_context(|| format!("connecting to {}", args.server))?;

    let outcome = client
        .users()
        .login(
            &args.username,
            &args.password,
            "fyde-scripts-publish",
            false,
            None,
        )
        .await
        .with_context(|| format!("logging in as {}", args.username))?;
    if let LoginOutcome::SessionLimitReached { max_sessions, .. } = outcome {
        anyhow::bail!(
            "{} already has {max_sessions} open session(s), its plan's limit: log one out before \
             publishing",
            args.username
        );
    }

    // Close the session whether publishing succeeded or not, so a failed run
    // doesn't leave one open against the account's plan limit. A logout
    // failure after a publishing failure is only logged, to keep the error
    // that actually stopped the run.
    let published = publish_scripts(&client).await;
    if let Err(err) = client
        .users()
        .logout()
        .await
        .with_context(|| format!("logging out {}", args.username))
    {
        if published.is_ok() {
            return Err(err);
        }
        tracing::warn!("{err:#}");
    }
    published
}

/// Publishes every scraper through `client`, which must already be logged in;
/// see [`publish`].
async fn publish_scripts(client: &Client) -> Result<()> {
    // Scripts this account may already have published: `list_user_scripts`
    // only returns the ones it has *enabled*, which a script created here
    // never is, so the public listing (every script `publish` creates is
    // public) is what actually finds them again. Neither listing says who
    // owns a script, so a name match is only a candidate - see below.
    let mut existing = client
        .scripts()
        .list_user_scripts()
        .await
        .context("listing this account's enabled scripts")?;
    for script in client
        .scripts()
        .list_public_scripts()
        .await
        .context("listing public scripts")?
    {
        if !existing.iter().any(|s| s.id() == script.id()) {
            existing.push(script);
        }
    }

    for scraper_name in list_scraper_names()? {
        let script_dir = PathBuf::from("scrapers").join(&scraper_name);
        let script_path = script_dir.join("script.lua");
        let script = std::fs::read_to_string(&script_path)
            .with_context(|| format!("reading Lua script {}", script_path.display()))?;
        let manifest = load_manifest(&script_dir, &scraper_name)?;
        let logo_path = script_dir.join("logo.png");
        let logo = if logo_path.is_file() {
            std::fs::read(&logo_path)
                .with_context(|| format!("reading logo {}", logo_path.display()))?
        } else {
            Vec::new()
        };

        let parameters: HashMap<String, ScriptParameter> = manifest
            .parameters
            .into_iter()
            .map(|(key, parameter)| (key, parameter.into()))
            .collect();

        // Update the first same-named script this account owns; the server
        // refuses `update_script` on someone else's, so move on to the next
        // candidate then, and only create a new script once none is ours.
        let mut updated = false;
        for current in existing.iter().filter(|s| s.name() == manifest.name) {
            match client
                .scripts()
                .update_script(
                    current.id(),
                    &manifest.name,
                    true,
                    logo.clone(),
                    &script,
                    &manifest.description,
                    &manifest.short_description,
                    manifest.allowed_domains.clone(),
                    ScriptType::Scraper,
                    parameters.clone(),
                )
                .await
            {
                Ok(_) => {
                    updated = true;
                    break;
                }
                Err(err)
                    if matches!(
                        err.code(),
                        ErrorCode::PermissionDenied | ErrorCode::NotFoundOnServer
                    ) =>
                {
                    continue;
                }
                Err(err) => {
                    return Err(err).with_context(|| format!("updating script {scraper_name}"));
                }
            }
        }

        if updated {
            tracing::info!("updated {scraper_name}");
        } else {
            client
                .scripts()
                .create_script(
                    &manifest.name,
                    true,
                    logo,
                    &script,
                    &manifest.description,
                    &manifest.short_description,
                    manifest.allowed_domains.clone(),
                    ScriptType::Scraper,
                    parameters,
                )
                .await
                .with_context(|| format!("creating script {scraper_name}"))?;
            tracing::info!("created {scraper_name}");
        }
    }

    Ok(())
}

/// Loads every scraper's `script.lua` and reports any that fail to parse or
/// don't return a table with a `run` function, failing the process (non-zero
/// exit) if any do.
fn check() -> Result<()> {
    let mut failed = Vec::new();

    for scraper_name in list_scraper_names()? {
        let script_path = PathBuf::from("scrapers")
            .join(&scraper_name)
            .join("script.lua");
        let script = std::fs::read_to_string(&script_path)
            .with_context(|| format!("reading Lua script {}", script_path.display()))?;

        match check_script(&scraper_name, &script) {
            Ok(()) => tracing::info!("{scraper_name}: ok"),
            Err(err) => {
                tracing::error!("{scraper_name}: {err:#}");
                failed.push(scraper_name);
            }
        }
    }

    if !failed.is_empty() {
        anyhow::bail!(
            "{} scraper script(s) failed validation: {failed:?}",
            failed.len()
        );
    }

    Ok(())
}

/// Prints one line per scraper under `scrapers/`: its directory name (what
/// `run` takes), then its `manifest.json` display name and short
/// description.
fn list() -> Result<()> {
    let names = list_scraper_names()?;
    let width = names.iter().map(String::len).max().unwrap_or(0);

    for scraper_name in names {
        let script_dir = PathBuf::from("scrapers").join(&scraper_name);
        let manifest = load_manifest(&script_dir, &scraper_name)?;
        println!(
            "{scraper_name:<width$}  {} - {}",
            manifest.name, manifest.short_description
        );
    }

    Ok(())
}

/// Prints the `manifest.json` `status` of every scraper named on the command
/// line, or of every scraper under `scrapers/` when none are.
fn status(args: StatusArgs) -> Result<()> {
    let names = if args.scrapers.is_empty() {
        list_scraper_names()?
    } else {
        args.scrapers
    };

    for (i, scraper_name) in names.iter().enumerate() {
        let script_dir = PathBuf::from("scrapers").join(scraper_name);
        let manifest = load_manifest(&script_dir, scraper_name)?;
        let status = &manifest.status;

        if i > 0 {
            println!();
        }
        println!(
            "{scraper_name} ({}): {}",
            manifest.name,
            status.state.label()
        );
        println!("  {:<30}{}", "last updated", status.last_updated);
        let checks = [
            ("login page found", &status.login_page_found),
            (
                "invalid credentials detected",
                &status.invalid_credentials_detected,
            ),
            ("login ok", &status.login_ok),
            ("documents fetched", &status.documents_fetched),
        ];
        for (label, result) in checks {
            println!("  {label:<30}{}", result.label());
        }
        match &status.antibot_name {
            Some(name) => println!(
                "  {:<30}{} ({name})",
                "antibot",
                status.antibot_status.label()
            ),
            None => println!("  {:<30}{}", "antibot", status.antibot_status.label()),
        }
        if let Some(notes) = &status.notes {
            println!("  notes: {notes}");
        }
    }

    Ok(())
}

const STATUS_TABLE_START: &str = "<!-- status-table:start -->";
const STATUS_TABLE_END: &str = "<!-- status-table:end -->";

/// Rewrites the part of `README.md` between `STATUS_TABLE_START` and
/// `STATUS_TABLE_END` with a Markdown table of every scraper's
/// `manifest.json` `status`, leaving the rest of the file untouched.
fn status_table() -> Result<()> {
    let mut table = String::from(
        "| Scraper | State | Login page found | Login KO detected | Login OK | Fetching OK | Antibot | Last updated |\n\
         |---|---|---|---|---|---|---|---|\n",
    );
    for scraper_name in list_scraper_names()? {
        let script_dir = PathBuf::from("scrapers").join(&scraper_name);
        let manifest = load_manifest(&script_dir, &scraper_name)?;
        let status = &manifest.status;
        let antibot = match &status.antibot_name {
            Some(name) => format!(
                "{} {}",
                status.antibot_status.icon(),
                name.replace('|', "\\|")
            ),
            None => status.antibot_status.icon().to_string(),
        };
        table.push_str(&format!(
            "| [`{scraper_name}`](scrapers/{scraper_name}/manifest.json) | {} {} | {} | {} | {} | {} | {antibot} | {} |\n",
            status.state.icon(),
            status.state.label(),
            status.login_page_found.icon(),
            status.invalid_credentials_detected.icon(),
            status.login_ok.icon(),
            status.documents_fetched.icon(),
            status.last_updated,
        ));
    }

    let readme = std::fs::read_to_string("README.md").context("reading README.md")?;
    let (before, rest) = readme
        .split_once(STATUS_TABLE_START)
        .with_context(|| format!("README.md has no {STATUS_TABLE_START} marker"))?;
    let (_, after) = rest
        .split_once(STATUS_TABLE_END)
        .with_context(|| format!("README.md has no {STATUS_TABLE_END} marker"))?;
    let updated = format!("{before}{STATUS_TABLE_START}\n{table}{STATUS_TABLE_END}{after}");
    std::fs::write("README.md", updated).context("writing README.md")?;

    println!("updated README.md's status table");
    Ok(())
}

/// Evaluates `script`'s top-level chunk in the same restricted stdlib
/// (`TABLE`/`STRING`/`MATH`/`UTF8`, with `dofile`/`loadfile`/`load` stripped)
/// `../sdk/src/domains/scrapers/service.rs`'s `sandboxed_lua` builds for a
/// real run, then checks the returned table has a `run` function - without
/// calling it, so this needs no network connection, and of the `fyde` host
/// table only `fyde.helpers` (which scripts alias at their top level), built
/// from the sdk's own Lua source.
fn check_script(name: &str, script: &str) -> Result<()> {
    let lua = mlua::Lua::new_with(
        mlua::StdLib::TABLE | mlua::StdLib::STRING | mlua::StdLib::MATH | mlua::StdLib::UTF8,
        mlua::LuaOptions::new(),
    )
    .context("creating a restricted Lua VM")?;
    let globals = lua.globals();
    globals.set("dofile", mlua::Value::Nil)?;
    globals.set("loadfile", mlua::Value::Nil)?;
    globals.set("load", mlua::Value::Nil)?;

    let helpers: mlua::Table = lua
        .load(fyde_sdk::SCRAPER_HELPERS_LUA)
        .set_name("fyde.helpers")
        .eval()
        .context("loading fyde.helpers")?;
    let fyde = lua.create_table()?;
    fyde.set("helpers", helpers)?;
    globals.set("fyde", fyde)?;

    let table: mlua::Table = lua
        .load(script)
        .set_name(name)
        .eval()
        .context("evaluating the script")?;

    table
        .get::<mlua::Function>("run")
        .context("script must return a table with a `run(parameters)` function")?;

    Ok(())
}

/// Lists the name of every scraper under `scrapers/` (i.e. every directory
/// directly under it containing a `script.lua`), sorted.
fn list_scraper_names() -> Result<Vec<String>> {
    let mut names = Vec::new();

    for entry in std::fs::read_dir("scrapers").context("reading the scrapers/ directory")? {
        let entry = entry.context("reading a scrapers/ directory entry")?;
        if !entry.path().join("script.lua").is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        names.push(name);
    }

    names.sort();
    Ok(names)
}

/// Runs a single scraper by name: reads `scrapers/<scraper_name>/script.lua`,
/// loads its parameters from `--secrets`, and runs it through its own
/// `fyde_sdk::init_dev_scrapers` instance (which saves the run's debug
/// report itself, under `--storage`'s `reports` subdirectory).
async fn run_scraper(args: &RunArgs, scraper_name: &str) -> Result<()> {
    let script_dir = PathBuf::from("scrapers").join(scraper_name);
    let script_path = script_dir.join("script.lua");
    let script = std::fs::read_to_string(&script_path)
        .with_context(|| format!("reading Lua script {}", script_path.display()))?;

    let parameters = load_parameters(&args.secrets, scraper_name)?;
    let manifest = load_manifest(&script_dir, scraper_name)?;
    let debug_http_dump = manifest.debug_http_dump || args.dev;

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
            manifest.wreq_emulation,
            manifest.follow_redirects,
            manifest.allowed_domains,
            args.visible,
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

/// Reads `scrapers/<scraper_name>/manifest.json` (next to `script.lua`).
fn load_manifest(script_dir: &Path, scraper_name: &str) -> Result<ScraperManifest> {
    let path = script_dir.join("manifest.json");
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
