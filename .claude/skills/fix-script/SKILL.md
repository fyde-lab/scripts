---
name: fix-script
description: "Iteratively debug and fix a broken Lua scraper script in this repo by running it, reading its debug report, patching the script, and re-running — repeating until the run succeeds or the loop is stuck. Use when asked to fix, debug, or get a scraper (didaxis, impots, ameli, edf, boursorama, eaudubassinrennais, cesu, pajemploi, scaleway, or a new one) working, or when told to run a script until it passes."
---

## What this loop does

One scraper name in, a working `scripts/<name>/script.lua` (or a clear reason it can't be
fixed from here) out. Each iteration: **run → read report → diagnose → patch → run again.**
Never declare success from stdout alone — only the report's absence of an error entry (and,
ideally, evidence a document was saved) means the run actually finished clean.

## 0. Before starting

Read `scripts/<name>/script.lua` in full and skim this repo's `CLAUDE.md` section about that
script (the "Architecture" section documents, per script, what's confirmed vs. `TODO` vs.
architecturally blocked — e.g. Datadome on boursorama/edf, no login flow for cesu/pajemploi,
client-side-rendered invoices on scaleway). If `CLAUDE.md` already flags the site as a probable
hard wall (no JS engine, bot detection), say so up front and ask the user whether to still
attempt it — don't burn iterations rediscovering a documented blocker.

**Never read `secret.json` or any `secret*.json` file.** The runner reads it directly; you never
need its contents to diagnose a failure. If a fix genuinely requires knowing what fields a
script's `parameters` table has, infer them from how the script reads them
(`parameters.username`, etc.), not from the secrets file.

## 1. Run

From the `scripts/` repo root:

```sh
cargo run -- <name>
```

Before running, note the current newest file (if any) under `data/reports/<name>_*.json` (e.g.
via `ls -t data/reports/<name>_*.json 2>/dev/null | head -1`), so you can tell which report file
is the new one afterwards — file names are `<name>_<started_at_ms>.json`, which also sort
correctly by recency.

**If the script calls `fyde.input.ask`** (session needs an MFA code, etc.), the process blocks
on stdin. This loop is not equipped to supply real third-party secrets or codes interactively —
if a run hangs waiting on a question, stop, tell the user what's being asked for, and let them
either run it by hand or paste the value back to you for one manual iteration.

## 2. Read the report

Read the newest `data/reports/<name>_*.json` file. It's a JSON-serialized run report: a
`scraper_name`, a start timestamp, and an ordered `entries` list, each with a timestamp, an
event name, and a value — covering every `fyde.log`/`fyde.http`/`fyde.progress`/`fyde.input`
call made during the run, plus a trailing error entry if the script's `run` raised. Treat the
exact field names as a snapshot, not a contract — skim the actual file rather than assuming a
fixed shape, since this report format is internal and has changed before.

What to pull out:

- **The last progress step reached** before things went wrong — tells you how far execution
  got (e.g. "Finding the Documents section" means login/session succeeded but the next phase
  didn't).
- **The error entry's message**, if present — usually a Lua runtime error with a
  `[string "<name>"]:<line>` stack traceback. That line number indexes directly into
  `scripts/<name>/script.lua`.
- **HTTP entries** (status, URL, timing, and body if `debug_http_dump` was set for this scraper
  in `secret.json` — you can't see that flag's value, but you can see its effect: a dumped body
  present or absent in the entry) — these tell you what the site actually returned, which is
  usually more informative than the Lua error message alone (e.g. a 200 with a login form
  instead of the documents page means a selector or logged-out check is wrong, not that the
  request itself failed).
- **No error entry at all** plus a plausible final progress step is the success signal. Corroborate
  it if you can (a `document_saved`-shaped entry, or a new file under `documents/`).

## 3. Diagnose

Open `scripts/<name>/script.lua` at the failing line. Common root causes, roughly in order of
likelihood given this repo's scripts:

- A CSS/HTML selector (`fyde.html.select`) no longer matches — the site's markup changed, or the
  selector was guessed/ported from a Python source and never verified. Check what the HTTP
  entry actually returned (dumped body, or re-fetch the same public URL yourself with
  `curl`/`WebFetch` if it doesn't require auth) against what the selector expects.
- A "logged out" marker (text/regex check) is wrong or too broad/narrow — it fires on a page that
  is actually fine, or misses a real logout.
- A URL changed (redirect target, path, query params) — compare against the HTTP entry's actual
  `url`/`status`.
- The script expects a prior session/cookie to already be authenticated (several of these
  scripts — see `CLAUDE.md` — have no automated login and rely on a previously-restored
  session). If the failure is "logged out" on a script that never logs in itself, that may be
  expected and not a bug in the script at all — say so rather than inventing a login flow that
  doesn't exist yet.
- Architecturally blocked (Datadome, client-rendered SPA, no JS engine) — if the HTTP entries
  show a bot-detection challenge page or the expected content simply isn't in the HTML this host
  fetched, this isn't fixable by editing the Lua script. Stop and report that, per `CLAUDE.md`'s
  own framing for the affected scripts — don't keep tweaking selectors against a page that was
  never going to contain the data.

You cannot exercise authenticated requests yourself (no credentials, no browser) — your evidence
is entirely the report's HTTP entries plus whatever public pages you can fetch directly. Don't
guess at a fix that isn't grounded in something the report or a fetched page actually showed you.

## 4. Patch and loop

Edit `scripts/<name>/script.lua` with the smallest change that addresses the diagnosed cause.
Then go back to step 1. Each iteration, compare the new report's last-progress-step/error against
the previous one:

- **Progressed further** (new error further into the script, or none) — the fix worked or at
  least helped; keep going on the new failure.
- **Same error, same line** — the edit didn't address the real cause; revisit the diagnosis
  instead of making a cosmetic variant of the same guess.
- **Regressed** (fails earlier than before) — revert that edit's reasoning, it broke something
  that was working.

## Stopping

- **Success**: a run with no error entry and a plausible final state (document saved, or the
  script's own stated goal reached). Report what was wrong and what changed, and stop — don't
  keep iterating past a good run "to be safe."
- **Stuck**: the same failure survives a genuine fix attempt with a different hypothesis, or the
  blocker is architectural (bot detection, no JS engine, no login flow to reverse-engineer). Say
  plainly what's blocking it and why further script edits won't help, per `CLAUDE.md`'s own
  framing for that site — don't loop indefinitely on a dead end.
- **Needs the user**: an MFA/question prompt, or a diagnosis that depends on seeing an
  authenticated page you have no way to fetch yourself.

Never commit or push as part of this loop unless asked — leave the fixed/in-progress script as
working-tree changes for the user to review.
