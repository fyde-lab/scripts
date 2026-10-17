-- Scraper for Électricité de Strasbourg's online customer area (ÉS, espaceclient.es.fr): meant
-- to download the bills.
--
-- The original portal
-- (www.interactive.electricite-strasbourg.net) no longer resolves: es.fr's "Espace client" now
-- leads to espaceclient.es.fr, which redirects to a Keycloak login
-- (`/auth/realms/espace-client-sso/...`, `form#kc-form-login` with `username`/`password`)
-- before landing on `/alice-ael/sso/login`. A wrong login answers the Keycloak page again with
-- "Veuillez vérifier votre identifiant et votre mot de passe" in `.kc-feedback-text` (checked
-- live, with made-up credentials). Nothing past the login is known yet (no account to look at
-- the new portal with), so a successful login stops with an explicit error rather than
-- guessing at the old portal's bill endpoints.

local M = {}

local LOGIN_URL = "https://espaceclient.es.fr/"
local LOGIN_FORM = "form#kc-form-login"

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
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM .. " input[name='password']") then
    error("ÉS login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { username = params.username, password = params.password })
  if has(resp, ".kc-feedback-text") or has(resp, LOGIN_FORM) then
    local feedback = fyde.html.select(resp.body, ".kc-feedback-text")[1]
    fail(INVALID_CREDENTIALS, feedback and trim(feedback.text) or "still on the login form")
  end
  return resp
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  local resp = login(params)
  error("credentials accepted (landed on " .. resp.url .. "), but the ÉS customer area's bill pages "
    .. "aren't ported yet - see this script's header comment", 0)
end

return M
