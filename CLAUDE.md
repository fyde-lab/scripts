# CLAUDE.md

`fyde-scripts` holds the Lua scraper scripts (`scrapers/<name>/script.lua`) run by `../sdk`'s
`scrapers` domain, plus `src/main.rs`, a small Rust CLI that runs them locally. Depends on
`../sdk` via a `path` dependency.

## Critical rules

- **Never read `secret.json` (or any `secret*.json`) with any tool** — it holds real
  third-party credentials. To run a scraper, run the `cargo run --` command via Bash without
  printing the file, or ask the user to run it. Never commit it (it's gitignored).
  `data/cookies/` and `data/session/` hold live sessions: don't read them either.
- Any manual edit to a manifest's `status` must also set `status.last_updated` to today
  (`YYYY-MM-DD`), then re-run `cargo run -- status-table` — never edit README.md's status table
  by hand.
- New scrapers follow the contract below; use the `create-script` / `fix-script` skills
  (`.claude/skills/`) for writing or debugging one.

## Commands

```sh
cargo run -- run didaxis impots              # run scrapers in order (--dev, --visible, --documents-dir, --storage, --secrets)
cargo run -- check                           # load every script in the sandbox without running it (no network)
cargo run -- list                            # every scraper with its manifest name/short description
cargo run -- status [name...]                # print manifest `status` objects
cargo run -- status-table                    # regenerate README.md's status table
cargo run -- publish --username U --password P [--server URL]   # publish every scraper as a public script
tests/login_smoke.sh [name...]               # live-site smoke test with fake credentials (writes manifest status)
```

CI (`.github/workflows/ci.yml`) runs: `luacheck scrapers/` (config in `.luacheckrc`),
`cargo run -- check`, `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`,
`cargo build`. There is no Rust test suite here; the host logic is tested in `../sdk`.
`check` only catches syntax errors and scripts that don't return a `run` function — it calls
nothing inside `run`, so it won't catch a bad `fyde.*` call.

Dev shell: `shell.nix` via direnv (`use nix`) — pinned rustc, `protobuf`, and the
`cmake`/`perl`/`go`/`clang` toolchain `../sdk`'s vendored BoringSSL needs. `../sdk`'s
`build.rs` also needs `buf` on `PATH` (or `FYDE_PROTO_DIR=../server/protos`).

## How `run` works

`run` doesn't build a full `fyde_sdk::Client` (no server, login or sync is needed — a scraper
only talks to a third-party site). It calls `fyde_sdk::init_dev_scrapers`, which wires:

- cookie/session persistence as one JSON file per scraper under `--storage` (default `data/`,
  `cookies/` and `session/` subdirectories); the sdk saves each run's debug report under
  `--storage/reports/`;
- `DevDocumentsClient` (`../sdk/src/domains/documents/dev.rs`): `fyde.save_document` writes
  plain files under `--documents-dir` (default `data/documents`) instead of encrypting/uploading.

Each scraper's `parameters` come from `--secrets` (default `secret.json`, see
`secret.json.example`): `{"<scraper>": {"parameters": {...}}}`, passed as-is to the script's
`run(parameters)`. `--dev` forces `debug_http_dump` on for every scraper; `--visible` shows
the `fyde.browser` window. Progress prints to the terminal; `fyde.input.ask` blocks on stdin.

## `scrapers/<name>/manifest.json`

Committed next to `script.lua` (and `logo.png`). Fields (struct `ScraperManifest` in
`src/main.rs`):

- `name`, `description`, `short_description` — marketplace metadata sent by `publish`;
  `homepage` is not read by the CLI.
- `wreq_emulation` (required) — Chrome TLS/HTTP2 fingerprint for `fyde.http`; off only where
  a WAF rejects it anyway (e.g. `ameli`).
- `debug_http_dump` (default `false`) — record response bodies in the debug report (never
  request headers/bodies). Leave off unless debugging; prefer `--dev`.
- `follow_redirects` (default `true`) — set `false` to inspect a redirect (`Location`) yourself.
- `allowed_domains` — only these hosts (and subdomains) are reachable by `fyde.http` /
  `fyde.browser:open`; anything else fails the run. The sdk fails closed (an omitted or empty
  list allows nothing, whatever `src/main.rs`'s comment says), so every scraper must list its
  real sites, including third-party ones the login needs (e.g. `challenges.cloudflare.com`).
- `parameters` — what the user must supply (`label`, `placeholder`, `type`, `required`,
  `secret`), published with the script; `login_smoke.sh` builds fake credentials from it.
- `status` — `state` (`verified`/`broken`/`blocked`/`wip`), `last_updated`, the four checks
  (`login_page_found`, `invalid_credentials_detected`, `login_ok`, `documents_fetched`:
  `passed`/`failed`/`not_tested`/`not_applicable`), `antibot_name`/`antibot_status`, `notes`.
  Semantics are documented in README.md's "Status" section.

## Scraper contract

A script returns a table with a single `run(parameters)` function and only uses the `fyde`
host table (`log`, `http`, `html`, `json`, `progress`, `input`, `save_document`, `session`,
`browser`, `helpers`) — see `../sdk/src/domains/scrapers/host/`. The sandbox has no `require`,
`io`, `os` or `load`. Every scraper must:

- check the restored session first and skip login if valid, logging `ALREADY_LOGGED_IN`; log
  `LOGIN_PAGE_FOUND` once the login form/endpoint is recognised;
- fail with exactly `error("INVALID_CREDENTIALS", 0)` for a rejected username/password and
  `error("MFA_FAILED", 0)` for a rejected/unanswered one-time code (`helpers.fail` does this);
- call `fyde.progress.step` only with a `ProgressStep` name — `checking_session`,
  `logging_in`, `waiting_for_verification_code`, `waiting_for_captcha`, `listing_documents`,
  `downloading_documents`, `done` — any other string raises (the app words steps in the user's
  language); call it once when a stage starts, not per item. `fyde.progress.update(current,
  total)` takes no message;
- pass every `fyde.save_document` a `type` and a `category`/`subcategory` from README.md's
  "Document metadata" list (the sdk rejects a mismatched pair);
- keep a header comment stating what it scrapes and what is/isn't confirmed or blocked.

Shared helpers come from `fyde.helpers` (`../sdk/src/domains/scrapers/host/helpers.lua`): alias
the ones a script uses at its top (`local helpers = fyde.helpers`, `local fail = helpers.fail`,
...) instead of copying them. A helper more than one script needs goes into `helpers.lua` (an
sdk change), not into a script.

## Host gotchas (learned from verified scrapers)

- `fyde.http` can't read a cookie's value, and only downloads via GET.
- Cookies set in `fyde.browser` reach `fyde.http`'s jar only when the run ends, so `fyde.http`
  may get 401 right after a browser login — download through the webview instead
  (`fyde.browser:download` / `helpers.browser_save`, see `mercermasante`).
- A single long `wait_for` issued while a click navigates dies with the old page; poll with
  short repeated waits instead (`helpers.wait_state`, or `ameli`'s `wait_across_navigation`).
- Submit forms by `click`ing the real submit control: bot-mitigation JS hooks the real submit
  event (`ameli`).
- Some sites need cookies planted before login with `fyde.http.set_cookie` (`boursobank`).
- Datadome/Akamai-style protections and client-rendered pages usually need `fyde.browser`;
  record findings in the manifest's `antibot_*` fields and the script header.
