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
cargo run -- status-table            # regenerate the status table below from the manifests
```

Downloaded documents are written under `--documents-dir` (default `data/documents/`,
gitignored). Cookies and session data persist across runs as one JSON file per scraper under
`--storage` (default `data/`, in its `cookies/` and `session/` subdirectories, gitignored), and
the sdk writes each run's debug report under `--storage`'s `reports/` subdirectory.

Progress (`fyde.progress.step`/`.update`) is printed to the terminal as it happens; a script
that calls `fyde.input.ask` (e.g. for an MFA code) prints the question and blocks on a line of
stdin.

See `CLAUDE.md` for the full architecture.

## Scrapers

`scrapers/` holds one scraper per site (login flow, success/failure signals, document
listing), all following the shared conventions below; the tables below list them.

### Shared conventions

- **Session first.** Every scraper first checks whether the restored session (cookies, or a
  token kept in `fyde.session`) is still valid and skips the login if so, logging
  `ALREADY_LOGGED_IN`.
- **Login errors.** A rejected username/password always fails the run with exactly
  `INVALID_CREDENTIALS`; a rejected, expired or unanswered one-time code / MFA step with exactly
  `MFA_FAILED` (both raised with `error(code, 0)`, so the message carries nothing else). Any other
  failure (captcha, vendor down, site changed) is a free-form error.
- **Markers.** `LOGIN_PAGE_FOUND` is logged once the login form/endpoint has been recognised.
- **Document metadata.** Every `fyde.save_document` call passes a `type` (what kind of paper
  it is, never the sector: `invoice`/`receipt`/`statement`/`reimbursement_statement`/`payslip`/`contract`/
  `insurance_certificate`/`insurance_card`/`rights_certificate`/`proof_of_residence`/`rib`/
  `tax_notice`/`tax_return`/`tax_certificate`/`employment_certificate`/`fee_summary`/`booking`/
  `medical_document`/`other`) and the
  `category`/`subcategory` the document is about, set once per scraper and overridden per
  document where needed (a bank's IFU is `taxes`/`tax_certificates`). The tree (a `subcategory`
  alone implies its category):

  | category | subcategories |
  |---|---|
  | `housing` | `energy`, `water`, `internet`, `home_insurance`, `home_services` |
  | `telecom` | `mobile` |
  | `money` | `banking`, `savings`, `gaming` |
  | `taxes` | `income_tax`, `tax_certificates` |
  | `health` | `health_insurance`, `complementary_health`, `care` |
  | `work` | `payslips`, `employment`, `household_employer` |
  | `family` | `benefits`, `childcare_school` |
  | `transport` | `train`, `flight`, `road`, `ride`, `travel` |
  | `shopping` | `online`, `pets`, `groceries`, `food_delivery` |
  | `subscriptions` | `media`, `cloud_software` |
  | `donations` | |
- **Shared code.** The Lua sandbox has no `require`, so the generic helpers (error contract,
  string/URL utilities, form submission, PDF download and browser polling) ship with the sdk as `fyde.helpers`
  (`../sdk/src/domains/scrapers/host/helpers.lua`); each script aliases the ones it uses
  (`local helpers = fyde.helpers` / `local fail = helpers.fail`).
- **Plain HTTP vs browser.** Sites that can be scraped with plain requests use `fyde.http`;
  sites that need to be driven in a real webview, or whose login needs a captcha or JS, use
  `fyde.browser`. Two host limitations come up repeatedly and are
  noted per scraper: `fyde.http` can't read a cookie's value (so tokens kept in
  cookies/localStorage are out of reach), and it only downloads with GET (POST answers are read as
  text, so binary PDFs served by POST are requested with GET instead, unconfirmed). Cookies set by
  `fyde.browser` only reach `fyde.http` on the next run.

### Status

Apart from the scrapers whose `state` is `verified` or `broken`, none of the scrapers has been
run against the real sites yet: there were no HAR captures
and no credentials, and the environment they were written in had no network access to the
sites. They were checked with luacheck and by loading each one in a sandboxed Lua 5.4 VM with a
mocked `fyde` table (catching syntax errors and early runtime errors), nothing more. The tests
that can be run without credentials - "is the login page there" and "is a wrong
username/password reported as `INVALID_CREDENTIALS`" - are automated by `tests/login_smoke.sh`;
its results fill each manifest's `login_page_found`/`invalid_credentials_detected` (last run on 2026-10-09 against every scraper,
fresh storage, made-up credentials).

Each scraper's status lives in the `status` object of its `scrapers/<name>/manifest.json`; print
it with `cargo run -- status <name>...` (every scraper when no name is given). `state` is one of
`verified` (login and documents both passed a run against the real site with real credentials),
`broken` (that run failed against the live site), `blocked` (a host limitation stops the
documents, or the login, even if the site behaves as expected) or `wip`.
`last_updated` is the date (`YYYY-MM-DD`) any field of `status` last changed - update it with
every manual edit to `status`; `tests/login_smoke.sh` bumps it whenever it changes a result.
`login_page_found` and `invalid_credentials_detected` come from the smoke test above, `login_ok`
and `documents_fetched` from runs with real credentials (on 2026-10-09 unless `notes` says
otherwise); each is `passed`, `failed`, `not_tested` or `not_applicable` (a passwordless login,
where a wrong login can only end in `MFA_FAILED`). When a scraper fails the smoke test, `notes`
gives the reason after "Smoke:".

`antibot_name` names the bot protection(s) found on the pages the scraper talks to (e.g.
`"DataDome"`, `"Akamai Bot Manager, reCAPTCHA"`), `null` when none, and `antibot_status` says
whether it gets in the way: `absent` (none found), `present` (there, but doesn't stop the
scraper), `blocking` (stops it: a 403/captcha the scraper can't get past) or `failed` (couldn't
be checked: site unreachable). Both were filled on 2026-10-11 from each script's own findings
and a probe of every host it talks to for antibot fingerprints (DataDome/Akamai/Imperva/
PerimeterX/Reblaze/AWS WAF cookies and headers, Cloudflare challenges, F5's `/TSPD/` bot
defense, captcha widgets). A bare WAF cookie (F5's `TS01…`) doesn't count; a client-rendered
login page may still hide a captcha the probe couldn't see.

### Status table

Generated from every scraper's `manifest.json` `status` by `cargo run -- status-table`; re-run it
after changing a status instead of editing the table by hand.

Legend: state ✅ verified, ❌ broken, 🚫 blocked, 🚧 wip; checks ✅ passed, ❌ failed, ❔ not
tested, ➖ not applicable; antibot ✅ absent, ⚠️ present, ⛔ blocking, ❔ couldn't be checked.

<!-- status-table:start -->
| Scraper | State | Login page found | Login KO detected | Login OK | Fetching OK | Antibot | Last updated |
|---|---|---|---|---|---|---|---|
| [`alan`](scrapers/alan/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`amazon`](scrapers/amazon/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ AWS WAF, Akamai Bot Manager, Arkose Labs captcha | 2026-10-11 |
| [`ameli`](scrapers/ameli/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ F5 BIG-IP ASM | 2026-10-11 |
| [`aprr`](scrapers/aprr/manifest.json) | 🚧 wip | ✅ | ➖ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`ascoresante`](scrapers/ascoresante/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`auchandrive`](scrapers/auchandrive/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ DataDome, reCAPTCHA v3 | 2026-10-11 |
| [`autolib`](scrapers/autolib/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ❔ | 2026-10-11 |
| [`bipandgo`](scrapers/bipandgo/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA v2 | 2026-10-11 |
| [`bitiba`](scrapers/bitiba/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`boulanger`](scrapers/boulanger/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Akamai Bot Manager | 2026-10-11 |
| [`boursobank`](scrapers/boursobank/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ in-house (__brs_mit cookie) | 2026-10-11 |
| [`bouyguesbox`](scrapers/bouyguesbox/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Akamai Bot Manager | 2026-10-11 |
| [`bouyguestelecom`](scrapers/bouyguestelecom/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ Akamai Bot Manager | 2026-10-11 |
| [`caf`](scrapers/caf/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ Reblaze | 2026-10-11 |
| [`cdiscount`](scrapers/cdiscount/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Cloudflare | 2026-10-11 |
| [`cesml`](scrapers/cesml/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`cesu`](scrapers/cesu/manifest.json) | ❌ broken | ❌ | ❌ | ✅ | ❌ | ⚠️ F5 BIG-IP ASM | 2026-10-11 |
| [`cultura`](scrapers/cultura/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`darty`](scrapers/darty/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⛔ DataDome, Akamai Bot Manager | 2026-10-11 |
| [`deliveroo`](scrapers/deliveroo/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ PerimeterX, Cloudflare | 2026-10-11 |
| [`didaxis`](scrapers/didaxis/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-11 |
| [`digiposte`](scrapers/digiposte/manifest.json) | 🚫 blocked | ✅ | ✅ | ❔ | ❔ | ⚠️ hCaptcha | 2026-10-11 |
| [`directenergie`](scrapers/directenergie/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`doctolib`](scrapers/doctolib/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Cloudflare | 2026-10-11 |
| [`eaudubassinrennais`](scrapers/eaudubassinrennais/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-11 |
| [`eaudugrandlyon`](scrapers/eaudugrandlyon/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`edf`](scrapers/edf/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Akamai Bot Manager | 2026-10-11 |
| [`ekwateur`](scrapers/ekwateur/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Cloudflare Turnstile | 2026-10-11 |
| [`electricitestrasbourg`](scrapers/electricitestrasbourg/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`enercoop`](scrapers/enercoop/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`engie`](scrapers/engie/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`eovimcdparticuliers`](scrapers/eovimcdparticuliers/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`eticket`](scrapers/eticket/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`facebook`](scrapers/facebook/manifest.json) | 🚫 blocked | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`fnac`](scrapers/fnac/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⛔ DataDome, Akamai Bot Manager | 2026-10-11 |
| [`francetravail`](scrapers/francetravail/manifest.json) | 🚧 wip | ✅ | ✅ | ❌ | ❔ | ✅ | 2026-10-11 |
| [`free`](scrapers/free/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`freemobile`](scrapers/freemobile/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`gazdebordeaux`](scrapers/gazdebordeaux/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`geg`](scrapers/geg/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`generali`](scrapers/generali/manifest.json) | ❌ broken | ❌ | ❔ | ❔ | ❔ | ⚠️ Ilex Sign&go (OIDC) + SMS OTP | 2026-10-14 |
| [`github`](scrapers/github/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`glisshop`](scrapers/glisshop/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`harmonie`](scrapers/harmonie/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`humanis`](scrapers/humanis/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Imperva | 2026-10-11 |
| [`impots`](scrapers/impots/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ Reblaze | 2026-10-11 |
| [`lamutuellegenerale`](scrapers/lamutuellegenerale/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⚠️ Imperva | 2026-10-11 |
| [`ldlc`](scrapers/ldlc/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA | 2026-10-11 |
| [`leclercdrive`](scrapers/leclercdrive/manifest.json) | 🚧 wip | ✅ | ❌ | ❔ | ❔ | ⛔ DataDome | 2026-10-11 |
| [`lucca`](scrapers/lucca/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`luko`](scrapers/luko/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ❔ | 2026-10-11 |
| [`macif`](scrapers/macif/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⛔ DataDome | 2026-10-11 |
| [`maif`](scrapers/maif/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`malakoffmederic`](scrapers/malakoffmederic/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Imperva | 2026-10-11 |
| [`malentille`](scrapers/malentille/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`materielnet`](scrapers/materielnet/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`mediapart`](scrapers/mediapart/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`mercermasante`](scrapers/mercermasante/manifest.json) | ✅ verified | ✅ | ✅ | ✅ | ✅ | ⚠️ Cloudflare Turnstile | 2026-10-11 |
| [`mgen`](scrapers/mgen/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`mint-energie`](scrapers/mint-energie/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`misterauto`](scrapers/misterauto/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ DataDome | 2026-10-11 |
| [`msf`](scrapers/msf/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`n26`](scrapers/n26/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`numericable`](scrapers/numericable/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`o2`](scrapers/o2/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`opngo`](scrapers/opngo/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`orange`](scrapers/orange/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ in-house captcha | 2026-10-11 |
| [`ovh`](scrapers/ovh/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`pajemploi`](scrapers/pajemploi/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ F5 BIG-IP ASM | 2026-10-11 |
| [`payfit`](scrapers/payfit/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`planeteoui`](scrapers/planeteoui/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`prixtel`](scrapers/prixtel/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ AWS WAF, reCAPTCHA | 2026-10-11 |
| [`probikeshop`](scrapers/probikeshop/manifest.json) | 🚧 wip | ✅ | ➖ | ❔ | ❔ | ⚠️ Cloudflare | 2026-10-11 |
| [`productboard`](scrapers/productboard/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Cloudflare | 2026-10-11 |
| [`red`](scrapers/red/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA | 2026-10-11 |
| [`saur`](scrapers/saur/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA v3 | 2026-10-11 |
| [`scaleway`](scrapers/scaleway/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA | 2026-10-11 |
| [`sfr`](scrapers/sfr/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA | 2026-10-11 |
| [`sfrbox`](scrapers/sfrbox/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ reCAPTCHA | 2026-10-11 |
| [`silae`](scrapers/silae/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`sncf`](scrapers/sncf/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⛔ DataDome | 2026-10-11 |
| [`sosh`](scrapers/sosh/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ in-house captcha | 2026-10-11 |
| [`spartoo`](scrapers/spartoo/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`stickersdiscount`](scrapers/stickersdiscount/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`tagandpass`](scrapers/tagandpass/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ❔ | 2026-10-11 |
| [`thomann`](scrapers/thomann/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ Cloudflare, Cloudflare Turnstile | 2026-10-11 |
| [`trainline`](scrapers/trainline/manifest.json) | 🚧 wip | ✅ | ❌ | ❔ | ❔ | ⚠️ DataDome | 2026-10-11 |
| [`uber`](scrapers/uber/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⚠️ Cloudflare, reCAPTCHA | 2026-10-11 |
| [`venteprivee`](scrapers/venteprivee/manifest.json) | 🚧 wip | ✅ | ❌ | ❔ | ❔ | ⚠️ Cloudflare | 2026-10-11 |
| [`veoliaeau`](scrapers/veoliaeau/manifest.json) | 🚧 wip | ❌ | ❌ | ❔ | ❔ | ⚠️ Friendly Captcha | 2026-10-11 |
| [`viasante`](scrapers/viasante/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ⚠️ F5 BIG-IP ASM | 2026-10-11 |
| [`vinciautoroute`](scrapers/vinciautoroute/manifest.json) | 🚫 blocked | ✅ | ✅ | ❔ | ❔ | ⚠️ Friendly Captcha | 2026-10-11 |
| [`wanimo`](scrapers/wanimo/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
| [`zooplus`](scrapers/zooplus/manifest.json) | 🚧 wip | ✅ | ✅ | ❔ | ❔ | ✅ | 2026-10-11 |
<!-- status-table:end -->

### Running the login smoke test

```sh
tests/login_smoke.sh                # every scraper
tests/login_smoke.sh edf free sncf  # some of them
```

Each scraper is run once with made-up credentials (built from its `manifest.json` parameter
placeholders), a fresh storage directory and stdin closed; the script writes both results
(`passed`/`failed`) into the `login_page_found`/`invalid_credentials_detected` fields of each
scraper's `manifest.json` `status` (leaving a passwordless scraper's `not_applicable` alone),
prints one summary line per scraper and keeps the full logs under `data/smoke/`. It doesn't touch
`notes`: update its "Smoke:" reason by hand. Browser-driven scrapers need a display (or Xvfb).
