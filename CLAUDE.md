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
value a `{"parameters": {...}, "debug_http_dump": bool}` object. `parameters` is injected into
the script's `run(parameters)` call as-is (as a Lua table) — this program never looks inside
it, so a script is free to read whatever fields it needs (conventionally
`username`/`password`) back out of it. `debug_http_dump` (optional, defaults to `false`) is
forwarded to `ScrapersService::run`'s `debug_http_dump` parameter, opting that scraper's run
into recording `fyde.http.get`/`post_form`'s response bodies in the per-run debug report
`../sdk`'s `reports` sub-domain saves (never request headers/bodies or form values — see
`../sdk/src/domains/scrapers/host/http.rs`'s doc comment) — leave it off unless actively
debugging a scraper's HTTP traffic. Copy `secret.json.example` to `secret.json` and fill it in
to run locally — never read or commit the real `secret.json`.

**Claude must never read `secret.json` (or any file matching `secret*.json`) with a tool —
it holds real third-party credentials.** To run a scraper, ask the user to run the `cargo run
--` command themselves, or run it via Bash without cat-ing/reading the file's contents.

The dev shell (`shell.nix` + `.envrc`, direnv/nix) mirrors `../sdk`'s: same pinned rustc,
`protobuf` (for `../sdk`'s `build.rs`), and `cmake`/`perl`/`go`/`bindgenHook` (for `../sdk`'s
vendored, patched BoringSSL used by `wreq`, the scrapers domain's HTTP client).

## Architecture

### `src/main.rs`

Parses CLI args — a required, variadic list of scraper names (e.g. `didaxis impots`), each the
name of a folder under `scripts/` — and runs each in turn via `run_scraper`: reads
`scripts/<name>/script.lua`, loads that scraper's `parameters` and `debug_http_dump` out of
`--secrets` (keyed by the same name), builds an `on_progress`/`on_question` pair (printing
progress to the terminal and blocking on stdin for a question — see `fyde_sdk::ClientConfig`'s
doc comments for why the sdk's own host functions no longer do this directly), calls
`fyde_sdk::init_dev_scrapers` to get a `scrapers::Service`, then calls its
`run(name, script, parameters, debug_http_dump)`. The per-run debug report is saved by
`../sdk`'s `scrapers::reports` sub-domain itself, under `--storage`'s `reports/`
subdirectory — this crate no longer writes one of its own.

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
