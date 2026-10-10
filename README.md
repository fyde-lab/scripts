# fyde-scripts

The canonical home for the Lua scraper scripts run by `fyde-sdk`'s `scrapers` domain
(`scripts/scrapers/didaxis/script.lua`, `scripts/scrapers/impots/script.lua`), plus a standalone CLI runner — ported from
`demo-rust-fyde` — that drives them through `fyde-sdk`'s `ScrapersService::run` directly,
without a full `Client`/server connection.

## Usage

```sh
cp secret.json.example secret.json  # then fill in real credentials, never commit it
cargo run -- run didaxis             # runs scrapers/didaxis/script.lua
cargo run -- run didaxis impots      # runs both, in order
cargo run -- run --dev --visible cesu  # dump HTTP bodies in the report, show the browser window
cargo run -- check                   # load every script without running it (no network)
```

Downloaded documents are written under `--documents-dir` (default `data/documents/`,
gitignored). Cookies and session data persist across runs as one JSON file per scraper under
`--storage` (default `data/`, in its `cookies/` and `session/` subdirectories, gitignored), and
the sdk writes each run's debug report under `--storage`'s `reports/` subdirectory.

Progress (`fyde.progress.step`/`.update`) is printed to the terminal as it happens; a script
that calls `fyde.input.ask` (e.g. for an MFA code) prints the question and blocks on a line of
stdin.

See `CLAUDE.md` for the full architecture.

## Scrapers ported from github.com/konnectors

