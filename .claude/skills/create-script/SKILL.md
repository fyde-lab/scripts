---
name: create-script
description: "Write a brand-new Lua scraper script for a given website from scratch, in a fixed order: ask for secret.json + a token budget, ask for an HAR capture of the login (and ideally a document fetch), write manifest.json, recreate the login flow with an already-logged-in check, run/fix/retry until it passes, re-run to confirm it doesn't log in twice, fetch documents, then add upload metadata. Use when asked to write, create, add, or port a new scraper/script for a site that has no scrapers/<name>/script.lua yet."
---

## What this loop does

A site name, a human-supplied HAR capture, and a login the user can supply credentials for in;
a new `scrapers/<name>/script.lua` out. The work happens in a fixed order — each numbered step
below must be done before the next starts:

1. Ask the user to fill in `secret.json` and to give a token budget for this task.
2. Ask the user for an HAR capture of the login (and ideally a first document fetch).
3. Write `scrapers/<name>/manifest.json`.
4. Recreate the login flow from the HAR, plus an already-logged-in check.
5. Run the script; loop **run -> read report -> fix -> retry** until it logs in cleanly.
6. Re-run the script and confirm the second run does *not* log in again.
7. Fetch the documents.
8. Add metadata to the document upload.

Stop and report to the user the moment you hit a blocker (see "Stopping" below) or the token
budget from step 1 — whichever comes first. Don't skip ahead: a later step's write/patch -> run
-> read report -> fix -> advance loop assumes every earlier step already passed for real,
against an actual run's report, not against an assumption of how the site "probably" works.

This mirrors `fix-script`'s loop mechanics (same run command including `--dev`, same report
format, same `secret.json` rule) but drives *forward* through new capability rather than
backward from a known failure — if you get stuck debugging a step that already seemed to work
before, switch to reasoning the way `fix-script` does rather than re-deriving it here.

## Never call the website directly

You must not fetch, browse, or otherwise load any page of the target site yourself (no
`WebFetch`, no `claude-in-chrome`/browser tools, no ad-hoc `curl`). The only things you're
allowed to look at are the HAR file the user gives you in step 2 and the script's own runs —
the only thing you're allowed to edit is `scrapers/<name>/script.lua` (and
`scrapers/<name>/manifest.json`). This keeps every byte you reason about something either the
user's own real browser session captured, or the script itself actually fetched through
`fyde.http`, under the same cookie jar/session it'll run with unattended — a page you loaded by
hand (different cookies, different IP, a logged-in browser session) can look nothing like what
the script sees. If a run needs to see a page beyond what the HAR already showed, add the
`fyde.http.get`/`post_form` call that reaches it to the script and run it (with `--dev`) rather
than looking it up yourself.

## 0. Before starting

- Check `scrapers/<name>/` doesn't already exist. If it does, this is a fix/extend job for
  `fix-script`, not a new script.
- Skim this repo's `CLAUDE.md` for whether the site is already known to be a hard wall (Datadome,
  client-rendered SPA, no JS engine). This host has **no JS engine and no real browser** — it's
  plain HTTP (`fyde.http`) + server-side HTML parsing (`fyde.html.select`, a CSS selector engine).
  If the HAR you get in step 2 shows the login or document pages are rendered client-side by JS,
  say so up front rather than discovering it after burning several iterations.
- Create `scrapers/<name>/script.lua` with a header comment (site name/URL, one line on what it
  scrapes) and a minimal skeleton, leaving the body to steps 4+:

  ```lua
  local M = {}

  function M.run(params)
    fyde.progress.step("Checking for an existing session")
    -- filled in step by step below
  end

  return M
  ```

## 1. Ask the user for `secret.json` and a token budget

Two separate asks, both before writing any real logic:

- Ask (if not already given) for the site's base URL and which `secret.json` fields the login
  needs (conventionally `username`/`password`, but e.g. `impots` uses `fiscal-number`). Add a
  `"<name>": {"parameters": {...}}` entry to `secret.json.example` (never to the real,
  gitignored `secret.json`) documenting the shape you're relying on, then ask the user to add
  the matching real entry to their own `secret.json` — **never read or write `secret.json`
  itself.**
- Ask the user for a token budget for this task — a number they're comfortable spending before
  you must stop and report back, regardless of which step you're on. Record it. Note the
  `<total_tokens>N tokens left</total_tokens>` figure from the current system-reminder as your
  baseline; from here on, check that figure again after each step and treat `baseline - current`
  as tokens spent so far. The moment that exceeds the user's budget, stop immediately (even
  mid-step) and report progress per "Stopping" below — don't finish "just this one step" first.

