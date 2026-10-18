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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local submit_form = helpers.submit_form
local has = helpers.has

local function login(params)
  fyde.progress.step("logging_in")
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
