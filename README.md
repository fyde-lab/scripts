# fyde-scripts

The canonical home for the Lua scraper scripts run by `fyde-sdk`'s `scrapers` domain
(`scripts/scripts/didaxis/script.lua`, `scripts/scripts/impots/script.lua`), plus a standalone CLI runner — ported from
`demo-rust-fyde` — that drives them through `fyde-sdk`'s `ScrapersService::run` directly,
without a full `Client`/server connection.

## Usage

```sh
cp secret.json.example secret.json  # then fill in real credentials, never commit it
cargo run                           # scripts/didaxis/script.lua by default
cargo run -- --script scripts/impots/script.lua
```

Downloaded documents are written under `--documents-dir` (default `documents/`, gitignored).
Cookies and session data persist across runs in a local SQLite database at `--storage`
(default `data/scrapers.db`, gitignored). Each run also writes a debug report to
`--report-dir` (default `reports/`, gitignored) as `<scraper>_<dd-mm-yy>_<hh-mm-ss>.json`.

Progress (`fyde.progress.step`/`.update`) is printed to the terminal as it happens; a script
that calls `fyde.input.ask` (e.g. for an MFA code) prints the question and blocks on a line of
stdin.

See `CLAUDE.md` for the full architecture.
