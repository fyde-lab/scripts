---
name: create-script
description: "Write a brand-new Lua scraper script for a given website from scratch, driving it through five staged steps (homepage, find login, log in, find documents, download documents) with a run -> read report -> fix -> advance loop at each step. Use when asked to write, create, add, or port a new scraper/script for a site that has no scripts/<name>/script.lua yet."
---

## What this loop does

A site name (and a login the user can supply credentials for) in, a new
`scripts/<name>/script.lua` out — built up incrementally, one capability at a time, each one
verified against a real run before moving to the next. Never write the whole script in one shot
and hope it works: each of the five steps below is its own **write/patch -> run -> read report ->
fix -> advance** loop, and you only advance to the next step once the current one's report shows
it actually succeeded. Once all five are clear, a final step (7, below) wipes all persisted state
and re-runs from scratch to make sure nothing was secretly relying on leftovers from an earlier
iteration — looping on that clean run (read report -> fix -> wipe state -> re-run) until it
passes unattended.

This mirrors `fix-script`'s loop mechanics (same run command including `--dev`, same report
format, same `secret.json` rule) but drives *forward* through new capability rather than
backward from a known failure — if you get stuck debugging a step that already seemed to work
before, switch to reasoning the way `fix-script` does rather than re-deriving it here.

## Never call the website directly

You must not fetch, browse, or otherwise load any page of the target site yourself (no
`WebFetch`, no `claude-in-chrome`/browser tools, no ad-hoc `curl`). The only thing you're allowed
to edit is `scripts/<name>/script.lua`; the only way you're allowed to see what the site returns
is by running it (`cargo run -- <name> --dev`) and reading the HTTP entries' response bodies in
the resulting `data/reports/<name>_*.json` dump. This keeps every byte you reason about something
the script itself actually fetched through `fyde.http`, under the same cookie jar/session it'll
run with unattended — a page you loaded by hand (different cookies, different IP, a logged-in
browser session) can look nothing like what the script sees. If you need to see a different page
than what's already in the dump, add the `fyde.http.get`/`post_form` call that reaches it to the
script and run it again rather than looking it up yourself.

## 0. Before starting

- Check `scripts/<name>/` doesn't already exist. If it does, this is a fix/extend job for
  `fix-script`, not a new script.
- Skim this repo's `CLAUDE.md` for whether the site is already known to be a hard wall (Datadome,
  client-rendered SPA, no JS engine). This host has **no JS engine and no real browser** — it's
  plain HTTP (`fyde.http`) + server-side HTML parsing (`fyde.html.select`, a CSS selector engine).
  If the site's login or document pages are rendered client-side by JS, say so up front rather
  than discovering it after burning several iterations.
- Ask the user (if not already given) for the site's base URL and which `secret.json` fields the
  login needs (conventionally `username`/`password`, but e.g. `impots` uses `fiscal-number`).
  Add a `"<name>": {"parameters": {...}}` entry to `secret.json.example` (never to the real,
  gitignored `secret.json`) documenting the shape you're relying on.
- Create `scripts/<name>/script.lua` with a header comment (site name/URL, one line on what it
  scrapes) and a minimal skeleton:

  ```lua
  local M = {}

  function M.run(params)
    fyde.progress.step("Checking for an existing session")
    -- filled in step by step below
  end

  return M
  ```

- Add a `"<name>": { "parameters": {...} }` block to the user's real `secret.json` is their job,
  not yours — **never read or write `secret.json` itself.** Ask them to add it (pointing at the
  `.example` entry you just wrote) before the first run.

## The fyde host API

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
  step 3).
- `fyde.save_document(relative_filename, bytes)` — writes a downloaded document. Use a filename
  that's stable and sanitized (see `didaxis/script.lua`'s `sanitize` helper for a pattern to
  copy: strip control chars, collapse whitespace, replace path-unsafe characters, cap length).
- `fyde.session` — a plain Lua table you can read/write; whatever's in it when `run` returns is
  persisted and restored verbatim on the next run. Use it only for state beyond what the cookie
  jar already gives you for free (cookies restore automatically already).

## 1. Run loop (every step below uses this)

From the `scripts/` repo root, always with `--dev` (forces `debug_http_dump` on, so the report's
HTTP entries include response bodies without needing to touch `secret.json`):

