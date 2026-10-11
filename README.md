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
probing names. The table below also lists the scrapers that aren't konnector ports
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

Apart from the scrapers whose `state` is `verified` or `broken`, none of the ported scrapers has been
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
documents, or the login, even if the site behaves as the konnector expected) or `wip`.
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

| Scraper | konnectors repo | Method |
|---|---|---|
| [`alan`](scrapers/alan/script.lua) | [alan](https://github.com/konnectors/alan) | browser |
| [`amazon`](scrapers/amazon/script.lua) | [amazon](https://github.com/konnectors/amazon) | browser |
| [`ameli`](scrapers/ameli/script.lua) | [cozy-konnector-ameli](https://github.com/konnectors/cozy-konnector-ameli) | browser |
| [`aprr`](scrapers/aprr/script.lua) | [aprr](https://github.com/konnectors/aprr) | HTTP |
| [`ascoresante`](scrapers/ascoresante/script.lua) | [ascoresante](https://github.com/konnectors/ascoresante) | HTTP |
| [`auchandrive`](scrapers/auchandrive/script.lua) | [auchandrive](https://github.com/konnectors/auchandrive) | HTTP |
| [`autolib`](scrapers/autolib/script.lua) | [autolib](https://github.com/konnectors/autolib) | HTTP |
| [`bipandgo`](scrapers/bipandgo/script.lua) | [bipandgo](https://github.com/konnectors/bipandgo) | browser |
| [`bitiba`](scrapers/bitiba/script.lua) | [bitiba](https://github.com/konnectors/bitiba) | HTTP |
| [`blablacar`](scrapers/blablacar/script.lua) | [blablacar](https://github.com/konnectors/blablacar) | HTTP |
| [`bookingdotcom`](scrapers/bookingdotcom/script.lua) | [bookingdotcom](https://github.com/konnectors/bookingdotcom) | HTTP |
| [`boulanger`](scrapers/boulanger/script.lua) | [boulanger](https://github.com/konnectors/boulanger) | HTTP |
| [`boursobank`](scrapers/boursobank/script.lua) | [boursorama](https://github.com/konnectors/boursorama) | HTTP |
| [`bouyguesbox`](scrapers/bouyguesbox/script.lua) | [cozy-konnector-bouyguesbox](https://github.com/konnectors/cozy-konnector-bouyguesbox) | HTTP |
| [`bouyguestelecom`](scrapers/bouyguestelecom/script.lua) | [cozy-konnector-bouyguestelecom](https://github.com/konnectors/cozy-konnector-bouyguestelecom) | browser |
| [`caf`](scrapers/caf/script.lua) | [caf](https://github.com/konnectors/caf) | HTTP |
| [`cdiscount`](scrapers/cdiscount/script.lua) | [cdiscount](https://github.com/konnectors/cdiscount) | browser |
| [`cesml`](scrapers/cesml/script.lua) | [cesml](https://github.com/konnectors/cesml) | HTTP |
| [`cesu`](scrapers/cesu/script.lua) | [cozy-konnector-cesu](https://github.com/konnectors/cozy-konnector-cesu) | browser |
| [`cic`](scrapers/cic/script.lua) | [cic](https://github.com/konnectors/cic) | HTTP |
| [`cultura`](scrapers/cultura/script.lua) | [cultura](https://github.com/konnectors/cultura) | HTTP |
| [`darty`](scrapers/darty/script.lua) | [darty](https://github.com/konnectors/darty) | HTTP |
| [`deezer`](scrapers/deezer/script.lua) | [deezer](https://github.com/konnectors/deezer) | browser |
| [`deliveroo`](scrapers/deliveroo/script.lua) | [deliveroo](https://github.com/konnectors/deliveroo) | HTTP |
| [`didaxis`](scrapers/didaxis/script.lua) | — | HTTP |
| [`digiposte`](scrapers/digiposte/script.lua) | [cozy-konnector-digiposte](https://github.com/konnectors/cozy-konnector-digiposte) | browser + HTTP |
| [`directenergie`](scrapers/directenergie/script.lua) | [cozy-konnector-directenergie](https://github.com/konnectors/cozy-konnector-directenergie) | browser |
| [`doctolib`](scrapers/doctolib/script.lua) | [doctolib](https://github.com/konnectors/doctolib) | HTTP |
| [`easyjet`](scrapers/easyjet/script.lua) | [easyjet](https://github.com/konnectors/easyjet) | HTTP |
| [`eaudubassinrennais`](scrapers/eaudubassinrennais/script.lua) | [eaudubassinrennais](https://github.com/konnectors/eaudubassinrennais) | HTTP |
| [`eaudugrandlyon`](scrapers/eaudugrandlyon/script.lua) | [eaudugrandlyon](https://github.com/konnectors/eaudugrandlyon) | HTTP |
| [`edf`](scrapers/edf/script.lua) | [edf](https://github.com/konnectors/edf) | browser |
| [`ekwateur`](scrapers/ekwateur/script.lua) | [ekwateur](https://github.com/konnectors/ekwateur) | HTTP |
| [`electricitestrasbourg`](scrapers/electricitestrasbourg/script.lua) | [electricitestrasbourg](https://github.com/konnectors/electricitestrasbourg) | HTTP |
| [`enercoop`](scrapers/enercoop/script.lua) | [cozy-konnector-enercoop](https://github.com/konnectors/cozy-konnector-enercoop) | HTTP |
| [`engie`](scrapers/engie/script.lua) | [engie](https://github.com/konnectors/engie) | browser |
| [`eovimcdparticuliers`](scrapers/eovimcdparticuliers/script.lua) | [eovimcdparticuliers](https://github.com/konnectors/eovimcdparticuliers) | HTTP |
| [`eticket`](scrapers/eticket/script.lua) | [eticket](https://github.com/konnectors/eticket) | HTTP |
| [`facebook`](scrapers/facebook/script.lua) | [cozy-konnector-facebook](https://github.com/konnectors/cozy-konnector-facebook) | HTTP |
| [`fnac`](scrapers/fnac/script.lua) | [fnac](https://github.com/konnectors/fnac) | browser + HTTP |
| [`fortuneo`](scrapers/fortuneo/script.lua) | [fortuneo](https://github.com/konnectors/fortuneo) | HTTP |
| [`francetravail`](scrapers/francetravail/script.lua) | [poleemploi](https://github.com/konnectors/poleemploi) | browser |
| [`free`](scrapers/free/script.lua) | [cozy-konnector-free](https://github.com/konnectors/cozy-konnector-free) | HTTP |
| [`freemobile`](scrapers/freemobile/script.lua) | [cozy-konnector-free-mobile](https://github.com/konnectors/cozy-konnector-free-mobile) | HTTP |
| [`gazdebordeaux`](scrapers/gazdebordeaux/script.lua) | [gazdebordeaux](https://github.com/konnectors/gazdebordeaux) | HTTP |
| [`geg`](scrapers/geg/script.lua) | [geg](https://github.com/konnectors/geg) | HTTP |
| [`generali`](scrapers/generali/script.lua) | [cozy-konnector-generali](https://github.com/konnectors/cozy-konnector-generali) | HTTP |
| [`github`](scrapers/github/script.lua) | [github](https://github.com/konnectors/github) | HTTP |
| [`glisshop`](scrapers/glisshop/script.lua) | [glisshop](https://github.com/konnectors/glisshop) | HTTP |
| [`harmonie`](scrapers/harmonie/script.lua) | [cozy-konnector-harmonie](https://github.com/konnectors/cozy-konnector-harmonie) | browser |
| [`humanis`](scrapers/humanis/script.lua) | [humanis](https://github.com/konnectors/humanis) | HTTP |
| [`impots`](scrapers/impots/script.lua) | [impots](https://github.com/konnectors/impots) | HTTP |
| [`inulogic`](scrapers/inulogic/script.lua) | [inulogic](https://github.com/konnectors/inulogic) | HTTP |
| [`justeat`](scrapers/justeat/script.lua) | [justeat](https://github.com/konnectors/justeat) | HTTP |
| [`lamutuellegenerale`](scrapers/lamutuellegenerale/script.lua) | [lamutuellegenerale](https://github.com/konnectors/lamutuellegenerale) | browser |
| [`ldlc`](scrapers/ldlc/script.lua) | [ldlc](https://github.com/konnectors/ldlc) | browser |
| [`leclercdrive`](scrapers/leclercdrive/script.lua) | [leclercdrive](https://github.com/konnectors/leclercdrive) | HTTP |
| [`lucca`](scrapers/lucca/script.lua) | [lucca](https://github.com/konnectors/lucca) | HTTP |
| [`luko`](scrapers/luko/script.lua) | [luko](https://github.com/konnectors/luko) | HTTP |
| [`macif`](scrapers/macif/script.lua) | [macif](https://github.com/konnectors/macif) | browser |
| [`maif`](scrapers/maif/script.lua) | [cozy-konnector-maif](https://github.com/konnectors/cozy-konnector-maif) | HTTP |
| [`malakoffmederic`](scrapers/malakoffmederic/script.lua) | [cozy-konnector-malakoffmederic](https://github.com/konnectors/cozy-konnector-malakoffmederic) | browser |
| [`malentille`](scrapers/malentille/script.lua) | [malentille](https://github.com/konnectors/malentille) | HTTP |
| [`materielnet`](scrapers/materielnet/script.lua) | [cozy-konnector-materielnet](https://github.com/konnectors/cozy-konnector-materielnet) | HTTP |
| [`mediapart`](scrapers/mediapart/script.lua) | [mediapart](https://github.com/konnectors/mediapart) | HTTP |
| [`mercermasante`](scrapers/mercermasante/script.lua) | — | browser |
| [`mgen`](scrapers/mgen/script.lua) | [cozy-konnector-mgen](https://github.com/konnectors/cozy-konnector-mgen) | browser |
| [`mint-energie`](scrapers/mint-energie/script.lua) | [mint-energie](https://github.com/konnectors/mint-energie) | HTTP |
| [`misterauto`](scrapers/misterauto/script.lua) | [misterauto](https://github.com/konnectors/misterauto) | HTTP |
| [`mondediplo`](scrapers/mondediplo/script.lua) | [mondediplo](https://github.com/konnectors/mondediplo) | HTTP |
| [`monoprix`](scrapers/monoprix/script.lua) | [monoprix](https://github.com/konnectors/monoprix) | HTTP |
| [`msf`](scrapers/msf/script.lua) | [msf](https://github.com/konnectors/msf) | HTTP |
| [`n26`](scrapers/n26/script.lua) | [n26](https://github.com/konnectors/n26) | HTTP |
| [`nalo`](scrapers/nalo/script.lua) | [nalo](https://github.com/konnectors/nalo) | HTTP |
| [`nespresso`](scrapers/nespresso/script.lua) | [nespresso](https://github.com/konnectors/nespresso) | HTTP |
| [`net-entreprise-micro`](scrapers/net-entreprise-micro/script.lua) | [net-entreprise-micro](https://github.com/konnectors/net-entreprise-micro) | HTTP |
| [`netflix`](scrapers/netflix/script.lua) | [netflix](https://github.com/konnectors/netflix) | browser |
| [`numericable`](scrapers/numericable/script.lua) | [cozy-konnector-numericable](https://github.com/konnectors/cozy-konnector-numericable) | HTTP |
| [`o2`](scrapers/o2/script.lua) | [o2](https://github.com/konnectors/o2) | HTTP |
| [`opngo`](scrapers/opngo/script.lua) | [opngo](https://github.com/konnectors/opngo) | HTTP |
| [`orange`](scrapers/orange/script.lua) | [cozy-konnector-orange](https://github.com/konnectors/cozy-konnector-orange) | browser |
| [`ovh`](scrapers/ovh/script.lua) | [ovh](https://github.com/konnectors/ovh) | HTTP |
| [`pajemploi`](scrapers/pajemploi/script.lua) | [cozy-konnector-pajemploi](https://github.com/konnectors/cozy-konnector-pajemploi) | browser |
| [`payfit`](scrapers/payfit/script.lua) | [payfit](https://github.com/konnectors/payfit) | browser |
| [`planeteoui`](scrapers/planeteoui/script.lua) | [planeteoui](https://github.com/konnectors/planeteoui) | HTTP |
| [`prixtel`](scrapers/prixtel/script.lua) | [prixtel](https://github.com/konnectors/prixtel) | browser |
| [`probikeshop`](scrapers/probikeshop/script.lua) | [probikeshop](https://github.com/konnectors/probikeshop) | browser |
| [`productboard`](scrapers/productboard/script.lua) | [productboard](https://github.com/konnectors/productboard) | HTTP |
| [`red`](scrapers/red/script.lua) | [red](https://github.com/konnectors/red) | browser |
| [`saur`](scrapers/saur/script.lua) | [saur](https://github.com/konnectors/saur) | HTTP |
| [`scaleway`](scrapers/scaleway/script.lua) | [scaleway](https://github.com/konnectors/scaleway) | HTTP |
| [`sfr`](scrapers/sfr/script.lua) | [sfr](https://github.com/konnectors/sfr) | browser |
| [`sfrbox`](scrapers/sfrbox/script.lua) | [cozy-konnector-sfrbox](https://github.com/konnectors/cozy-konnector-sfrbox) | HTTP |
| [`showroomprive`](scrapers/showroomprive/script.lua) | [showroomprive](https://github.com/konnectors/showroomprive) | HTTP |
| [`silae`](scrapers/silae/script.lua) | [silae](https://github.com/konnectors/silae) | HTTP |
| [`sncf`](scrapers/sncf/script.lua) | [cozy-konnector-sncf](https://github.com/konnectors/cozy-konnector-sncf) | browser |
| [`sosh`](scrapers/sosh/script.lua) | [cozy-konnector-sosh](https://github.com/konnectors/cozy-konnector-sosh) | browser |
| [`spartoo`](scrapers/spartoo/script.lua) | [spartoo](https://github.com/konnectors/spartoo) | HTTP |
| [`stickersdiscount`](scrapers/stickersdiscount/script.lua) | [stickersdiscount](https://github.com/konnectors/stickersdiscount) | HTTP |
| [`tagandpass`](scrapers/tagandpass/script.lua) | [tagandpass](https://github.com/konnectors/tagandpass) | HTTP |
| [`theoldreader`](scrapers/theoldreader/script.lua) | [cozy-konnector-theoldreader](https://github.com/konnectors/cozy-konnector-theoldreader) | HTTP |
| [`thomann`](scrapers/thomann/script.lua) | [thomann](https://github.com/konnectors/thomann) | browser |
| [`trainline`](scrapers/trainline/script.lua) | [cozy-konnector-trainline](https://github.com/konnectors/cozy-konnector-trainline) | HTTP |
| [`uber`](scrapers/uber/script.lua) | [cozy-konnector-uber](https://github.com/konnectors/cozy-konnector-uber) | HTTP |
| [`unibet`](scrapers/unibet/script.lua) | [unibet](https://github.com/konnectors/unibet) | HTTP |
| [`venteprivee`](scrapers/venteprivee/script.lua) | [venteprivee](https://github.com/konnectors/venteprivee) | HTTP |
| [`veoliaeau`](scrapers/veoliaeau/script.lua) | [veoliaeau](https://github.com/konnectors/veoliaeau) | browser |
| [`viasante`](scrapers/viasante/script.lua) | [viasante](https://github.com/konnectors/viasante) | HTTP |
| [`vinciautoroute`](scrapers/vinciautoroute/script.lua) | [vinciautoroute](https://github.com/konnectors/vinciautoroute) | browser |
| [`wanimo`](scrapers/wanimo/script.lua) | [wanimo](https://github.com/konnectors/wanimo) | HTTP |
| [`zalando`](scrapers/zalando/script.lua) | [zalando](https://github.com/konnectors/zalando) | browser |
| [`zooplus`](scrapers/zooplus/script.lua) | [zooplus](https://github.com/konnectors/zooplus) | HTTP |

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
