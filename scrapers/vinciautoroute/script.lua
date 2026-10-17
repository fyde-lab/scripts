-- Scraper for VINCI Autoroutes' toll-badge customer area, now Ulys (account.ulys.com): login
-- check only - documents blocked, see below.
--
-- The original
-- espaceabonnes.vinci-autoroutes.com now redirects to account.ulys.com, and the original
-- oidc-bcu.vinci-autoroutes.com no longer answers. The new customer area is an Angular SPA
-- signing in through an IdentityServer at connect.ulys.com (client `BCU.EspaceClient`, redirect
-- `https://account.ulys.com/oidc-callback`, both from the SPA's bundle). Its server-rendered
-- `/Account/Login` form (`#username`/`#password`, `#login` button) is gated by a Friendly Captcha
-- widget that a plain HTTP post can't satisfy ("Merci de prouver que vous n'êtes pas un robot"),
-- but that solves itself in the webview once `.frc-button` is clicked (proof of work, ~5s), which
-- enables `#login`. Bad credentials re-render the form with "Votre identifiant ou votre mot de
-- passe n’est pas correct". All of the above is confirmed against the live site.
--
-- **Blocked past the login:** a successful login hands back to account.ulys.com, whose SPA
-- refuses WebKitGTK outright ("Votre Espace Client ne fonctionne pas sur ce navigateur : Safari
-- 11.x sur Linux"), and `fyde.browser` exposes neither the current URL (to exchange the
-- authorization code with `fyde.http` instead) nor a way to change its user agent. So invoices
-- (`api.ulys.invoices.r` on the SPA's API) aren't fetched: leaving connect.ulys.com counts as
-- logged in, and the run then stops with an explicit error. See README.md.

local M = {}

local AUTHORIZE_URL = "https://connect.ulys.com/connect/authorize?client_id=BCU.EspaceClient"
  .. "&response_type=code&scope=openid%20email&redirect_uri=https%3A%2F%2Faccount.ulys.com%2Foidc-callback"
  .. "&state=fyde&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
local LOGIN_FORM = "form#fullLogin"
local CAPTCHA_BUTTON = ".frc-button"
-- Only rendered after a rejected login (the field-level messages are always in the markup).
local BAD_CREDENTIALS = { "mot de passe n’est pas correct", "mot de passe n'est pas correct" }
-- What account.ulys.com's SPA shows WebKitGTK - also the sign the login went through.
local LEFT_LOGIN = { "ne fonctionne pas sur ce navigateur", "Espace Client" }

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
local fail = helpers.fail
local contains_any = helpers.contains_any
local sanitize = helpers.sanitize
local read_form = helpers.read_form

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

local function body_text(html)
  local body = fyde.html.select(html, "body")[1]
  return body and body.text or ""
end

-- "login" while connect.ulys.com's form is shown, "left" once the browser is past it.
local function current_state(html)
  if has(html, LOGIN_FORM) then
    return "login"
  elseif contains_any(body_text(html), LEFT_LOGIN) then
    return "left"
  end
  return nil
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Logging in")
  fyde.browser:fill("#username", params.username)
  fyde.browser:fill("#password", params.password)
  fyde.browser:click(CAPTCHA_BUTTON)
  local ready = false
  for _ = 1, 30 do
    sleep(1000)
    local button = fyde.html.select(page_html(), "#login")[1]
    if button and button.attrs.disabled == nil then
      ready = true
      break
    end
  end
  if not ready then
    error("Ulys' anti-robot check (Friendly Captcha) did not complete")
  end
  fyde.browser:click("#login")
  sleep(2000)
  for _ = 1, 40 do
    local html = page_html()
    if has(html, LOGIN_FORM) and contains_any(body_text(html), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    elseif current_state(html) == "left" then
      return
    end
    sleep(1000)
  end
  if has(page_html(), LOGIN_FORM) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  error("Ulys login did not complete")
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(AUTHORIZE_URL)
  local state
  for _ = 1, 45 do
    sleep(1000)
    state = current_state(page_html())
    if state then
      break
    end
  end
  if state == "left" then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif state == "login" then
    login(params)
  else
    error("Ulys login page not found on connect.ulys.com")
  end
  error("logged in, but Ulys' customer area refuses this browser engine, so invoices can't be "
    .. "fetched - see this script's header comment", 0)
end

return M
