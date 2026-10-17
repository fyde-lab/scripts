-- Scraper for Pajemploi (pajemploi.urssaf.fr), Urssaf's service for parents employing a
-- child-minder: login only for now, documents not ported yet.
--
-- The original
-- www.pajemploi.urssaf.fr/pajeweb JSP pages (logindec.htm, connect.htm, ajaxlistebs.jsp...) now
-- all redirect to urssaf.fr's "se connecter" hub. Pajemploi is now an Angular SPA
-- (pajemploi.urssaf.fr, `assets/configuration/env.js`) that logs in through Urssaf's OIDC
-- provider (login.urssaf.fr, the same login page as `scrapers/cesu`) and reads everything from
-- api.urssaf.fr/paje/apaj/v1 with a bearer token kept by the SPA - out of reach of `fyde.http`.
-- So the login is driven through `fyde.browser`, the same way as cesu's (whose flow is confirmed
-- with a real account): opening the SPA lands on login.urssaf.fr's `#username`/`#password` form
-- (confirmed), `#btn-valider` submits it, a `#code` field means an emailed one-time code.
-- Not verified (no account): what the SPA shows once logged in (looked for as a "déconnexion"
-- control) - and the payslips/tax certificates aren't ported to the new API: a successful login
-- stops with an explicit error. See README.md.

local M = {}

local APP_URL = "https://pajemploi.urssaf.fr/"
local USERNAME_FIELD = "#username"
local PASSWORD_FIELD = "#password"
local SUBMIT_CONTROL = "#btn-valider"
local MFA_CODE_FIELD = "#code"
local MFA_SUBMIT_CONTROL = "#verify"
local LOGGED_IN_TEXT = { "déconnexion", "se déconnecter" }
-- Error messages login.urssaf.fr shows on the form after a rejected login - the last one is its
-- 30-minute lockout after 3 failed attempts (confirmed), reported as rejected credentials too.
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "incorrect", "invalide", "tentatives de connexion ont échoué" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains_any = helpers.contains_any
local ask_code = helpers.ask_code
local has = helpers.has

local function sleep(ms)
  pcall(function()
    fyde.browser:wait_for("#__fyde_scraper_sleep__", ms)
  end)
end

local function page_html()
  local ok, html = pcall(function()
    return fyde.browser:html()
  end)
  return ok and html or ""
end

-- Polls the page every second for up to `timeout_ms` and returns the first state seen:
-- "mfa", "login" (the credentials form), or "logged_in" (no form, a logout control) - nil on
-- timeout. Polling with short reads survives the OAuth redirects between login.urssaf.fr and
-- the SPA, where a long `wait_for` would die with the page it was issued against.
-- With `after_submit`, the credentials form only counts once it shows an error message ("bad"),
-- since it stays on screen for a moment after the click whatever the outcome.
local function wait_state(timeout_ms, after_submit)
  for _ = 1, math.ceil(timeout_ms / 1000) do
    local html = page_html()
    local body = fyde.html.select(html, "body")[1]
    local text = body and body.text or ""
    if has(html, MFA_CODE_FIELD) then
      return "mfa", html
    elseif has(html, USERNAME_FIELD) then
      if not after_submit then
        return "login", html
      elseif contains_any(text, BAD_CREDENTIALS) then
        return "bad", html
      end
    elseif contains_any(text, LOGGED_IN_TEXT) then
      return "logged_in", html
    end
    sleep(1000)
  end
  return nil, page_html()
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Submitting credentials")
  fyde.browser:fill(USERNAME_FIELD, params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)
  local state, html = wait_state(45000, true)
  if state == "bad" then
    fail(INVALID_CREDENTIALS, "rejected by Urssaf")
  elseif state == nil and has(html, USERNAME_FIELD) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  elseif state == "mfa" then
    fyde.progress.step("Waiting for the one-time code")
    fyde.browser:fill(MFA_CODE_FIELD, ask_code("Code reçu par e-mail de l'Urssaf (Pajemploi)"))
    pcall(function()
      fyde.browser:click("#rememberDeviceConsent")
    end)
    fyde.browser:click(MFA_SUBMIT_CONTROL)
    sleep(2000)
    if wait_state(45000) ~= "logged_in" then
      fail(MFA_FAILED, "no logged-in page after the one-time code")
    end
  elseif state ~= "logged_in" then
    error("Pajemploi login did not complete (no logged-in page after submitting)")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(APP_URL)
  sleep(1500)
  local state = wait_state(45000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif state == "login" then
    login(params)
  else
    error("Pajemploi login page not found (neither the Urssaf login form nor a logged-in page)")
  end
  error("logged in, but Pajemploi's documents (payslips, tax certificates) aren't ported to its new "
    .. "API yet - see this script's header comment", 0)
end

return M