```sh
cargo run -- <name> --dev
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

## 2. Step 1 — Go to the homepage

Add a `BASE` constant and a first `fyde.http.get(BASE)`. Goal: confirm the base URL is right and
see what an anonymous visit returns (status 200, and does the body look like the expected site,
not a captcha/bot-detection page already at this stage).

**Advance when:** the report shows a 200 (or an expected redirect) and the body is plausibly the
site's real homepage, not a bot-detection challenge. If it's already blocked here, stop and
report that per `CLAUDE.md`'s framing for other blocked sites — no point building further steps
behind a wall that starts at the front door.

## 3. Step 2 — Find the login page or login form

From the homepage body (or a `/login`-shaped URL you can guess/confirm), use
`fyde.html.select` to locate the login `<form>`: its `action` URL and the `name`/`id` attributes
of its username/password inputs. If the homepage already contains the form inline (no separate
login page), that's fine — note the field names you found in a comment above the login function,
the way `didaxis/script.lua` does.

If you can't find a plain HTML form (e.g. the login is a JS-driven SPA posting to a JSON API,
or behind an OPAQUE-style/WebAuthn flow this host can't drive), that's a step-2 hard wall — stop
and report it rather than guessing field names that don't exist.

**Advance when:** you can point at a concrete `action` URL and field names, confirmed by reading
the actual fetched HTML (never guessed from memory of how the site "probably" works).

## 4. Step 3 — Try to log in

Write the `login(params)` function: a `fyde.http.post_form` to the action URL found in step 2,
with the field names found there mapped to `params.username`/`params.password` (or whatever the
site's own field names are — keep `params`'s keys matching `secret.json`'s conventional
`username`/`password` unless the site's own terminology strongly suggests otherwise, as `impots`
does with `fiscal-number`).

Write an `is_logged_in(html)` check (pattern-match on a known logged-in marker vs. a login-page
marker — see `didaxis/script.lua`'s version) and use it right after the login POST to confirm it
actually worked, not just that the POST returned 200 (a 200 with the login form still in the body
means the credentials were rejected or the field names are wrong).

If the login needs an MFA/OTP step, wire `fyde.input.ask` in for it, but don't try to drive it
through this unattended loop — tell the user once you reach this point so they can supply it
interactively for a one-off manual verification.

**Advance when:** the report shows the post-login page passing `is_logged_in`, confirmed against
the real HTTP response, not assumed from a 200 status alone.

## 5. Step 4 — Find the documents

Once logged in, use `fyde.html.select` against the authenticated page(s) to locate the
documents section(s) — a dashboard link, a dedicated "documents"/"bills"/"payslips" page per
`didaxis/script.lua`'s `SECTIONS` pattern. Extract the list of document rows/links and log how
many were found per section (`fyde.log.info`) without downloading yet — confirm the count and
that the extracted link `href`s look like real document URLs (PDF, a `download.php?id=`-shaped
endpoint, etc.), not e.g. the navigation chrome of the page itself.

**Advance when:** the report shows a plausible, non-zero document count (or a legitimately empty
account is explicitly logged as "0 documents found", not an empty list from a broken selector).

## 6. Step 5 — Download the documents

For each extracted document link, resolve it to an absolute URL, `fyde.http.download(url)` it,
check `status == 200` and that `content_type` isn't HTML (an HTML response usually means a
logged-out redirect or wrong URL, not a real file), then `fyde.save_document(filename, body)`
with a sanitized filename. Log a warning (not an error) for any single document that fails to
download, so one bad link doesn't abort the whole run.

**Advance when:** the report (and `data/documents/<name>/`) shows at least one real document
saved, with content-type/byte-size consistent with a real file, not an HTML error page saved
under a `.pdf` name.

## 7. Final check — clean run from scratch

Steps 2-6 build up state as they go (a restored session, cookies, previously-saved documents),
which can mask a step that only works *because* of leftovers from a previous run (e.g. step 3's
login looking fine because step 1/2's run already left a valid session cookie behind). Once all
five steps have passed once, verify the whole script actually works unattended, from nothing:

```sh
rm -rf data/documents/<name> data/session/<name>.json data/cookies/<name>.cookies.json
cargo run -- <name> --dev
```

Read the resulting report the same way as every other iteration. If it fails (a step that
previously passed now breaks without the leftover state, or a new error appears):

1. Diagnose from the report (same diagnosis framing as `fix-script`: selector drift, wrong
   logged-out marker, URL mismatch, a step that silently depended on state from a prior run
   rather than deriving it itself).
2. Patch `scripts/<name>/script.lua`.
3. Remove `data/documents/<name>`, `data/session/<name>.json`, and
   `data/cookies/<name>.cookies.json` again — a partial/stale session or cookie file from the
   failed attempt must not carry into the next try, or you'll be debugging against leftovers
   again.
4. Re-run `cargo run -- <name> --dev` and re-read the report.

Repeat until a clean-state run succeeds end to end with no error entry and at least one document
saved, or you hit the same stuck/needs-user conditions below.

## Stopping

- **Success**: the clean-from-scratch run in step 7 passes end to end in one run — no error
  entry, every section logged a document count, at least one document saved and
  content-type-checked. Report what the script does and where it still might be fragile (guessed
  selectors not visible in the test account, etc.), and stop.
- **Stuck on a given step**: the same failure survives a genuinely different hypothesis at that
  step (per `fix-script`'s diagnosis framing — selector drift, wrong URL, logged-out marker,
  bot-detection, no JS engine). Say plainly which step is blocked and why, rather than guessing
  further at the same step indefinitely.
- **Needs the user**: missing `secret.json` fields, an MFA/question prompt, or any page you need
  to see authenticated that you have no way to fetch yourself.

Never commit or push as part of this loop unless asked — leave the new script as working-tree
changes (plus the `secret.json.example` addition) for the user to review.
