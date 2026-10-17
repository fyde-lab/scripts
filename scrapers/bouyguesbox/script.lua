-- Scraper for Bouygues Telecom's customer area (bouyguestelecom.fr), legacy "box" area:
-- downloads the bills of every billing account through api.bouyguestelecom.fr.
--
-- Login posts the
-- CAS form of `www.mon-compte.bouyguestelecom.fr/cas/login` (username/password/lastname) -
-- "Votre identifiant ou votre mot de passe est incorrect" means bad credentials. Then the OAuth2
-- implicit flow `oauth2.bouyguestelecom.fr/authorize?client_id=a360.bouyguestelecom.fr&
-- response_type=id_token token` redirects to `www.bouyguestelecom.fr/mon-compte/` with
-- `access_token=...&...id_token=<JWT>` (the JWT's `id_personne` is the user id); staying on
-- oauth2.bouyguestelecom.fr means the login didn't stick. Bills: `/personnes/<id>` ->
-- `_links.factures.href` -> `comptesFacturation[].factures[]`, each with a
-- `_links.facturePDF` (or `facturePDFDF`) resource whose `_actions.telecharger.action` is the
-- PDF. The access token isn't a cookie, so a session is only "restored" when the CAS cookie
-- still gets a token without re-posting credentials. See also `bouyguestelecom`, the newer
-- browser-based port of the same site. Unverified (see README.md).

local M = {}

local API = "https://api.bouyguestelecom.fr"
local CAS_URL = "https://www.mon-compte.bouyguestelecom.fr/cas/login"
local AUTHORIZE_URL = "https://oauth2.bouyguestelecom.fr/authorize?client_id=a360.bouyguestelecom.fr"
  .. "&response_type=id_token%20token&redirect_uri=https%3A%2F%2Fwww.bouyguestelecom.fr%2Fmon-compte%2F"

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
local contains = helpers.contains
local sanitize = helpers.sanitize
local base64url_decode = helpers.base64url_decode
local submit_form = helpers.submit_form

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

-- Follows the implicit OAuth2 flow; returns (access_token, id_personne) or nil.
local function get_token()
  local resp = fyde.http.get(AUTHORIZE_URL)
  local token = resp.url:match("access_token=([^&]+)")
  local jwt = resp.url:match("id_token=([^&]+)")
  if not token or not jwt then
    return nil
  end
  local claims = json_or_nil(base64url_decode(jwt:match("^[^.]+%.([^.]+)") or "")) or {}
  return token, claims.id_personne
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(CAS_URL)
  if not has(page, "input[name='password']") then
    error("Bouygues Telecom CAS login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { username = params.username, password = params.password, lastname = params.lastname or "" })
  if contains(resp.body, "Votre identifiant ou votre mot de passe est incorrect") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local token, user = get_token()
  if token then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    token, user = get_token()
    if not token then
      error("logged in, but no OAuth2 token was issued (the account may need its last name: LOGIN_FAILED.NEEDS_SECRET)")
    end
  end
  local auth = { Authorization = "Bearer " .. token }
  local function api(path)
    return json_or_nil(fyde.http.get(API .. path, auth).body) or {}
  end

  fyde.progress.step("Downloading bills")
  local person = api("/personnes/" .. tostring(user))
  local accounts = api(person._links and person._links.factures and person._links.factures.href or "/")
  for _, account in ipairs(accounts.comptesFacturation or {}) do
    for _, bill in ipairs(account.factures or {}) do
      local link = bill._links and (bill._links.facturePDF or bill._links.facturePDFDF)
      if bill.soldeFacturePrec ~= nil and link then
        local pdf = api(link.href)
        local action = pdf._actions and pdf._actions.telecharger and pdf._actions.telecharger.action
        if action then
          local date = tostring(bill.dateFacturation):sub(1, 10)
          save_pdf(API .. action, date:gsub("-", ""):sub(1, 6) .. "_bouygues_" .. tostring(bill.mntTotFacture) .. "EUR_" .. tostring(bill.idFacture) .. ".pdf", {
            name = "Facture Bouygues Telecom " .. date,
            type = "invoice",
            category = "housing",
            subcategory = "internet",
          }, auth)
        end
      end
    end
  end
  fyde.progress.step("Done")
end

return M