Every repository of the [konnectors](https://github.com/orgs/konnectors/repositories) GitHub
organization (Cozy Cloud's connectors) has a scraper here, ported from the konnector's own logic
(login flow, success/failure signals, document listing) - 110 scrapers, 7 of which already
existed in this repo and were only aligned on the shared conventions below. The organization's
repository list API wasn't reachable when this was done, so the repositories were found by
probing names. The status table below also lists the scrapers that aren't konnector ports
(`didaxis`, `mercermasante`, no konnectors repo).

### Shared conventions

- **Session first.** Every scraper first checks whether the restored session (cookies, or a
  token kept in `fyde.session`) is still valid and skips the login if so, logging
  `ALREADY_LOGGED_IN`.
- **Login errors.** A rejected username/password always fails the run with exactly
  `INVALID_CREDENTIALS`; a rejected, expired or unanswered one-time code / MFA step with exactly
  `MFA_FAILED` (both raised with `error(code, 0)`, so the message carries nothing else). Any other
  failure (captcha, vendor down, site changed) is a free-form error. Where the konnector raised
  Cozy's `LOGIN_FAILED`, the port raises `INVALID_CREDENTIALS`.
- **Markers.** `LOGIN_PAGE_FOUND` is logged once the login form/endpoint has been recognised.
- **Shared code.** The Lua sandbox has no `require`, so each script inlines the same helper
  block (error contract, form submission, PDF download, browser polling, and - for sites that
  have no PDF to download, whose konnector generated one with pdfjs - a small text-only PDF
  writer).
- **Plain HTTP vs browser.** Konnectors built on `cozy-konnector-libs` requests are ported to
  `fyde.http`; cozy-clisk konnectors (which drove the real site in a webview), and sites whose
  login needs a captcha or JS, to `fyde.browser`. Two host limitations come up repeatedly and are
  noted per scraper: `fyde.http` can't read a cookie's value (so tokens a konnector read from
  cookies/localStorage are out of reach), and it only downloads with GET (POST answers are read as
  text, so binary PDFs served by POST are requested with GET instead, unconfirmed). Cookies set by
  `fyde.browser` only reach `fyde.http` on the next run.

### Status

Apart from the pre-existing scrapers (marked ²/¹ below), none of the ported scrapers has been
run against the real sites yet: there were no HAR captures
and no credentials, and the environment they were written in had no network access to the
sites. They were checked with luacheck and by loading each one in a sandboxed Lua 5.4 VM with a
mocked `fyde` table (catching syntax errors and early runtime errors), nothing more. The tests
that can be run without credentials - "is the login page there" and "is a wrong
username/password reported as `INVALID_CREDENTIALS`" - are automated by `tests/login_smoke.sh`;
its output rows fill the two test columns below (last run on 2026-10-09 against every scraper,
fresh storage, made-up credentials). When a scraper fails the smoke test, the Notes column gives the
reason after "Smoke:".

Legend: ✅ passed, ❌ failed, ⏳ not run yet. ¹ verified by earlier work on this repo, before the
error-contract change. ² run against the real site with real credentials (and the session
left in `data/`) on 2026-10-09. Status "Verified" means login and documents both passed that
run, "Broken" that it failed against the live site. Status "Blocked" means a host limitation stops the documents (or the
login) even if the site behaves as the konnector expected.

| Scraper | konnectors repo | Method | Status | Login page found | Invalid credentials detected | Login OK | Documents fetched | Notes |
|---|---|---|---|---|---|---|---|---|
| [`alan`](scrapers/alan/script.lua) | [alan](https://github.com/konnectors/alan) | browser | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Konnector never automated login (site checks isTrusted); documents page URL unconfirmed; Smoke: password field not found |
| [`amazon`](scrapers/amazon/script.lua) | [amazon](https://github.com/konnectors/amazon) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Captchas not solvable; invoices via popovers; Smoke: sign-in form not found |
| [`ameli`](scrapers/ameli/script.lua) | [cozy-konnector-ameli](https://github.com/konnectors/cozy-konnector-ameli) | browser | Verified | ✅ | ✅ | ✅² | ✅² | Attestation de droits per beneficiary (and "Toute la famille"), relevés mensuels (up to 27 months), payment statements (last 6 months); verified 2026-10-10. Emailed code on every fresh login, session lasts a few minutes; the WAF rejects logins ("The requested URL was rejected") after ~8 in 20 minutes |
| [`aprr`](scrapers/aprr/script.lua) | [aprr](https://github.com/konnectors/aprr) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: redirected to `mango-mobilitesbyaprr.com`, not in `allowed_domains` |
| [`ascoresante`](scrapers/ascoresante/script.lua) | [ascoresante](https://github.com/konnectors/ascoresante) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`auchandrive`](scrapers/auchandrive/script.lua) | [auchandrive](https://github.com/konnectors/auchandrive) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | No PDFs on the site: text PDF generated per order; site moved to auchan.fr; Smoke: redirected to `auchan.fr`, not in `allowed_domains` |
| [`autolib`](scrapers/autolib/script.lua) | [autolib](https://github.com/konnectors/autolib) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Service closed in 2018; Smoke: host unreachable |
| [`bipandgo`](scrapers/bipandgo/script.lua) | [bipandgo](https://github.com/konnectors/bipandgo) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | reCAPTCHA on login (konnector used a paid solver) - may block the webview |
| [`bitiba`](scrapers/bitiba/script.lua) | [bitiba](https://github.com/konnectors/bitiba) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`blablacar`](scrapers/blablacar/script.lua) | [blablacar](https://github.com/konnectors/blablacar) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | No receipts on the site: text PDF per ride; site is now a SPA; Smoke: login page answers HTTP 403 |
| [`bookingdotcom`](scrapers/bookingdotcom/script.lua) | [bookingdotcom](https://github.com/konnectors/bookingdotcom) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Login moved to account.booking.com since; text PDF per reservation; Smoke: login form not found |
| [`boulanger`](scrapers/boulanger/script.lua) | [boulanger](https://github.com/konnectors/boulanger) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`boursobank`](scrapers/boursobank/script.lua) | [boursorama](https://github.com/konnectors/boursorama) | HTTP | Verified | ✅ | ✅ | ✅² | ✅² | Statements, other banks' documents, IFU, RIBs |
| [`bouyguesbox`](scrapers/bouyguesbox/script.lua) | [cozy-konnector-bouyguesbox](https://github.com/konnectors/cozy-konnector-bouyguesbox) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`bouyguestelecom`](scrapers/bouyguestelecom/script.lua) | [cozy-konnector-bouyguestelecom](https://github.com/konnectors/cozy-konnector-bouyguestelecom) | browser | Verified | ✅ | ✅ | ✅² | ✅² | Mobile and Bbox invoices; SMS confirmation code on login, session reused on the next run; one old (2021) invoice isn't a PDF and is skipped |
| [`caf`](scrapers/caf/script.lua) | [caf](https://github.com/konnectors/caf) | HTTP | Verified | ✅ | ✅ | ✅² | ✅² | Attestations (paiements, mns, qf, rms); remembered device, no one-time code asked |
| [`cdiscount`](scrapers/cdiscount/script.lua) | [cdiscount](https://github.com/konnectors/cdiscount) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Order selection relies on the select change event; Smoke: login form not found |
| [`cesml`](scrapers/cesml/script.lua) | [cesml](https://github.com/konnectors/cesml) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: host timed out |
| [`cesu`](scrapers/cesu/script.lua) | [cozy-konnector-cesu](https://github.com/konnectors/cozy-konnector-cesu) | browser | Broken | ❌ | ❌ | ✅² | ❌² | Session reused, but the "Mes déclarations" / "Mon avantage fiscal" menu links are no longer found: no documents; Smoke: reported `ALREADY_LOGGED_IN` on a fresh `--storage` because the session lives in the webview's localStorage, which the sdk keeps in one profile shared by every run and scraper (`~/.local/share/fyde-scripts`) instead of under `--storage` |
| [`cic`](scrapers/cic/script.lua) | [cic](https://github.com/konnectors/cic) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Excel export not readable: asks a CSV export (unconfirmed) saved as text PDF; app-push SCA confirmed by the user |
| [`cultura`](scrapers/cultura/script.lua) | [cultura](https://github.com/konnectors/cultura) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`darty`](scrapers/darty/script.lua) | [darty](https://github.com/konnectors/darty) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login form not found (HTTP 403) |
| [`deezer`](scrapers/deezer/script.lua) | [deezer](https://github.com/konnectors/deezer) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | reCAPTCHA on login; receipts are HTML pages -> text PDFs |
| [`deliveroo`](scrapers/deliveroo/script.lua) | [deliveroo](https://github.com/konnectors/deliveroo) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`didaxis`](scrapers/didaxis/script.lua) | — | HTTP | Verified | ✅ | ✅ | ✅² | ✅² | Payslips, employment contracts, bills, personal documents |
| [`digiposte`](scrapers/digiposte/script.lua) | [cozy-konnector-digiposte](https://github.com/konnectors/cozy-konnector-digiposte) | browser + HTTP | Blocked | ✅ | ✅ | ⏳ not tested | ⏳ not tested | **Blocked**: API token needs the XSRF cookie value (not readable); hCaptcha on login |
| [`directenergie`](scrapers/directenergie/script.lua) | [cozy-konnector-directenergie](https://github.com/konnectors/cozy-konnector-directenergie) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`doctolib`](scrapers/doctolib/script.lua) | [doctolib](https://github.com/konnectors/doctolib) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | 2FA field names unconfirmed |
| [`easyjet`](scrapers/easyjet/script.lua) | [easyjet](https://github.com/konnectors/easyjet) | HTTP | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Site rebuilt since; text PDF per booking; Smoke: login answers HTTP 403 |
| [`eaudubassinrennais`](scrapers/eaudubassinrennais/script.lua) | [eaudubassinrennais](https://github.com/konnectors/eaudubassinrennais) | HTTP | Verified | ✅ | ✅ | ✅² | ✅² | Bills |
| [`eaudugrandlyon`](scrapers/eaudugrandlyon/script.lua) | [eaudugrandlyon](https://github.com/konnectors/eaudugrandlyon) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`edf`](scrapers/edf/script.lua) | [edf](https://github.com/konnectors/edf) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Bot protection may block the webview |
| [`ekwateur`](scrapers/ekwateur/script.lua) | [ekwateur](https://github.com/konnectors/ekwateur) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`electricitestrasbourg`](scrapers/electricitestrasbourg/script.lua) | [electricitestrasbourg](https://github.com/konnectors/electricitestrasbourg) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | PDF fetched with GET instead of the konnector's POST (unconfirmed); Smoke: host unreachable |
| [`enercoop`](scrapers/enercoop/script.lua) | [cozy-konnector-enercoop](https://github.com/konnectors/cozy-konnector-enercoop) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`engie`](scrapers/engie/script.lua) | [engie](https://github.com/konnectors/engie) | browser | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: submit button not found |
| [`eovimcdparticuliers`](scrapers/eovimcdparticuliers/script.lua) | [eovimcdparticuliers](https://github.com/konnectors/eovimcdparticuliers) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: host unreachable |
| [`eticket`](scrapers/eticket/script.lua) | [eticket](https://github.com/konnectors/eticket) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Firebase websocket replaced by the Firebase REST API (unconfirmed) |
| [`facebook`](scrapers/facebook/script.lua) | [cozy-konnector-facebook](https://github.com/konnectors/cozy-konnector-facebook) | HTTP | Blocked | ✅ | ✅ | ⏳ not tested | ⏳ not tested | **Blocked**: OAuth token instead of password; photos are JPEG (save_document is PDF-only) |
| [`fnac`](scrapers/fnac/script.lua) | [fnac](https://github.com/konnectors/fnac) | browser + HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Browser login; documents come on the next run (cookies reach fyde.http then); Smoke: login form not found (Datadome?) |
| [`fortuneo`](scrapers/fortuneo/script.lua) | [fortuneo](https://github.com/konnectors/fortuneo) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | CSV-in-ZIP export not readable: operations table saved as text PDF; Smoke: login form not found |
| [`francetravail`](scrapers/francetravail/script.lua) | [poleemploi](https://github.com/konnectors/poleemploi) | browser | Broken | ❌ | ❌ | ❌² | ⏳ not tested | Timed out waiting for the browser on the `#identifiant` field of candidat.francetravail.fr/espacepersonnel/; Smoke: timed out waiting for the browser |
| [`free`](scrapers/free/script.lua) | [cozy-konnector-free](https://github.com/konnectors/cozy-konnector-free) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`freemobile`](scrapers/freemobile/script.lua) | [cozy-konnector-free-mobile](https://github.com/konnectors/cozy-konnector-free-mobile) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`gazdebordeaux`](scrapers/gazdebordeaux/script.lua) | [gazdebordeaux](https://github.com/konnectors/gazdebordeaux) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`geg`](scrapers/geg/script.lua) | [geg](https://github.com/konnectors/geg) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | PDF fetched with GET instead of POST (unconfirmed); Smoke: host unreachable |
| [`generali`](scrapers/generali/script.lua) | [cozy-konnector-generali](https://github.com/konnectors/cozy-konnector-generali) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`github`](scrapers/github/script.lua) | [github](https://github.com/konnectors/github) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`glisshop`](scrapers/glisshop/script.lua) | [glisshop](https://github.com/konnectors/glisshop) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`harmonie`](scrapers/harmonie/script.lua) | [cozy-konnector-harmonie](https://github.com/konnectors/cozy-konnector-harmonie) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | API token unreachable, download controls clicked instead |
| [`humanis`](scrapers/humanis/script.lua) | [humanis](https://github.com/konnectors/humanis) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Merged into Malakoff Humanis; site may be gone; Smoke: redirected to `malakoffhumanis.com`, not in `allowed_domains` |
| [`impots`](scrapers/impots/script.lua) | [impots](https://github.com/konnectors/impots) | HTTP | Verified | ✅ | ✅ | ✅² | ✅² | Tax notices (income, property), online tax returns, declarative situation notices, tax reminders |
| [`inulogic`](scrapers/inulogic/script.lua) | [inulogic](https://github.com/konnectors/inulogic) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: host unreachable |
| [`justeat`](scrapers/justeat/script.lua) | [justeat](https://github.com/konnectors/justeat) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`lamutuellegenerale`](scrapers/lamutuellegenerale/script.lua) | [lamutuellegenerale](https://github.com/konnectors/lamutuellegenerale) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login form not found |
| [`ldlc`](scrapers/ldlc/script.lua) | [ldlc](https://github.com/konnectors/ldlc) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | reCAPTCHA on login; documents come on the next run |
| [`leclercdrive`](scrapers/leclercdrive/script.lua) | [leclercdrive](https://github.com/konnectors/leclercdrive) | HTTP | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Datadome captcha not solvable; Smoke: Datadome captcha |
| [`lucca`](scrapers/lucca/script.lua) | [lucca](https://github.com/konnectors/lucca) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Payslips behind a 6-digit code reported as MFA_FAILED |
| [`luko`](scrapers/luko/script.lua) | [luko](https://github.com/konnectors/luko) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Company stopped in 2023; API likely gone; Smoke: host unreachable |
| [`macif`](scrapers/macif/script.lua) | [macif](https://github.com/konnectors/macif) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login form not found |
| [`maif`](scrapers/maif/script.lua) | [cozy-konnector-maif](https://github.com/konnectors/cozy-konnector-maif) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | OAuth token instead of password; data saved as text PDF; konnector unmaintained since 2020; Smoke: host unreachable |
| [`malakoffmederic`](scrapers/malakoffmederic/script.lua) | [cozy-konnector-malakoffmederic](https://github.com/konnectors/cozy-konnector-malakoffmederic) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | DWR login driven through the browser; Smoke: login form not found |
| [`malentille`](scrapers/malentille/script.lua) | [malentille](https://github.com/konnectors/malentille) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`materielnet`](scrapers/materielnet/script.lua) | [cozy-konnector-materielnet](https://github.com/konnectors/cozy-konnector-materielnet) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`mediapart`](scrapers/mediapart/script.lua) | [mediapart](https://github.com/konnectors/mediapart) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`mercermasante`](scrapers/mercermasante/script.lua) | — | browser | Verified | ✅ | ✅ | ✅² | ✅² | Attestation de couverture, carte de tiers payant, reimbursement statements; SMS code on login, session reused on the next run |
| [`mgen`](scrapers/mgen/script.lua) | [cozy-konnector-mgen](https://github.com/konnectors/cozy-konnector-mgen) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Attestations (api.mgen.fr) not ported; Smoke: login form not found |
| [`mint-energie`](scrapers/mint-energie/script.lua) | [mint-energie](https://github.com/konnectors/mint-energie) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`misterauto`](scrapers/misterauto/script.lua) | [misterauto](https://github.com/konnectors/misterauto) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`mondediplo`](scrapers/mondediplo/script.lua) | [mondediplo](https://github.com/konnectors/mondediplo) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`monoprix`](scrapers/monoprix/script.lua) | [monoprix](https://github.com/konnectors/monoprix) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Upstream konnector never saved documents; order history saved as text PDF; Smoke: login form not found |
| [`msf`](scrapers/msf/script.lua) | [msf](https://github.com/konnectors/msf) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`n26`](scrapers/n26/script.lua) | [n26](https://github.com/konnectors/n26) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | App approval confirmed by the user through fyde.input.ask |
| [`nalo`](scrapers/nalo/script.lua) | [nalo](https://github.com/konnectors/nalo) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`nespresso`](scrapers/nespresso/script.lua) | [nespresso](https://github.com/konnectors/nespresso) | HTTP | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login answers HTTP 403 |
| [`net-entreprise-micro`](scrapers/net-entreprise-micro/script.lua) | [net-entreprise-micro](https://github.com/konnectors/net-entreprise-micro) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`netflix`](scrapers/netflix/script.lua) | [netflix](https://github.com/konnectors/netflix) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`numericable`](scrapers/numericable/script.lua) | [cozy-konnector-numericable](https://github.com/konnectors/cozy-konnector-numericable) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Merged into SFR; site may be gone |
| [`o2`](scrapers/o2/script.lua) | [o2](https://github.com/konnectors/o2) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`opngo`](scrapers/opngo/script.lua) | [opngo](https://github.com/konnectors/opngo) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | PDF fetched with GET instead of POST (unconfirmed); Smoke: redirected to `indigoneo.com`, not in `allowed_domains` |
| [`orange`](scrapers/orange/script.lua) | [cozy-konnector-orange](https://github.com/konnectors/cozy-konnector-orange) | browser | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: password step not shown |
| [`ovh`](scrapers/ovh/script.lua) | [ovh](https://github.com/konnectors/ovh) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | API credentials (appKey/appSecret/consumerKey), requests signed with SHA-1 |
| [`pajemploi`](scrapers/pajemploi/script.lua) | [cozy-konnector-pajemploi](https://github.com/konnectors/cozy-konnector-pajemploi) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | reCAPTCHA not solvable; payslips fetched with GET instead of POST (unconfirmed); Smoke: redirected to `urssaf.fr`, not in `allowed_domains` |
| [`payfit`](scrapers/payfit/script.lua) | [payfit](https://github.com/konnectors/payfit) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Payslips page URL unconfirmed; API token unreachable; Smoke: login form not found |
| [`planeteoui`](scrapers/planeteoui/script.lua) | [planeteoui](https://github.com/konnectors/planeteoui) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Brand discontinued; site may be gone; Smoke: redirected to `mint-energie.com`, not in `allowed_domains` |
| [`prixtel`](scrapers/prixtel/script.lua) | [prixtel](https://github.com/konnectors/prixtel) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | reCAPTCHA on login; API token unreachable, download buttons clicked instead |
| [`probikeshop`](scrapers/probikeshop/script.lua) | [probikeshop](https://github.com/konnectors/probikeshop) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: redirected to `shop.app`, not in `allowed_domains` |
| [`productboard`](scrapers/productboard/script.lua) | [productboard](https://github.com/konnectors/productboard) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Workspace subdomain is a parameter (konnector hardcoded cozycloud); Smoke: login form not found |
| [`red`](scrapers/red/script.lua) | [red](https://github.com/konnectors/red) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`saur`](scrapers/saur/script.lua) | [saur](https://github.com/konnectors/saur) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: HTTP 500 |
| [`scaleway`](scrapers/scaleway/script.lua) | [scaleway](https://github.com/konnectors/scaleway) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | reCAPTCHA expected by the API; session JWT not deleted (no DELETE in fyde.http) |
| [`sfr`](scrapers/sfr/script.lua) | [sfr](https://github.com/konnectors/sfr) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`sfrbox`](scrapers/sfrbox/script.lua) | [cozy-konnector-sfrbox](https://github.com/konnectors/cozy-konnector-sfrbox) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`showroomprive`](scrapers/showroomprive/script.lua) | [showroomprive](https://github.com/konnectors/showroomprive) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`silae`](scrapers/silae/script.lua) | [silae](https://github.com/konnectors/silae) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | SOAP replaced by the ASMX HTTP-POST binding (unconfirmed); Smoke: host unreachable |
| [`sncf`](scrapers/sncf/script.lua) | [cozy-konnector-sncf](https://github.com/konnectors/cozy-konnector-sncf) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login form not found |
| [`sosh`](scrapers/sosh/script.lua) | [cozy-konnector-sosh](https://github.com/konnectors/cozy-konnector-sosh) | browser | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: password step not shown |
| [`spartoo`](scrapers/spartoo/script.lua) | [spartoo](https://github.com/konnectors/spartoo) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`stickersdiscount`](scrapers/stickersdiscount/script.lua) | [stickersdiscount](https://github.com/konnectors/stickersdiscount) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`tagandpass`](scrapers/tagandpass/script.lua) | [tagandpass](https://github.com/konnectors/tagandpass) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: redirected to `reso-m.fr`, not in `allowed_domains` |
| [`theoldreader`](scrapers/theoldreader/script.lua) | [cozy-konnector-theoldreader](https://github.com/konnectors/cozy-konnector-theoldreader) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested |  |
| [`thomann`](scrapers/thomann/script.lua) | [thomann](https://github.com/konnectors/thomann) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: redirected to `thomann.fr`, not in `allowed_domains` |
| [`trainline`](scrapers/trainline/script.lua) | [cozy-konnector-trainline](https://github.com/konnectors/cozy-konnector-trainline) | HTTP | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | API v5.1 likely replaced since; Smoke: sign-in answers HTTP 404 |
| [`uber`](scrapers/uber/script.lua) | [cozy-konnector-uber](https://github.com/konnectors/cozy-konnector-uber) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | 2017-era flow, almost certainly outdated; Smoke: login form not found |
| [`unibet`](scrapers/unibet/script.lua) | [unibet](https://github.com/konnectors/unibet) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login answers HTTP 404 |
| [`venteprivee`](scrapers/venteprivee/script.lua) | [venteprivee](https://github.com/konnectors/venteprivee) | HTTP | WIP | ✅ | ❌ | ⏳ not tested | ⏳ not tested | Veepee login now JS + captcha; Smoke: made-up credentials accepted: run ends OK with no documents |
| [`veoliaeau`](scrapers/veoliaeau/script.lua) | [veoliaeau](https://github.com/konnectors/veoliaeau) | browser | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: login form not found |
| [`viasante`](scrapers/viasante/script.lua) | [viasante](https://github.com/konnectors/viasante) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: host unreachable |
| [`vinciautoroute`](scrapers/vinciautoroute/script.lua) | [vinciautoroute](https://github.com/konnectors/vinciautoroute) | HTTP | WIP | ❌ | ❌ | ⏳ not tested | ⏳ not tested | Smoke: redirected to `ulys.com`, not in `allowed_domains` |
| [`wanimo`](scrapers/wanimo/script.lua) | [wanimo](https://github.com/konnectors/wanimo) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |
| [`zalando`](scrapers/zalando/script.lua) | [zalando](https://github.com/konnectors/zalando) | browser | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Bot protection may block the webview |
| [`zooplus`](scrapers/zooplus/script.lua) | [zooplus](https://github.com/konnectors/zooplus) | HTTP | WIP | ✅ | ✅ | ⏳ not tested | ⏳ not tested | Site is now a Next.js app: login rebuilt on its JSON API (`/fr/api/auth/*`); SMS code step, order list and receipts unverified |

### Running the login smoke test

```sh
tests/login_smoke.sh                # every scraper
tests/login_smoke.sh edf free sncf  # some of them
```

Each scraper is run once with made-up credentials (built from its `settings.json` parameter
placeholders), a fresh storage directory and stdin closed; the script prints one markdown table
row per scraper (login page found / invalid credentials detected) and keeps the full logs under
`data/smoke/`. Browser-driven scrapers need a display (or Xvfb).
