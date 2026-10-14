---
name: fix-script
description: "Debug and fix a broken Lua scraper script in this repo, in a fixed order: ask for secret.json + a token budget, ask for a fresh HAR capture of the login (and ideally a document fetch), then run/read report/diagnose/patch/retry until it passes, re-run to confirm it doesn't log in twice, and confirm documents + their upload metadata still come through. Use when asked to fix, debug, or get a scraper (didaxis, impots, ameli, edf, boursobank, cesu, pajemploi, scaleway, or a new one) working, or when told to run a script until it passes."
---

## What this loop does

A broken scraper name in; a working `scrapers/<name>/script.lua` (or a clear reason it can't be
fixed from here) out. The work happens in a fixed order — each numbered step below must be done
before the next starts:

1. Ask the user to confirm/update `secret.json` and to give a token budget for this task.
2. Ask the user for a fresh HAR capture of the login (and ideally a document fetch).
3. Run the script; loop **run -> read report -> diagnose -> patch -> retry** until it passes.
4. Re-run the script and confirm the second run does *not* log in again.
5. Confirm documents are still fetched and their upload metadata is still valid.

Stop and report to the user the moment you hit a blocker (see "Stopping" below) or the token
budget from step 1 — whichever comes first. Never declare success from stdout alone — only the
report's absence of an error entry (and, ideally, evidence a document was saved) means a run
actually finished clean.

This mirrors `create-script`'s loop mechanics (same run command including `--dev`, same report
format, same `secret.json` rule, same HAR-first/token-budget framing) but drives *backward* from
a known failure in an existing script rather than forward through new capability — if you're
instead building a script for a site with no `scrapers/<name>/script.lua` yet, use `create-script`
instead.

## 0. Before starting

Read `scrapers/<name>/script.lua` in full and skim this repo's `CLAUDE.md` section about that
script (the "Architecture" section documents, per script, what's confirmed vs. `TODO` vs.
architecturally blocked — e.g. Datadome on edf, no login flow for cesu/pajemploi,
client-side-rendered invoices on scaleway). If `CLAUDE.md` already flags the site as a probable
hard wall (no JS engine, bot detection), say so up front and ask the user whether to still
attempt it — don't burn iterations rediscovering a documented blocker.

## 1. Ask the user for `secret.json` and a token budget

Two separate asks, both before running anything:

- Check `scrapers/<name>/script.lua` for which `parameters` fields it reads (`parameters.username`,
  etc.) and confirm with the user that their `secret.json` entry for `<name>` still has matching
  fields — a renamed/missing field is a common, boring cause of a "broken" script that has
  nothing to do with the site itself. **Never read or write `secret.json` itself** — infer the
  expected shape from how the script reads `parameters`, and ask the user to check/update the
  real file themselves.
- Ask the user for a token budget for this task — a number they're comfortable spending before
  you must stop and report back, regardless of which step you're on. Record it. Note the
  `<total_tokens>N tokens left</total_tokens>` figure from the current system-reminder as your
  baseline; from here on, check that figure again after each step and treat `baseline - current`
  as tokens spent so far. The moment that exceeds the user's budget, stop immediately (even
  mid-step) and report progress per "Stopping" below — don't finish "just this one fix attempt"
  first.

## 2. Ask the user for a fresh HAR capture

Ask the user to record and send an up-to-date HAR file (from their own real, logged-in or
logging-in browser session) covering the login and — if they're willing — a document fetch.
A script that used to work and now doesn't is usually broken because the site's markup, login
flow, or URLs changed since it was written; a stale dump from a previous run's report can't show
you that, only what the old report already captured. Diffing the HAR's current `action`
URL/field names/markers against what `scrapers/<name>/script.lua` currently assumes is the
fastest way to confirm *what* changed before touching any code.

Read the HAR (it's JSON — a `log.entries[]` array, each with `request`/`response`) yourself.
Treat specific values in it (session cookies, CSRF tokens, an unredacted password) as
**ephemeral and not to be hardcoded** — only the URLs/field names/structure are durable. If
the user can't produce a fresh HAR (e.g. the account is locked, or they're not able to
reproduce the failure by hand either), fall back to diagnosing from the run report alone per
step 3, but say so — a diagnosis without a current HAR is weaker evidence.

