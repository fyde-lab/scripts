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

local function login(params)
  fyde.progress.step("Logging in")
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
