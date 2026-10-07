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
cargo run -- didaxis impots --documents-dir data/documents  # runs both, in order
```

There is no test suite here — the logic worth testing (the dev documents service, the
scrapers service itself) lives in and is tested by `../sdk`.

Config: each scraper's parameters come from `--secrets` (default `secret.json`, gitignored),
a JSON map keyed by scraper name (the script's parent directory name, e.g. `"didaxis"`,
`"impots"`), each value a `{"parameters": {...}} `object. `parameters` is injected into
the script's `run(parameters)` call as-is (as a Lua table) — this program never looks inside
it, so a script is free to read whatever fields it needs (conventionally
`username`/`password`) back out of it. Copy `secret.json.example` to `secret.json` and fill it
in to run locally — never read or commit the real `secret.json`.

Every scraper also has a `scripts/<name>/settings.json`, next to its `script.lua` — unlike
`--secrets`, this holds settings specific to the script itself rather than credentials, so
it's committed alongside the script. It's a `{"name": string, "description": string,
"short_description": string, "homepage": string, "wreq_emulation": bool, "debug_http_dump":
bool, "follow_redirects": bool, "allowed_domains": [string]}` object. `name`/`description`/`short_description` are
marketplace metadata — `cargo run -- publish` reads them (plus `logo.PNG`, next to
`script.lua`) and sends them through to `ScriptsClient::create_script`/`update_script` when
publishing that scraper as a public script, so a published script's display name, blurb, and
banner image come from here rather than from the scraper's directory name. `homepage` isn't
read by this program yet. `wreq_emulation` is forwarded to
`ScrapersService::run`'s `wreq_emulation` parameter, toggling `fyde.http`'s Chrome TLS/HTTP2
fingerprint emulation (`wreq_util::Profile::Chrome131`) for that scraper — on by default for
every scraper except `ameli`, whose WAF blocks `wreq`'s TLS fingerprint outright regardless of
emulation (see `scripts/ameli/script.lua`'s header comment). `debug_http_dump` (optional,
defaults to `false`) is forwarded to `ScrapersService::run`'s `debug_http_dump` parameter,
opting that scraper's run into recording `fyde.http.get`/`post_form`'s response bodies in the
per-run debug report `../sdk`'s `reports` sub-domain saves (never request headers/bodies or
form values — see `../sdk/src/domains/scrapers/host/http.rs`'s doc comment) — leave it off
unless actively debugging a scraper's HTTP traffic. `follow_redirects` (optional, defaults to
`true`) is forwarded to `ScrapersService::run`'s `follow_redirects` parameter, toggling
whether `fyde.http` automatically follows HTTP redirects for that scraper — set to `false`
for a scraper that needs to inspect a redirect response itself (e.g. reading a `Location`
header) instead of being carried straight to its target. `allowed_domains` (optional, defaults
to empty/unrestricted) is forwarded to `ScrapersService::run`'s `allowed_domains` parameter —
the only hosts (or subdomains of them) that scraper's `fyde.http.get/post_form/post_json/
download` and `fyde.browser:open` calls may reach; a call to any other host fails before it
ever touches the network, which stops the script right there since nothing here wraps a
`fyde.http`/`fyde.browser` call in `pcall`. Every scraper under `scripts/` sets this
explicitly to the real site(s) it talks to (e.g. `["impots.gouv.fr"]` covers both
`cfspart.impots.gouv.fr` and `cfspart-idp.impots.gouv.fr`).

Pass `--dev` to force `debug_http_dump` on for every scraper run regardless of what each
scraper's `settings.json` sets — a shortcut for "I'm actively debugging this script's HTTP
traffic" that doesn't require editing `settings.json`. The `create-script` and `fix-script`
skills always run with `--dev`, since both loops diagnose failures from the debug report's
dumped HTTP bodies.

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
`scripts/<name>/script.lua`, loads that scraper's `parameters` from `--secrets` and its
`wreq_emulation`/`debug_http_dump`/`follow_redirects`/`allowed_domains` settings from
`scripts/<name>/settings.json` (both keyed by the same name), builds an `on_progress`/
`on_question` pair (printing progress to the terminal and blocking on stdin for a question —
see `fyde_sdk::ClientConfig`'s doc comments for why the sdk's own host functions no longer do
this directly), calls `fyde_sdk::init_dev_scrapers` to get a `scrapers::Service`, then calls
its `run(name, script, parameters, debug_http_dump, wreq_emulation, follow_redirects,
allowed_domains)`. The
per-run debug report is saved by `../sdk`'s `scrapers::reports` sub-domain itself, under
`--storage`'s `reports/` subdirectory — this crate no longer writes one of its own.

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

### The remaining scripts, ported from `../doc-downloaders`

`../doc-downloaders` is a sibling repo of browser-automation (Playwright) scrapers for the same
sites, run against a real, human-authenticated Chromium (see its own `CLAUDE.md`). Its scripts
never automate login themselves (a human always logs in by hand, then presses ENTER) and often
never automate navigation to the documents page either — so unlike didaxis/impots (which were
reverse-engineered directly against the live sites by hand), porting these five scripts from
their Python source alone could only carry over what the Python code and its selectors actually
reveal: URLs it `goto()`s to directly, text/regex patterns it matches against, and markers it
checks for being logged out. Each script below states plainly, in its own header comment, what
is and isn't confirmed, and whether it hits a hard wall this host (no browser, no JS engine —
see `../sdk/src/domains/scrapers/host/*.rs`) can't get past, rather than presenting a
best-guess as if it were verified.

- **`scripts/scripts/boursorama/script.lua`** and **`scripts/scripts/edf/script.lua`** — the
  document-listing/download logic is ported from confirmed URLs/patterns in the Python source,
  gated the same way behind a restored session cookie, but these two sites run Datadome
  bot-detection (per `../doc-downloaders/CLAUDE.md`) that a plain HTTP client with no JS engine
  very likely can't get past even for a correctly-guessed login request — this is flagged as a
  probable architectural block in each file's header comment, not just an unconfirmed detail.
- **`scripts/scripts/cesu/script.lua`** and **`scripts/scripts/pajemploi/script.lua`** — both
  share Urssaf's SSO login; the Python source for each never reveals even the documents page
  URL (the human navigates there manually), so these are recon-only scaffolds in the same spirit
  as `ameli/script.lua`: they check whether a restored session is already authenticated and
  otherwise fail with an explanatory error, with no login or document logic written yet.
- **`scripts/scripts/scaleway/script.lua`** — architecturally blocked for a different reason
  than Datadome: the console's invoices table is rendered client-side by its React SPA and
  simply doesn't exist in the plain HTML `fyde.http.get` receives, and its download buttons have
  no real `href` to fetch — both require a JS engine this host doesn't have. The header comment
  suggests Scaleway's real JSON API (`api.scaleway.com`, authenticated with an API key) as a
  different, non-scraping way to get invoices if this is ever worth pursuing, but that's a
  separate design, not a variant of this file.
