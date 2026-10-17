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

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper - see README.md).
--
-- Login error contract: a rejected username/password always fails the run with exactly
-- `INVALID_CREDENTIALS`, and a rejected, expired or unanswered OTP/MFA step with exactly
-- `MFA_FAILED` (both raised with `error(code, 0)`, so the message carries no position prefix).
-- Any other failure is a free-form error message.
--
-- Log markers (grepped by tests/login_smoke.sh): `LOGIN_PAGE_FOUND` once the login form has
-- been seen, `ALREADY_LOGGED_IN` when a restored session made the login step unnecessary.
-- ---------------------------------------------------------------------------------------------
local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize(name)
  name = trim((name or ""):gsub("%s+", " "))
  name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

-- Asks the user for a one-time code through fyde.input.ask; an unanswered/empty prompt (or no
-- input handler at all, e.g. an unattended run) is an MFA failure.
local function ask_code(question)
  local ok, code = pcall(fyde.input.ask, question)
  if not ok or type(code) ~= "string" or trim(code) == "" then
    fail(MFA_FAILED, "no one-time code was provided")
  end
  return (code:gsub("%s", ""))
end

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

-- Fills `values` into the form matching `selector` on `page` and posts it.
local function submit_form(page, selector, values, headers)
  local action, fields = read_form(page, selector)
  if not action then
    error("no form matching '" .. selector .. "' on " .. tostring(page.url))
  end
  for name, value in pairs(values) do
    fields[name] = value
  end
  return fyde.http.post_form(action, fields, headers)
end

local function has(page_or_html, selector)
  local html = type(page_or_html) == "table" and page_or_html.body or page_or_html
  return #fyde.html.select(html or "", selector) > 0
end

local function json_or_nil(body)
  local ok, value = pcall(fyde.json.decode, body or "")
  if ok then
    return value
  end
  return nil
end

-- Downloads `url` and saves it as `filename` when it really is a PDF; returns true on success.
local function save_pdf(url, filename, fields, headers)
  local resp = fyde.http.download(url, headers)
  local content_type = resp.content_type or ""
  local is_pdf = content_type:find("pdf", 1, true) or (resp.body or ""):sub(1, 4) == "%PDF"
  if resp.status == 200 and is_pdf then
    fyde.save_document(sanitize(filename), resp.body, fields)
    return true
  end
  fyde.log.warn(string.format("skipping %s (status %d, content-type %s)", filename, resp.status, content_type))
  return false
end
-- luacheck: pop

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
