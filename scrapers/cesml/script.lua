-- Scraper for CESML (cesml.com), an electricity distributor/supplier around Montpellier:
-- meant to download the bills.
--
-- The original portal (moncompte.cesml.com) no
-- longer resolves: cesml.com's "Mon compte" now links to an eFluid customer portal at
-- moncompte-cesml.multield.net. Its login page
-- (`/application/jsp/arc/habilitation/login.jsp`) holds `form[name='theForm']` (`lg`/`psw`,
-- posted to `habilitation.ActorIdentificationAel.go` with `act=valider`, as the page's
-- `soumission('theForm', 'valider')` does); a wrong login answers that same page with
-- "Problème d'identification" (checked live, with made-up credentials). Nothing past the login
-- is known yet (no account to look at the portal's bill pages with), so a successful login
-- stops with an explicit error rather than guessing at the old portal's bill endpoints.

local M = {}

local BASE = "https://moncompte-cesml.multield.net/application/jsp/arc/habilitation"
local LOGIN_URL = BASE .. "/login.jsp"
local LOGIN_FORM = "form[name='theForm']"
local BAD_CREDENTIALS = { "Problème d'identification" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local submit_form = helpers.submit_form
local has = helpers.has

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM .. " input[name='psw']") then
    error("CESML login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { act = "valider", lg = params.username, psw = params.password })
  if contains_any(resp.body, BAD_CREDENTIALS) then
    fail(INVALID_CREDENTIALS)
  end
  if has(resp, LOGIN_FORM .. " input[name='psw']") then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  return resp
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  local resp = login(params)
  error("credentials accepted (landed on " .. resp.url .. "), but the CESML eFluid portal's bill pages "
    .. "aren't ported yet - see this script's header comment", 0)
end

return M