## Reference: run loop mechanics (every step from here on uses this)

From the `scripts/` repo root, always with `--dev` (forces `debug_http_dump` on for this run,
so the report's HTTP entries include response bodies regardless of what `secret.json` sets).

Run the compiled binary directly rather than `cargo run` — this loop re-runs many times per
session (only `script.lua` changes between iterations, not Rust code), and `cargo run`
re-checks the whole dependency graph, including `../sdk`, on every invocation, which is slow
even when nothing actually changed. Only rebuild when the binary is missing or `../sdk` (or
this crate's own sources) changed since the last build:

```sh
BIN=target/debug/fyde-scripts
if [ ! -x "$BIN" ] || [ -n "$(find ../sdk/src ../sdk/Cargo.toml ../sdk/build.rs src Cargo.toml -newer "$BIN" -type f 2>/dev/null)" ]; then
  cargo build
fi
"$BIN" <name> --dev
```

Before running, note the current newest file (if any) under `data/reports/<name>_*.json` (e.g.
via `ls -t data/reports/<name>_*.json 2>/dev/null | head -1`), so you can tell which report file
is the new one afterwards — file names are `<name>_<started_at_ms>.json`, which also sort
correctly by recency.

**Never read `secret.json` or any `secret*.json` file.** The runner reads it directly; you never
need its contents to diagnose a failure.

**If the script calls `fyde.input.ask`** (session needs an MFA code, etc.), the process blocks
on stdin. This loop is not equipped to supply real third-party secrets or codes interactively —
if a run hangs waiting on a question, stop, tell the user what's being asked for, and let them
either run it by hand or paste the value back to you for one manual iteration.

Read the newest `data/reports/<name>_*.json` file after each run. It's a JSON-serialized run
report: a `scraper_name`, a start timestamp, and an ordered `entries` list, each with a
timestamp, an event name, and a value — covering every `fyde.log`/`fyde.http`/`fyde.progress`/
`fyde.input` call made during the run, plus a trailing error entry if the script's `run` raised.
Treat the exact field names as a snapshot, not a contract — skim the actual file rather than
assuming a fixed shape, since this report format is internal and has changed before.

What to pull out:

- **The last progress step reached** before things went wrong — tells you how far execution
  got (e.g. "Finding the Documents section" means login/session succeeded but the next phase
  didn't).
- **The error entry's message**, if present — usually a Lua runtime error with a
  `[string "<name>"]:<line>` stack traceback. That line number indexes directly into
  `scrapers/<name>/script.lua`.
- **HTTP entries** (status, URL, timing, and body — present because `--dev` forces
  `debug_http_dump` on for this run) — these tell you what the site actually returned, which is
  usually more informative than the Lua error message alone (e.g. a 200 with a login form
  instead of the documents page means a selector or logged-out check is wrong, not that the
  request itself failed).
- **No error entry at all** plus a plausible final progress step is the success signal. Corroborate
  it if you can (a `document_saved`-shaped entry, or a new file under `documents/`).

## 3. Run, diagnose, patch, retry

Open `scrapers/<name>/script.lua` at the failing line reported by the run above. Cross-check it
against the HAR from step 2. Common root causes, roughly in order of likelihood given this
repo's scripts:

- A CSS/HTML selector (`fyde.html.select`) no longer matches — the site's markup changed, or the
  selector was guessed/ported from a Python source and never verified. Compare the HAR's current
  response body (or the run's dumped HTTP entry body) against what the selector expects.
- A "logged out" marker (text/regex check) is wrong or too broad/narrow — it fires on a page that
  is actually fine, or misses a real logout.
- A URL changed (redirect target, path, query params) — compare against the HAR's or the run
  report's HTTP entry's actual `url`/`status`.
- The script expects a prior session/cookie to already be authenticated (several of these
  scripts — see `CLAUDE.md` — have no automated login and rely on a previously-restored
  session). If the failure is "logged out" on a script that never logs in itself, that may be
  expected and not a bug in the script at all — say so rather than inventing a login flow that
  doesn't exist yet.
- Architecturally blocked (Datadome, client-rendered SPA, no JS engine) — if the HAR or the HTTP
  entries show a bot-detection challenge page or the expected content simply isn't in the HTML
  this host fetched, this isn't fixable by editing the Lua script. Stop and report that, per
  `CLAUDE.md`'s own framing for the affected scripts — don't keep tweaking selectors against a
  page that was never going to contain the data.

You cannot exercise authenticated requests yourself (no credentials, no browser) — your evidence
is entirely the HAR plus the report's HTTP entries. Don't guess at a fix that isn't grounded in
something one of those two actually showed you.

Edit `scrapers/<name>/script.lua` with the smallest change that addresses the diagnosed cause,
then re-run per the mechanics above. Each iteration, compare the new report's
last-progress-step/error against the previous one:

- **Progressed further** (new error further into the script, or none) — the fix worked or at
  least helped; keep going on the new failure.
- **Same error, same line** — the edit didn't address the real cause; revisit the HAR/diagnosis
  instead of making a cosmetic variant of the same guess.
- **Regressed** (fails earlier than before) — revert that edit's reasoning, it broke something
  that was working.

**Advance when:** a run completes with no error entry and the script's own stated goal reached
(login confirmed, or further, depending on what was broken).

## 4. Re-run and confirm the second run doesn't log in again

Once step 3 produces a clean run, run the exact same binary invocation a second time, with the
session/cookie state that run left behind still in place (don't wipe
`data/session/<name>.json`/`data/cookies/<name>.cookies.json` first — that's the point of this
check). Read the new report and confirm:

- the script's `is_logged_in`-style check (or equivalent) passed on the restored session, and
- the login request was **not** issued a second time (no new `fyde.http.post_form`/`post_json`
  entry to the login URL in this run's report).

If the second run logs in again anyway, the fix broke (or never covered) the already-logged-in
check or the session/cookie restore — go back to step 3 and fix that specifically, then repeat
step 4 until a second consecutive run skips login. This matters even for a script that didn't
need a login fix at all: a patch elsewhere (a selector, a URL) can still regress this if it
touches shared code.

## 5. Confirm documents and their upload metadata

If the script's job includes fetching documents, confirm the clean run from step 4 still saved
at least one real document under `data/documents/<name>/` (content-type/byte-size consistent
with a real file, not an HTML error page saved under a `.pdf` name), and that every
`fyde.save_document(name, content, fields)` call's `fields` table still has valid values —
`source_category`/`source_sub_category`/`purpose` are enums (see
`../sdk/src/domains/documents/models.rs`); a run error naming one of them means the fix
introduced or left behind an invalid value. If the original breakage touched this logic at all,
re-run once more per the mechanics above after any change here.

## Stopping

- **Success**: step 5 confirms a clean run with no error entry, step 4's double-run check held,
  and (if applicable) documents + metadata still come through. Report what was wrong and what
  changed, and stop — don't keep iterating past a good run "to be safe."
- **Stuck**: the same failure survives a genuine fix attempt with a different hypothesis, or the
  blocker is architectural (bot detection, no JS engine, no login flow to reverse-engineer). Say
  plainly what's blocking it and why further script edits won't help, per `CLAUDE.md`'s own
  framing for that site — don't loop indefinitely on a dead end.
- **Token budget hit**: per step 1, the moment `baseline - current` from the
  `<total_tokens>N tokens left</total_tokens>` reminder exceeds the budget the user gave you,
  stop wherever you are (even mid-step) and report which step you reached and what's left.
- **Needs the user**: a missing/incomplete HAR, an MFA/question prompt, or a diagnosis that
  depends on seeing an authenticated page you have no way to fetch yourself.

Never commit or push as part of this loop unless asked — leave the fixed/in-progress script as
working-tree changes for the user to review.
