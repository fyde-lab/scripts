-- Scraper for the "Cesu" personal space (www.cesu.urssaf.fr), the Urssaf service for declaring
-- and paying a household employee (particulier employeur) under the "Chèque Emploi Service
-- Universel" scheme.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.progress, fyde.input, fyde.browser, fyde.save_document.
--
-- **Why this drives a real browser instead of `fyde.http`.** Clicking "Se connecter" on
-- www.cesu.urssaf.fr sends the browser through a full OAuth2/OIDC authorization-code-with-PKCE
-- dance across three domains (www.cesu.urssaf.fr -> login.urssaf.fr -> login-secure.urssaf.fr
-- and back), and the `code_challenge`/`nonce`/`state` values for that dance are computed by the
-- cesu.urssaf.fr SPA's own JS *before* the first redirect even happens (SHA-256 + base64url of a
-- fresh `code_verifier` for `code_challenge_method=S256`) - there is no plain-HTTP way to
-- reconstruct that client-side computation (this host's Lua sandbox has no SHA-256/crypto
-- primitive - see `../sdk/src/domains/scrapers/host/`, there is no `fyde.crypto`), and nothing
-- short of a real JS engine can produce it. `fyde.browser` (a real embedded webview - see
-- `../sdk/src/domains/scrapers/browser/driver.rs`) runs that JS the normal way instead of trying
-- to replay it by hand.
--
-- **Login flow, confirmed end to end against several real runs with a real account:**
--   1. `LOGIN_URL` is a cesu.urssaf.fr SPA page whose own JS kicks off the OAuth authorize
--      request (PKCE params generated client-side, per above) and is 302-redirected, fully
--      transparently to a real browser, through login.urssaf.fr's and login-secure.urssaf.fr's
--      OAuth/AM endpoints, landing on a server-rendered login form at
--      `login.urssaf.fr/api/oauth/v1/providerLogin` with plain (not hidden) `#username`/
--      `#password` inputs inside `#login-form`.
--   2. That page's own `initFormFields()` removes `#btn-valider`'s `disabled` attribute
--      unconditionally on load (not gated on field validation) - so filling both fields and
--      clicking is enough, no need to wait for the button to become enabled first.
--   3. Clicking `#btn-valider` runs `submitFormLogin()`, which POSTs the credentials as JSON to
--      `/api/oauth/v1/login` (not a real form submit - an in-page synchronous XHR) and, on
--      success, navigates to the redirect URL the response carries.
--   4. **A first login lands on an email MFA step**: a `login-secure.urssaf.fr/cesu/mfa/
--      challenge` page titled "MFA Challenge", with a 6-char `#code` input and a real (not
--      JS-intercepted) submit button, `#verify`, inside a real `<form method="post">` - clicking
--      it does a normal browser form submission. This script asks for the code via
--      `fyde.input.ask` (see `ameli/script.lua` for the same pattern) - it cannot be answered
--      unattended. Ticking `#rememberDeviceConsent` before submitting (best effort) skips this
--      step on later runs, confirmed live: once ticked, several subsequent runs went straight
--      from credentials to the dashboard with no MFA step at all - WebKitGTK's default webview
--      profile is apparently persistent across separate process runs even though
--      `scrapers::browser::init()` builds a fresh `BrowserDriver` each run (nothing in this host
--      explicitly configures a data directory - see `browser::driver::run_event_loop`).
--   5. Past MFA (or directly, for a remembered device), the OAuth dance finishes transparently
--      (an invisible device-fingerprint POST on the `login-secure.urssaf.fr/cesu/login/callback`
--      page, then back through `cesu/oauth/authorize` to a final `www.cesu.urssaf.fr/decla/
--      index.html?...&code=...` landing page), which itself exchanges the code for a token and
--      calls `cesuwebdec/authenticationPanorama` to establish the real authenticated session -
--      all before the dashboard renders.
--   6. Success is confirmed by `LOGGED_IN_MARKER`, the employer menu's "Mes déclarations" link
--      (`name="page_empl_mes_declarations"`), which the SPA only renders once the authenticated
--      dashboard is up. **Not `#deconnexion_link`** (the desktop logout link, which this script
--      used to wait for): confirmed live (2026-10-11), it sits in the static connected-mode
--      header template of *every* cesu.urssaf.fr page, logged out included (hidden, empty
--      `#modeConnecte_header_num_cesu` next to it, menu limited to `page_accueil`/
--      `page_tous_les_liens`) - so a logged-out LOGIN_URL matched it before its OAuth redirect to
--      the login form even fired, the run logged a false `ALREADY_LOGGED_IN`, and every document
--      lookup then ran against the login form. A failed login (wrong credentials) re-renders the
--      same login form with its `#alert-panel` error message visible instead of navigating away,
--      so this script treats "still on the login form" as a distinct, clearer error than a bare
--      timeout.
--
-- **`fyde.browser:wait_for` races the OAuth redirect chain - retry it in short bursts, not one
-- long wait.** `wait_for` injects a one-shot JS poll into whatever page is *currently* loaded in
-- the webview (see `browser::driver::wait_for_script`'s doc comment); the entire login flow above
-- is nothing but navigations (six-plus redirects across three domains, even before the real form
-- renders), and a navigation destroys that in-page poll without it ever reporting back - Rust
-- only learns about it once its own full timeout elapses, however fast the real page actually
-- settled. A single `wait_for(selector, 30000)` placed right after a step that triggers
-- navigation reliably stalls for the entire 30s even when the target selector was ready in well
-- under a second, because the poll that would have found it was almost always injected into a
-- page that got replaced moments later (confirmed against a real run: the post-timeout
-- `fyde.browser:html()` dump showed the target element present, fully initialized, immediately
-- after the "timed out" error). `wait_for_through_navigation` below works around this by retrying
-- `wait_for` itself in several short attempts: each attempt re-injects the poll against whatever
-- page is current *right then*, so once the redirect chain actually settles, the very next
-- attempt (not the one that happened to be in flight when the last redirect fired) succeeds
-- immediately. The post-submit wait below passes a grouped, comma-separated selector (both
-- `LOGGED_IN_MARKER` and `MFA_CODE_FIELD` at once - `document.querySelector` accepts a
-- comma-separated list, same trick `ameli/script.lua` uses), since a real submit can land on
-- either depending on whether this device is already remembered.
--
-- **Navigating within the dashboard: click the real menu link, don't `open()` a `?page=` URL.**
-- Confirmed live: `fyde.browser:open("...index.html?page=page_empl_mes_declarations&LANG=FR")`
-- (and the equivalent for `page_empl_avantage_fiscal`), each polled for up to 12s, produced
-- byte-for-byte identical page content both times - almost certainly bounced back to whatever
-- page was already showing. This SPA's own menu links all have an empty `href=""` and a
-- `name="page_xxx"` attribute instead - the "page" shown is swapped by in-page JS reading that
-- `name`, not by loading a distinct URL. `click_menu_link` below finds the real link by its
-- `name` attribute and `fyde.browser:click`s it for real instead.
--
-- **Downloading documents: `fyde.browser:download`, not a no-op click.** Both pages this script
-- visits list real documents with a confirmed, identical convention: a hidden `display:none`
-- template button, `id="affichagePdf"`, and one real, visible button per document,
-- `id="affichagePdf_<id>"` - "Bulletin de salaire" buttons (one per declared pay period) on the
-- declarations page, "Télécharger" (the attestation fiscale) on the avantage fiscal page, same id
-- prefix, presumably the same JS handler. Clicking a real `affichagePdf_<id>` button was
-- confirmed, live, to produce **no observable change to the current page whatsoever** via plain
-- `fyde.browser:click` - polled at 5/10/15s after the click, `fyde.browser:html()`'s snapshot
-- came back byte-for-byte identical. That's because the handler doesn't change the page at all -
-- it triggers the webview engine's own native file-download machinery (most likely a
-- `window.open()` whose response carries `Content-Disposition: attachment`), which neither
-- `wait_for` nor `html` can ever observe since nothing in the DOM changes.
-- `fyde.browser:download(selector, [timeout_ms])` (see `../../../sdk/src/domains/scrapers/
-- browser/driver.rs`'s `download_started_handler`/`download_completed_handler`) clicks the same
-- selector but waits for, and returns the bytes of, that native download instead - this is what
-- `M.run` below uses to actually save each bulletin/attestation it finds.

local M = {}

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local LOGIN_URL = "https://www.cesu.urssaf.fr/decla/index.html?page=page_se_connecter&LANG=FR"

local USERNAME_FIELD = "#username"
local PASSWORD_FIELD = "#password"
local SUBMIT_CONTROL = "#btn-valider"
local MFA_CODE_FIELD = "#code"
local MFA_SUBMIT_CONTROL = "#verify"
-- The "Mes déclarations" menu link, not `#deconnexion_link`: see point 6 of the header comment.
local LOGGED_IN_MARKER = '[name="page_empl_mes_declarations"]'

-- The OAuth dance alone crosses three domains before the login form even renders - budget
-- ~10 short attempts (see the header comment on why short-and-repeated beats one long wait).
local FORM_LOAD_ATTEMPTS = 10
local FORM_LOAD_ATTEMPT_TIMEOUT_MS = 4000
-- Past the credentials POST: an invisible device-fingerprint POST, two more OAuth redirects, a
-- token exchange, and authenticationPanorama, all before the dashboard renders.
local POST_SUBMIT_ATTEMPTS = 12
local POST_SUBMIT_ATTEMPT_TIMEOUT_MS = 4000
local PROBE_TIMEOUT_MS = 1000
-- A real PDF download routinely takes longer to settle than a DOM change does.
local DOWNLOAD_TIMEOUT_MS = 30000

-- Retries `fyde.browser:wait_for` in several short attempts instead of one long one - see the
-- header comment for why a single long wait races page navigations and silently stalls.
local function wait_for_through_navigation(selector, attempts, attempt_timeout_ms)
  local last_err
  for _ = 1, attempts do
    local ok, err = pcall(function()
      fyde.browser:wait_for(selector, attempt_timeout_ms)
    end)
    if ok then
      return
    end
    last_err = err
  end
  error(last_err)
end

-- Polls `selector` with a short timeout and reports whether it matched, instead of erroring out -
-- used to tell apart the states a real submit can land on. Only used once the page has had time
-- to settle (right after `wait_for_through_navigation` above already found one of them), so a
-- single short attempt is enough here, unlike the retrying helper above.
local function browser_has(selector)
  local ok = pcall(function()
    fyde.browser:wait_for(selector, PROBE_TIMEOUT_MS)
  end)
  return ok
end

-- Used purely as a delay (this host has no `fyde.sleep`): waits for a selector that can never
-- match, so the call always runs for the full `ms` before `wait_for` reports its timeout.
local function sleep_ms(ms)
  pcall(function()
    fyde.browser:wait_for("__never_matches_anything__", ms)
  end)
end

-- Dumps whatever actually rendered instead of erroring blind, so a future run tells us which
-- state this script doesn't handle yet (an error page, a slower-than-expected render, ...)
-- rather than just "timed out".
local function log_page_for_diagnosis(context)
  local html_ok, html = pcall(function()
    return fyde.browser:html()
  end)
  if html_ok then
    fyde.log.info(context .. " - page length: " .. #html)
    fyde.log.info(context .. " - title: " .. tostring(html:match("<title[^>]*>(.-)</title>")))
    local names, seen = {}, {}
    for name in html:gmatch('name="(page_[%w_]+)"') do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
    fyde.log.info(context .. " - page_* names: " .. table.concat(names, ", "))
    -- A small page is an intermediate/error page (e.g. an OAuth callback) - worth logging whole.
    if #html < 8000 then
      fyde.log.info(context .. " - page markup: " .. html)
    end
  else
    fyde.log.info(context .. " - fetching page markup for diagnosis also failed: " .. tostring(html))
  end
end

-- Asks for the emailed MFA code, fills it in, and submits - a real click on `#verify`, a genuine
-- `<button type="submit">` inside a real `<form method="post">`, so this is an ordinary browser
-- form submission (unlike the main login's JS-intercepted `submitFormLogin`).
local function submit_mfa_code()
  local code = fyde.input.ask("Cesu emailed a one-time code - enter it:"):gsub("%s", "")
  -- An unanswered prompt (e.g. an unattended run with no stdin) - don't submit an empty code and
  -- sit through the whole post-submit wait for nothing.
  if code == "" then
    error("no one-time code entered")
  end
  fyde.browser:fill(MFA_CODE_FIELD, code)
  -- Ticks "Mémoriser mon appareil pour 2 mois" - confirmed live to skip this step on later runs
  -- (see the header comment) - best effort, not load-bearing: if this checkbox ever goes away,
  -- MFA just happens every run instead.
  pcall(function()
    fyde.browser:click("#rememberDeviceConsent")
  end)
  fyde.browser:click(MFA_SUBMIT_CONTROL)
  wait_for_through_navigation(LOGGED_IN_MARKER, POST_SUBMIT_ATTEMPTS, POST_SUBMIT_ATTEMPT_TIMEOUT_MS)
end

-- Finds every `<tag ... name="name" ...>` occurrence in `html` and returns each one's full
-- opening tag text (by scanning outward from the `name="..."` match to the nearest `<`/`>`), so
-- the real `id` (and any other attributes) can be read off it without guessing.
local function tags_with_name(html, name)
  local tags = {}
  local marker = 'name="' .. name .. '"'
  local pos = 1
  while true do
    local s = html:find(marker, pos, true)
    if not s then
      break
    end
    local lt
    for i = s, 1, -1 do
      if html:sub(i, i) == "<" then
        lt = i
        break
      end
    end
    local gt = html:find(">", s)
    table.insert(tags, lt and gt and html:sub(lt, gt) or "<?>")
    pos = s + #marker
  end
  return tags
end

-- Prefers a non-mobile/non-burger-menu id (the desktop menu is what's actually visible in this
-- headless-sized window), falling back to whichever id was found first.
local function pick_id(tags)
  local fallback
  for _, tag in ipairs(tags) do
    local id = tag:match('id="([^"]+)"')
    if id then
      fallback = fallback or id
      if not id:find("burger") and not id:find("mobile") then
        return id
      end
    end
  end
  return fallback
end

-- Finds the dashboard's menu link by its `name` attribute (see the header comment on why this,
-- not `fyde.browser:open`, is how navigation within this SPA actually works) and clicks it.
-- Returns whether a link was found at all.
local function click_menu_link(html, name)
  local id = pick_id(tags_with_name(html, name))
  if not id then
    return false
  end
  fyde.log.info("clicking menu link #" .. id .. " (name=\"" .. name .. "\")")
  fyde.browser:click("#" .. id)
  return true
end

-- Finds every real (non-template) `id="<prefix>_<id>"` in `html`, returning each `<id>` suffix -
-- used for the `affichagePdf_<id>` document buttons (see the header comment on their shared,
-- confirmed naming convention across both the declarations and avantage fiscal pages).
local function real_ids(html, prefix)
  local ids = {}
  local pos = 1
  while true do
    local s, e, suffix = html:find('id="' .. prefix .. '_([%w]+)"', pos)
    if not s then
      break
    end
    table.insert(ids, suffix)
    pos = e + 1
  end
  return ids
end

-- Downloads and saves every id in `ids` by clicking its "affichagePdf_<id>" button via
-- `fyde.browser:download` (see the header comment for why `download`, not plain `click`, is what
-- actually retrieves the file). A failed download for one id is logged and skipped rather than
-- aborting the whole run - a pattern already used by every other scraper's own per-document loop
-- (see `../impots/script.lua`/`../didaxis/script.lua`).
local function download_and_save(ids, slug, label, fields)
  for _, id in ipairs(ids) do
    local ok, result = pcall(function()
      return fyde.browser:download("#affichagePdf_" .. id, DOWNLOAD_TIMEOUT_MS)
    end)
    if ok then
      fyde.save_document("cesu/" .. slug .. "_" .. id .. ".pdf", result, fields)
      fyde.log.info(string.format("saved %s %s (%d bytes)", label, id, #result))
    else
      fyde.log.warn(string.format("failed to download %s %s: %s", label, id, tostring(result)))
    end
  end
end

function M.run(params)
  fyde.progress.step("Visiting the login page")
  -- A real browser follows LOGIN_URL's cross-domain OAuth redirect chain (and runs the SPA's own
  -- PKCE-generating JS) on its own - there's no manual Location-header chasing to do here.
  fyde.browser:open(LOGIN_URL)
  local load_ok, load_err = pcall(function()
    wait_for_through_navigation(USERNAME_FIELD .. ", " .. LOGGED_IN_MARKER, FORM_LOAD_ATTEMPTS, FORM_LOAD_ATTEMPT_TIMEOUT_MS)
  end)
  if not load_ok then
    log_page_for_diagnosis("login form timeout")
    error(load_err)
  end

  if browser_has(LOGGED_IN_MARKER) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    fyde.log.info("LOGIN_PAGE_FOUND")
    fyde.progress.step("Submitting credentials")
    fyde.browser:fill(USERNAME_FIELD, params.username)
    fyde.browser:fill(PASSWORD_FIELD, params.password)
    fyde.browser:click(SUBMIT_CONTROL)

    local ok, err = pcall(function()
      wait_for_through_navigation(
        LOGGED_IN_MARKER .. ", " .. MFA_CODE_FIELD,
        POST_SUBMIT_ATTEMPTS,
        POST_SUBMIT_ATTEMPT_TIMEOUT_MS
      )
    end)
    if not ok then
      if browser_has(USERNAME_FIELD) then
        fyde.log.warn("login did not succeed - still on the login form after submitting (rejected credentials)")
        error("INVALID_CREDENTIALS", 0)
      end
      log_page_for_diagnosis("post-submit timeout")
      error(err)
    end

    if browser_has(LOGGED_IN_MARKER) then
      fyde.log.info("logged in without a one-time code step (device already remembered)")
    elseif browser_has(MFA_CODE_FIELD) then
      fyde.progress.step("Waiting for the one-time code")
      if not pcall(submit_mfa_code) then
        fyde.log.warn("the one-time code was not accepted")
        error("MFA_FAILED", 0)
      end
    else
      error("post-submit page matched neither the logged-in marker nor the MFA code field")
    end

    if not browser_has(LOGGED_IN_MARKER) then
      error(
        "login did not succeed - found no '"
          .. LOGGED_IN_MARKER
          .. "' logout link, so the session does not appear authenticated"
      )
    end
    fyde.log.info("authenticated")
  end

  fyde.progress.step("Listing bulletins de salaire")
  local dashboard_html = fyde.browser:html()
  if click_menu_link(dashboard_html, "page_empl_mes_declarations") then
    sleep_ms(3000)
    local bulletin_ids = real_ids(fyde.browser:html(), "affichagePdf")
    fyde.log.info(#bulletin_ids .. " bulletin(s) de salaire found")
    download_and_save(bulletin_ids, "bulletin", "bulletin de salaire", {
      type = "payslip",
      source_category = "gov",
      purpose = "employment",
    })
  else
    fyde.log.warn('could not find the "Mes déclarations" menu link on the dashboard')
    log_page_for_diagnosis("no Mes déclarations link")
  end

  fyde.progress.step("Listing avantage fiscal attestations")
  local current_html = fyde.browser:html()
  if click_menu_link(current_html, "page_empl_avantage_fiscal") then
    sleep_ms(3000)
    local attestation_ids = real_ids(fyde.browser:html(), "affichagePdf")
    fyde.log.info(#attestation_ids .. " attestation(s) fiscale(s) found")
    download_and_save(attestation_ids, "attestation_fiscale", "attestation fiscale", {
      type = "tax_certificate",
      source_category = "gov",
      source_sub_category = "tax",
      purpose = "attestation",
    })
  else
    fyde.log.warn('could not find the "Mon avantage fiscal" menu link on the current page')
    log_page_for_diagnosis("no Mon avantage fiscal link")
  end
end

return M