## 2. Ask the user for an HAR capture

Ask the user to record and send an HAR file (from their own real, logged-out browser session)
covering: loading the homepage, submitting the login form, and — if they're willing to log in
for it — fetching at least one document afterward. This is the one legitimate source of real
site traffic in this loop besides the script's own runs (see "Never call the website directly"
above); it's what step 4 and step 7 are built from, so don't proceed to either without it.

Read the HAR (it's JSON — a `log.entries[]` array, each with `request`/`response`) yourself to
find: the login form's exact `action` URL and field names, whether it's a form POST or a JSON
API call, any request headers the site insists on (beyond cookies, which the host manages for
you), and the document-fetch entry's URL shape if present. Treat specific values in it
(session cookies, CSRF tokens, the actual password if the user didn't redact it) as
**ephemeral and not to be hardcoded** — they belong to that one browser session, not to the
script; only the URLs/field names/structure are durable. If the HAR shows the login is a
JS-driven SPA call you can't just replay as a plain `fyde.http` request, or sits behind an
OPAQUE-style/WebAuthn flow this host can't drive, that's a hard wall — stop and report it per
`CLAUDE.md`'s framing for other blocked sites rather than building further steps behind it.

## 3. Write `manifest.json`

Create `scrapers/<name>/manifest.json` per this repo's `CLAUDE.md`: a `{"name", "description",
"short_description", "homepage", "wreq_emulation", "debug_http_dump", "follow_redirects",
"allowed_domains", "status"}` object.

- `status` — `{"state": "wip", "login_page_found", "invalid_credentials_detected",
  "login_ok", "documents_fetched"}`, each check `passed`/`failed`/`not_tested`/`not_applicable`
  (plus an optional `notes` string; see `README.md`'s Status section). Start every check at
  `not_tested` and update them, and `state`, as the steps below pass or fail.
- `name`/`description`/`short_description`/`homepage` — marketplace metadata; write something
  accurate for the site now, even though nothing reads it until `publish`.
- `wreq_emulation` — leave `true` (the default) unless the HAR or an early run's report shows
  the site's WAF blocks `wreq`'s TLS fingerprint outright regardless of emulation (per `ameli`'s
  precedent) — that's a hard wall, not a setting to tune around.
- `debug_http_dump` — leave `false`; this loop always passes `--dev` on the command line instead,
  which forces it on for every run without touching this file.
- `follow_redirects` — leave `true` unless the HAR shows the script needs to inspect a redirect
  itself (e.g. a `Location` header) rather than being carried straight to its target.
- `allowed_domains` — set explicitly from every host you actually saw requests hit in the HAR
  (e.g. `["impots.gouv.fr"]` covering both `cfspart.impots.gouv.fr` and
  `cfspart-idp.impots.gouv.fr`). Don't leave this unrestricted — a call to any other host fails
  closed, which is the point.

## Reference: the fyde host API

Every capability the script can use is the `fyde` global table — nothing else is reachable (no
`io`, `os`, sockets). Full reference, ported 1:1 from `../sdk/src/domains/scrapers/host/*.rs`:

- `fyde.http.get(url, headers?)`, `fyde.http.post_form(url, form_table, headers?)`,
  `fyde.http.download(url, headers?)` — each returns `{ status, url, body, content_type? }`
  (`download` omits `url`, adds `content_type`). The cookie jar persists automatically across
  calls within a run, and across runs via `fyde.session`/the restored session store — never
  manage cookies by hand.
- `fyde.html.select(html, css_selector)` — returns an array of
  `{ text = "...", html = "<outer html>", attrs = { href = "...", ... } }`, one per match. This
  is your only way to read a page's structure; there's no JS, no XPath.
- `fyde.json.decode(text)` / `fyde.json.encode(value)` — for sites with a JSON API instead of (or
  alongside) HTML forms.
- `fyde.progress.step(name)` — announce a new high-level stage (call once per step below).
  `fyde.progress.update(current, total, message)` — fine-grained progress within a step (e.g.
  while downloading N documents).
- `fyde.log.info/warn/error/debug(message)` — goes into the run's debug report.
- `fyde.input.ask(question)` — blocks for an interactively-supplied value (MFA code). Only use
  this if the login genuinely needs one; it can't be answered unattended by this loop (see
  step 4).
- `fyde.save_document(name, content, fields?)` — uploads a downloaded document. `name` only needs
  to end in `.pdf`; it's a hint, not the document's real identity. The optional `fields` table
  (used in step 8) sets any of `name`, `type`, `category`, `subcategory`, `attributes`
  up front instead of leaving them for a later classification pass — see
  `../sdk/src/domains/documents/models.rs` for each field's valid enum values (`type`: what kind
  of paper it is, never the sector: `invoice`/`receipt`/`statement`/`reimbursement_statement`/`payslip`/`contract`/
  `insurance_certificate`/`insurance_card`/`rights_certificate`/`proof_of_residence`/`rib`/
  `tax_notice`/`tax_return`/`tax_certificate`/`employment_certificate`/`fee_summary`/`booking`/
  `medical_document`/`other`; `category`/`subcategory`: the part of life it's
  about, see README.md's "Document metadata" for the tree). `attributes` maps `snake_case`
  names to typed values: `{ type = "string"|"integer"|"float"|"boolean", value = ... }`,
  `{ type = "date", value = "2026-10-15" }` (ISO, never the site's own format),
  `{ type = "amount", value = { minor_units = 215050, currency = "EUR" } }` (an integer count
  of cents — `math.floor(x * 100 + 0.5)`, never a float amount) or
  `{ type = "select", value = { selected = "paid", options = { "paid", "unpaid" } } }`.
  Use one of the default attribute names whenever one fits (`issued_on`, `reference`,
  `period_start`/`period_end`, `total_amount`, `due_on`, `net_pay`, `tax_year`... — seeded by
  `../server/migrations/0012_create_attributes.sql`): a value of any other type than the one
  defined there is rejected on upload.
- `fyde.session` — a plain Lua table you can read/write; whatever's in it when `run` returns is
  persisted and restored verbatim on the next run. Use it only for state beyond what the cookie
  jar already gives you for free (cookies restore automatically already).

### Run loop mechanics (every step from here on uses this)

From the `scripts/` repo root, always with `--dev` (forces `debug_http_dump` on, so the report's
HTTP entries include response bodies without needing to touch `secret.json`).

Run the compiled binary directly rather than `cargo run` — this loop re-runs many times per
step (only `script.lua` changes between iterations, not Rust code), and `cargo run` re-checks
the whole dependency graph, including `../sdk`, on every invocation, which is slow even when
nothing actually changed. Only rebuild when the binary is missing or `../sdk` (or this crate's
own sources) changed since the last build:

```sh
BIN=target/debug/fyde-scripts
if [ ! -x "$BIN" ] || [ -n "$(find ../sdk/src ../sdk/Cargo.toml ../sdk/build.rs src Cargo.toml -newer "$BIN" -type f 2>/dev/null)" ]; then
  cargo build
fi
"$BIN" <name> --dev
```

Note the newest `data/reports/<name>_*.json` before running (`ls -t data/reports/<name>_*.json
2>/dev/null | head -1`) so you can identify the new report file afterwards.

**Never read `secret.json` or any `secret*.json` file.** If a run needs a value you don't have
(a field name, an MFA code), ask the user rather than guessing or peeking at the file.

**If the script calls `fyde.input.ask`**, the process blocks on stdin. This loop can't supply
real third-party secrets/codes — stop, tell the user what's being asked, and let them either run
it by hand or hand you the value back for one manual iteration.

Read the newest `data/reports/<name>_*.json` after each run exactly as `fix-script` describes:
last progress step reached, the error entry's message/line (if any), and HTTP entries (status,
url, timing, and body — present thanks to `--dev`) — these tell you what the site actually
returned, which is more informative than the Lua error alone.

## 4. Recreate the login flow, plus an already-logged-in check

Using only the HAR from step 2 as ground truth (never guessed from memory of how the site
"probably" works), write the login logic:

- A `BASE` constant and the login form's/API's exact `action` URL and field names, per the HAR.
- An `is_logged_in(html)` (or equivalent JSON-shape) check: a pattern match on a known
  logged-in marker vs. a login-page marker — see `didaxis/script.lua`'s version for the pattern.
  Call this **first**, before attempting login, so a restored session that's already
  authenticated skips the login POST entirely — this is what step 6 verifies.
- The `login(params)` function itself: a `fyde.http.post_form` (or `post_json`, if the HAR shows
  a JSON API) to that action URL, with the field names found there mapped to
  `params.username`/`params.password` (or whatever the site's own field names are — keep
  `params`'s keys matching `secret.json`'s conventional `username`/`password` unless the site's
  own terminology strongly suggests otherwise, as `impots` does with `fiscal-number`). Run
  `is_logged_in` again right after the POST to confirm it actually worked — a 200 with the login
  form still in the body means the credentials were rejected or the field names are wrong.

If the login needs an MFA/OTP step, wire `fyde.input.ask` in for it, but don't try to drive it
through this unattended loop — tell the user once you reach this point so they can supply it
interactively for a one-off manual verification.

## 5. Run, fix, retry until login succeeds

Run per the mechanics above. Each iteration, compare the new report's last-progress-step/error
against the previous one:

- **Progressed further** (new error further into the script, or none) — the fix worked or at
  least helped; keep going on the new failure.
- **Same error, same line** — the edit didn't address the real cause; revisit the HAR instead of
  making a cosmetic variant of the same guess.
- **Regressed** (fails earlier than before) — revert that edit's reasoning, it broke something
  that was working.

**Advance when:** the report shows the post-login page passing `is_logged_in`, confirmed against
the real HTTP response, not assumed from a 200 status alone.

## 6. Re-run and confirm the second run doesn't log in again

Run the exact same binary invocation a second time, with the session/cookie state step 5 left
behind still in place (don't wipe `data/session/<name>.json`/`data/cookies/<name>.cookies.json`
first — that's the point of this check). Read the new report and confirm:

- `is_logged_in`'s pre-login check passed on the restored session, and
- the login POST was **not** issued a second time (no new `fyde.http.post_form`/`post_json`
  entry to the login URL in this run's report).

If the second run logs in again anyway, the `is_logged_in` check or the session/cookie restore
is wrong — fix it and repeat step 6 (not step 5) until a second consecutive run skips login.
Logging in on every single run is the kind of thing that gets an account rate-limited or
flagged, so don't treat this as optional polish.

## 7. Fetch the documents

Once a logged-in session is confirmed stable across runs, use `fyde.html.select` against the
authenticated page(s) to locate the documents section(s) — a dashboard link, a dedicated
"documents"/"bills"/"payslips" page per `didaxis/script.lua`'s `SECTIONS` pattern (and per
whatever the HAR's document-fetch entry, if present, already showed). For each extracted
document link: resolve it to an absolute URL, `fyde.http.download(url)` it, check
`status == 200` and that `content_type` isn't HTML (an HTML response usually means a
logged-out redirect or wrong URL, not a real file), then `fyde.save_document(filename, body)`
with a sanitized filename (see `didaxis/script.lua`'s `sanitize` helper: strip control chars,
collapse whitespace, replace path-unsafe characters, cap length). Log a warning (not an error)
for any single document that fails to download, so one bad link doesn't abort the whole run.

**Advance when:** the report (and `data/documents/<name>/`) shows at least one real document
saved, with content-type/byte-size consistent with a real file, not an HTML error page saved
under a `.pdf` name — go back through the run/fix/retry loop from step 5 if not.

## 8. Add metadata to the document upload

Pass `fyde.save_document`'s third `fields` argument on every call from step 7, instead of
leaving every document's metadata for a later classification pass. At minimum set `name` (a
human-readable title, not just the sanitized filename), `type`, and the `category`/
`subcategory` the site belongs to (README.md's "Document metadata" lists the tree; a
`subcategory` alone is enough, it implies its category); override them per document where the
site's own page structure makes another value obvious (e.g. a bank's tax-form section is
`type = "tax_certificate"`, `subcategory = "tax_certificates"`) — don't guess a value the page
gives you no actual signal for.
Re-run once more (per step 5's mechanics) after adding this and confirm the report shows no
error from an invalid value (`fyde.save_document` rejects an unrecognized `type`/`category`/
`subcategory`, and a `subcategory` outside its `category`).

## Stopping

- **Success**: step 8 completes — documents are fetched, saved with metadata, and step 6's
  double-run check held. Report what the script does and where it still might be fragile
  (guessed selectors not visible in the HAR/test account, etc.), and stop.
- **Stuck on a given step**: the same failure survives a genuinely different hypothesis at that
  step (per `fix-script`'s diagnosis framing — selector drift, wrong URL, logged-out marker,
  bot-detection, no JS engine). Say plainly which step is blocked and why, rather than guessing
  further at the same step indefinitely.
- **Token budget hit**: per step 1, the moment `baseline - current` from the
  `<total_tokens>N tokens left</total_tokens>` reminder exceeds the budget the user gave you,
  stop wherever you are (even mid-step) and report which step you reached and what's left.
- **Needs the user**: missing `secret.json` fields, a missing/incomplete HAR, an MFA/question
  prompt, or any page you need to see authenticated that you have no way to fetch yourself.

Never commit or push as part of this loop unless asked — leave the new script as working-tree
changes (plus the `secret.json.example` and `manifest.json` additions) for the user to review.
