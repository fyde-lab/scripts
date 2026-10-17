-- Scraper for MAIF (maif.fr), the mutual insurer: meant to save the member's documents.
--
-- The original implementation had no login form: it
-- called MAIF's open API (openapiweb.maif.fr) with an OAuth token
-- obtained through an OAuth flow. That host no longer resolves, so this script now logs in
-- the way a member does, on MAIF's own login (connect.maif.fr/connect/oic/login), in two steps
-- on the same `form#loginForm`: the identifier first (`username` - an email or a member number),
-- then, on the page that comes back, the `password`. A wrong login answers that second page
-- again with "Identifiant ou mot de passe invalide" (checked live, with made-up credentials).
-- Nothing past the login is known yet (no account to look at the personal space with), so a
-- successful login stops with an explicit error rather than guessing at the documents pages.

local M = {}

local LOGIN_URL = "https://connect.maif.fr/connect/oic/login"
local LOGIN_FORM = "form#loginForm"
local BAD_CREDENTIALS = { "mot de passe invalide" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local submit_form = helpers.submit_form
local has = helpers.has

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM .. " input[name='username']") then
    error("MAIF login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  page = submit_form(page, LOGIN_FORM, { username = params.username })
  if not has(page, LOGIN_FORM .. " input[name='password']") then
    fail(INVALID_CREDENTIALS, "identifier not accepted (no password step)")
  end
  local resp = submit_form(page, LOGIN_FORM, { password = params.password })
  if contains_any(resp.body, BAD_CREDENTIALS) or has(resp, LOGIN_FORM .. " input[name='password']") then
    fail(INVALID_CREDENTIALS)
  end
  return resp
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  local resp = login(params)
  error("credentials accepted (landed on " .. resp.url .. "), but the MAIF personal space's documents "
    .. "pages aren't ported yet - see this script's header comment", 0)
end

return M
