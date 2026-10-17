-- Scraper for Free's internet (Freebox) customer area (adsl.free.fr): downloads the monthly
-- bills.
--
-- Credentials are posted
-- to `subscribe.free.fr/login/do_login.pl` (login/pass), which redirects to the console with
-- `?id=...&idt=...` session parameters in the URL - no redirect, or one to an `error` page or
-- to `/accesgratuit/console/console.pl`, means LOGIN_FAILED. Bills are listed by
-- `adsl.free.fr/liste-factures.pl?<same parameters>` ("Session invalide" when they expired):
-- one `.pane li` per bill with its PDF link (`...&mois=YYYYMM&no_facture=<id>`); bills before
-- 2012 have no file. The session parameters are kept in fyde.session so the next run can
-- reuse them instead of logging in again. Unverified (see README.md).

local M = {}

local LOGIN_URL = "https://subscribe.free.fr/login/do_login.pl"
local LOGIN_PAGE = "https://subscribe.free.fr/login/"
local BILLS_URL = "https://adsl.free.fr/liste-factures.pl"

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

local function bills_page()
  if not fyde.session.free_params then
    return nil
  end
  local page = fyde.http.get(BILLS_URL .. "?" .. fyde.session.free_params)
  if page.status ~= 200 or contains(page.body, "Session invalide") or not has(page, ".pane") then
    return nil
  end
  return page
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_PAGE)
  if not has(page, "input[name='pass'], input[name='login']") then
    error("Free login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(LOGIN_URL, { login = params.username, pass = params.password })
  local query = resp.url:match("%?(.*)$")
  if resp.url:find("error", 1, true) or resp.url:find("/accesgratuit/console/console.pl", 1, true)
    or resp.url:find("subscribe.free.fr/login", 1, true) or not query then
    fail(INVALID_CREDENTIALS, "redirected to " .. resp.url)
  end
  fyde.session.free_params = query
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = bills_page()
  if page then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = bills_page()
    if not page then
      error("logged in, but the bills page reports an invalid session")
    end
  end

  fyde.progress.step("Downloading bills")
  for _, item in ipairs(fyde.html.select(page.body, ".pane li")) do
    local link = fyde.html.select(item.html, "a")[1]
    local href = link and link.attrs.href or ""
    local month = href:match("mois=(%d%d%d%d%d%d)")
    local id = href:match("no_facture=([^&]+)")
    if month and tonumber(month:sub(1, 4)) > 2011 then
      save_pdf("https://adsl.free.fr/" .. href:gsub("^/", ""), month .. "_free.pdf", {
        name = "Facture Free " .. month:sub(5, 6) .. "/" .. month:sub(1, 4),
        type = "invoice",
        category = "housing",
        subcategory = "internet",
      })
    elseif id then
      fyde.log.info("bill " .. id .. " predates 2012 and has no file")
    end
  end
  fyde.progress.step("Done")
end

return M
