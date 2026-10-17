-- Scraper for GEG (Gaz Électricité de Grenoble): meant to download the bills.
--
-- The original online agency (monagence.geg.fr) no
-- longer resolves: geg.fr's espace client now links to mon-espace.geg.fr, an SAP BTP app. Its
-- index page is a JS stub that sets a few cookies and sends the browser (`location="..."`) to
-- an XSUAA authorize URL on geg-fournisseur-prd.authentication.eu10.hana.ondemand.com, whose
-- login page only offers one identity provider (`a.saml-login-link`, to
-- authentification-sap.geg.fr - SAP Identity Authentication). That one shows
-- `form#logOnForm` (`j_username`/`j_password`); a wrong login answers the same form again with
-- "Sorry, we could not authenticate you" (checked live, with made-up credentials). Nothing past
-- the login is known yet (no account to look at the portal with), so a successful login stops
-- with an explicit error rather than guessing at the old agency's bill endpoints.

local M = {}

local PORTAL_URL = "https://mon-espace.geg.fr/"
local LOGIN_FORM = "form#logOnForm"

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
local sanitize = helpers.sanitize
local absolute = helpers.absolute
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

-- Follows mon-espace.geg.fr's JS redirect and the XSUAA page's identity-provider link down to
-- the SAP Identity Authentication login page.
local function login_page()
  local stub = fyde.http.get(PORTAL_URL)
  local authorize = stub.body:match('location="(https://[^"]+)"')
  if not authorize then
    return stub
  end
  local xsuaa = fyde.http.get(authorize)
  local idp = fyde.html.select(xsuaa.body, "a.saml-login-link")[1]
  if not idp or not idp.attrs.href then
    return xsuaa
  end
  return fyde.http.get(absolute(xsuaa.url, idp.attrs.href))
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = login_page()
  if not has(page, LOGIN_FORM .. " input[name='j_password']") then
    error("GEG login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { j_username = params.username, j_password = params.password })
  if has(resp, LOGIN_FORM .. " input[name='j_password']") then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  return resp
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  local resp = login(params)
  error("credentials accepted (landed on " .. resp.url .. "), but the GEG customer area's bill pages "
    .. "aren't ported yet - see this script's header comment", 0)
end

return M
