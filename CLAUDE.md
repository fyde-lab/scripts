# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

`fyde-scripts` is the canonical home for the Lua scraper scripts run by `fyde-sdk`'s
`scrapers` domain (`scripts/scripts/<name>/script.lua`), plus `fyde-scripts` itself — a thin Rust CLI (ported from
the standalone `demo-rust-fyde` repo) that runs one of those scripts through
`fyde-sdk`'s public `ScrapersService::run`, outside of a full `Client`.

It's a sibling repo to `../sdk` (see the top-level `CLAUDE.md`), depended on via a `path`
dependency, the same way `../cli` depends on it.

## Why not a full `fyde_sdk::Client`

`Client::init` wires up a real server connection, OPAQUE login, settings and changelog sync —
none of which this CLI needs, since a scraper script never touches the fyde server itself
(it logs into a *third-party* site). Instead this program calls `fyde_sdk::init_dev_scrapers`,
which builds just the `scrapers::Service`, injecting:

- `scrapers::StorageConfig::File` (a directory this program controls via `--storage`) instead
  of the `StorageConfig::Sqlite` pool a full `Client` manages under the XDG data directory —
  cookies/session data persist as one JSON file per scraper under `--storage/cookies` and
  `--storage/session` respectively, rather than in a SQLite database;
- `fyde_sdk`'s dev `DocumentsService` implementation (`DevDocumentsClient`, in `../sdk/src/
  domains/documents/dev.rs`) instead of the real encrypted-upload one `Client` builds: a
  script's `fyde.save_document` call just writes the file under `--documents-dir` as plain
  bytes, the way `demo-rust-fyde` did, rather than encrypting and publishing it as a changelog
  event (there is no account/session to publish one against here anyway).

Both are "dev" implementations that live inside their own domain in `../sdk`, not in this
repo — `fyde_sdk::init_dev_scrapers` is the one function this program calls to get a working
`Arc<dyn ScrapersService>` from them.

## Commands

```sh
cargo build
cargo run -- didaxis                          # runs scripts/didaxis/script.lua
cargo run -- didaxis impots --documents-dir documents  # runs both, in order
```

There is no test suite here — the logic worth testing (the dev documents service, the
scrapers service itself) lives in and is tested by `../sdk`.

Config: each scraper's parameters come from `--secrets` (default `secret.json`, gitignored),
a JSON map keyed by scraper name (the script's parent directory name, e.g. `"didaxis"`,
`"impots"`), each
value a `{"parameters": {...}}` object. `parameters` is injected into the script's
`run(parameters)` call as-is (as a Lua table) — this program never looks inside it, so a
script is free to read whatever fields it needs (conventionally `username`/`password`) back
out of it. Copy `secret.json.example` to `secret.json` and fill it in to run locally — never
read or commit the real `secret.json`.

The dev shell (`shell.nix` + `.envrc`, direnv/nix) mirrors `../sdk`'s: same pinned rustc,
`protobuf` (for `../sdk`'s `build.rs`), and `cmake`/`perl`/`go`/`bindgenHook` (for `../sdk`'s
vendored, patched BoringSSL used by `wreq`, the scrapers domain's HTTP client).

## Architecture

### `src/main.rs`

Parses CLI args — a required, variadic list of scraper names (e.g. `didaxis impots`), each the
name of a folder under `scripts/` — and runs each in turn via `run_scraper`: reads
`scripts/<name>/script.lua`, loads that scraper's `parameters` out of `--secrets` (keyed by the
same name), builds an `on_progress`/`on_question` pair (printing progress to the terminal and
blocking on stdin for a question — see `fyde_sdk::ClientConfig`'s doc comments for why the
sdk's own host functions no longer do this directly), calls `fyde_sdk::init_dev_scrapers` to
get a `scrapers::Service`, then calls its `run(name, script, parameters)`. A `Report` wraps
each scraper's run (see below).

### `src/report.rs` — per-run debug report

Ported from `demo-rust-fyde`'s `report.rs`, simplified: records `run_started`/`run_finished`/
`error` around the whole run, plus every `fyde.progress.step`/`.update` call, as one JSON
array under `--report-dir` (default `reports/`, gitignored), rewritten after each entry so it
stays valid JSON even if the run crashes partway through. This is a debugging aid only, kept
in this repo rather than `../sdk`, since `../sdk`'s own CLAUDE.md notes the equivalent feature
was deliberately dropped when the scrapers domain was ported into the sdk (out of scope
there — a GUI/mobile `Client` consumer renders its own progress, it doesn't need a report
file).

### `scripts/scripts/didaxis/script.lua` / `scripts/scripts/impots/script.lua`

Unmodified from `demo-rust-fyde` (beyond updated comments pointing at `../sdk`'s host
instead of a local one that no longer exists here) — see each file's header comment for what
it scrapes and how. Any new per-site script must follow the same contract: return a table
with a single `run(parameters)` function, and only call into the `fyde` host table (`fyde.log`,
`fyde.http`, `fyde.html`, `fyde.json`, `fyde.progress`, `fyde.input`, `fyde.save_document`,
`fyde.session`) — see `../sdk/src/domains/scrapers/host/`.

### `scripts/scripts/ameli/script.lua`

Scaffold for the "compte ameli" personal space (assure.ameli.fr, Assurance Maladie/CPAM) —
**unverified**, unlike the two scripts above: `assure.ameli.fr` returns a bot-protection
"Request Rejected" page to plain HTTP requests, and there's no test account to reverse-engineer
the real login/document flow by hand through a browser the way didaxis/impots were. The login
URL, form fields, and document selectors are marked `TODO` in the file's header comment and
need confirming against the live site with a real account before this script will actually
work.
