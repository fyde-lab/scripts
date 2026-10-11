-- Scraper for France Travail's ("Pôle emploi") job-seeker personal space
-- (candidat.francetravail.fr/espacepersonnel).
--
-- **Why this drives a real browser instead of `fyde.http`.** The previous revision of this
-- script (see git history) drove the whole login flow - including ForgeRock/OpenAM's
-- callback-based auth tree - through `fyde.http`, replaying the tree's JSON callbacks by hand
-- (including a static, fabricated `DeviceProfileCallback` payload - see that revision's
-- `device_profile_json()`). That got through the credentials step but was then rejected with a
-- `401 authentFailed` right after submitting the device-profile callback, for a reason never
-- confirmed - most likely that a plain HTTP client structurally cannot produce whatever the
-- real page's device-fingerprinting JS computes, the same class of problem documented in
-- `ameli/script.lua`'s header comment for the same symptom on a different site. `fyde.browser`
-- (a real embedded webview) exists for exactly this: the site's own JS actually runs, so the
-- `DeviceProfileCallback` step (and whatever anti-fraud check sits behind it) is satisfied the
-- normal way, by a real browser, with no manual callback-filling for it needed from this script
-- at all.
--
-- **Confirmed so far, via a live (no-login) and a live (one real login attempt) run of this
-- script against the real site** - not reverse-engineered from a HAR:
--   1. `HOME_URL` renders a server-side, jQuery-based login form (not an Angular SPA, contrary
--      to what the previous revision's header comment assumed) directly - no OAuth2 redirect
--      chain visible to `fyde.browser` (`fyde.browser` has no way to read the current URL, only
--      `html()`, so whatever redirecting happens client-side is transparent here either way).
--      The form's own `tag-page="Connexion_compte/Saisie_identifiants"` marker (on `#page`) is
--      this script's one confirmed way to tell "showing the login form" apart from anything
--      else - see `LOGIN_FORM_MARKER`.
--   2. Credentials fields: `#identifiant` (`name="callback_0"`, `autocomplete="username"`) and
--      `#password` (`name="callback_1"`, `autocomplete="current-password"`), submitted via
--      `#submit` (a real `<button type="submit">`, not an `onclick` handler to replicate by
--      hand).
--   3. Submitting real, correct credentials (confirmed by the account holder) does **not** land
--      back on the login form - `LOGIN_FORM_MARKER` is gone afterward - but what it lands on
--      instead (the device-profile check almost certainly completes invisibly, per the header
--      comment above, followed by some combination of ForgeRock's `SelectionMoyenDeContact`/
--      `OTPCollectorPage`/`SaveMoyenDeConfiance` stages - see the previous revision's header
--      comment for what those stages ask for in the JSON API this script no longer talks to
--      directly) **is not yet confirmed**: capturing it requires a second real login attempt
--      (the first already used up this run's one-time code), which needs a real run by someone
--      not blocked from submitting real third-party credentials.
--
-- **Not yet implemented: the OTP/trusted-device steps and document fetching.** `run` below gets
-- as far as submitting credentials and confirming the login form is gone, then stops and dumps
-- diagnostic info via `fyde.log` instead of guessing selectors for whatever comes next. Once a
-- real run against a fresh login shows what that screen actually looks like, OTP entry needs
-- `fyde.input.ask` wired in the same way `ameli/script.lua`'s `submit_otp()` does it (not used
-- here yet - there's nothing to ask for until the real OTP screen's selectors are known).
-- Document fetching was never reached by the original HAR either (see git history) and still
-- needs its own capture.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.progress, fyde.browser, fyde.html.

local M = {}

-- Login error contract shared with every scraper ported from github.com/konnectors (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local HOME_URL = "https://candidat.francetravail.fr/espacepersonnel/"

local IDENTIFIANT_FIELD = "#identifiant"
local PASSWORD_FIELD = "#password"
local SUBMIT_CONTROL = "#submit"

-- The login form's own `tag-page` attribute value (on `#page`), confirmed present only while
-- the login form itself is showing - see header comment, point 1.
local LOGIN_FORM_MARKER = "Connexion_compte/Saisie_identifiants"

local FORM_LOAD_TIMEOUT_MS = 30000
-- Unconfirmed how long the post-submit device-profile check + next stage render actually takes
-- here (the previous `fyde.http` revision's own equivalent step was near-instant, but that
-- didn't run the site's real fingerprinting JS) - borrowing `ameli/script.lua`'s
-- POST_SUBMIT_TIMEOUT_MS as a starting point for the same class of bot-mitigation delay.
local POST_SUBMIT_TIMEOUT_MS = 45000

-- Shown above the form after a refused identifiant/password (checked live, with made-up
-- credentials): "Nom d'utilisateur ou mot de passe incorrect, veuillez corriger...".
local BAD_CREDENTIALS = "mot de passe incorrect"

-- `html()`/`wait_for` both fail with "timed out ... waiting for the browser" while the page is
-- still loading - which, on this site, can last past the form being fully usable. These read the
-- page tolerating that, as "" when it can't be read yet.
local function page_html()
  local ok, html = pcall(function()
    return fyde.browser:html()
  end)
  return ok and html or ""
end

-- True if the login form (see LOGIN_FORM_MARKER) is still/again showing on the current page.
local function on_login_form()
  return page_html():find(LOGIN_FORM_MARKER, 1, true) ~= nil
end

-- Polls (1s at a time, via `wait_for` on a selector that never exists) until `check()` returns a
-- truthy value or `timeout_ms` runs out.
local function poll(check, timeout_ms)
  local waited = 0
  repeat
    local result = check()
    if result then
      return result
    end
    pcall(function()
      fyde.browser:wait_for("#__francetravail_scraper_force_wait__", 1000)
    end)
    waited = waited + 1000
  until waited >= timeout_ms
  return nil
end

function M.run(params)
  fyde.progress.step("Opening the homepage")
  fyde.browser:open(HOME_URL)
  pcall(function()
    fyde.browser:wait_for(IDENTIFIANT_FIELD, FORM_LOAD_TIMEOUT_MS)
  end)
  -- The load can outlast `wait_for` even once the form is usable (see `page_html`), so whether
  -- the form is there is checked on the page itself. A page that never shows anything readable
  -- is an error, not a session: assuming one would hide every broken load as ALREADY_LOGGED_IN.
  local opened = poll(function()
    local html = page_html()
    if html:find(LOGIN_FORM_MARKER, 1, true) then
      return "login"
    end
    return #html > 0 and #fyde.html.select(html, "body *") > 20 and "other" or nil
  end, FORM_LOAD_TIMEOUT_MS)
  if not opened then
    error("France Travail page did not load")
  end

  -- Checking for an existing session: mirrors didaxis/caf's "Checking for an existing session"
  -- pattern, but fyde.browser has no cookie-jar bridge to fyde.http and no way to read the
  -- current URL (see host/browser.rs's doc comment) - the login form's own marker being present
  -- right after opening HOME_URL is the only signal available here. **Unconfirmed**: whether a
  -- still-valid SSO session actually skips the login form the same way it does for
  -- `fyde.http`'s cookie-jar-based scrapers, since fyde.browser's webview keeps its own,
  -- separate session/cookie state across runs (not yet verified to persist at all).
  if not on_login_form() then
    fyde.log.info("login form not shown on open - assuming an existing session is still valid")
    fyde.log.info("ALREADY_LOGGED_IN")
    fyde.progress.step("Done")
    return
  end

  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Submitting credentials")
  fyde.browser:fill(IDENTIFIANT_FIELD, params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)

  -- No known selector for whatever renders next (OTP channel choice, OTP entry, trusted-device
  -- prompt, or straight through to the SPA - see header comment), and `wait_for` only supports
  -- a CSS selector, not a text/marker search - so there's nothing to usefully wait_for here.
  -- Force a fixed delay for the page transition/device-profile-check round trip instead (same
  -- reasoning as ameli/script.lua's own POST_SUBMIT_TIMEOUT_MS, a bot-mitigation-related delay
  -- observed taking anywhere from ~20s to noticeably longer there).
  local outcome = poll(function()
    local html = page_html()
    if html:find(BAD_CREDENTIALS, 1, true) then
      return "bad"
    end
    return html ~= "" and not html:find(LOGIN_FORM_MARKER, 1, true) and "next" or nil
  end, POST_SUBMIT_TIMEOUT_MS)

  if outcome == "bad" then
    error("INVALID_CREDENTIALS", 0)
  end
  if on_login_form() then
    -- Still on the form without the error message: most likely a refused login too (the
    -- device-profile check failing silently would look the same - unconfirmed).
    fyde.log.warn("still showing the login form after submitting credentials")
    error("INVALID_CREDENTIALS", 0)
  end

  -- TODO: once a real login attempt's post-submit page is captured, replace this diagnostic
  -- dump with real handling for whatever stage(s) actually render (OTP channel choice via
  -- fyde.browser:click, OTP entry via fyde.input.ask + fyde.browser:fill, trusted-device prompt
  -- via fyde.browser:click) - see header comment.
  local html = page_html()
  fyde.log.info("post-submit page length: " .. #html)
  fyde.log.info("post-submit page snippet: " .. html:sub(1, 2000))
  error(
    "login form is gone, but this script doesn't yet know how to handle whatever comes next "
      .. "(OTP/trusted-device steps aren't implemented) - see the dumped page snippet above, or "
      .. "re-run and inspect data/reports/francetravail_*.json for the full page"
  )
end

return M
