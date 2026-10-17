-- Scraper for Mediapart (mediapart.fr), the online newspaper: downloads the subscription
-- invoices.
--
-- Login posts `#logFormEl`
-- (name/password) from `www.mediapart.fr/login`; logged in shows an `a[href='/logout']` link.
-- Invoices: the `.billing__list__item` entries of `moncompte.mediapart.fr` with a
-- `/facture/<id>/telecharger` link, a "Du dd/mm/yyyy au dd/mm/yyyy" period and an amount.
-- Unverified (see README.md).

local M = {}

local ACCOUNT_URL = "https://moncompte.mediapart.fr/"

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get("https://www.mediapart.fr/login")
  if not has(page, "#logFormEl") then
    error("Mediapart login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#logFormEl", { name = params.username, password = params.password })
  if not has(resp, "a[href='/logout']") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ACCOUNT_URL)
  if has(page, ".billing__list__item, a[href='/logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ACCOUNT_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, item in ipairs(fyde.html.select(page.body, ".billing__list__item")) do
    local id = item.html:match('href="/facture/(%d*)/telecharger"')
    if id then
      local s1, s2, s3, e1, e2, e3 = item.text:match("Du (%d%d)/(%d%d)/(%d%d%d%d) au (%d%d)/(%d%d)/(%d%d%d%d)")
      local start_date = s1 and (s3 .. "-" .. s2 .. "-" .. s1) or "?"
      local end_date = e1 and (e3 .. "-" .. e2 .. "-" .. e1) or "?"
      save_pdf("https://moncompte.mediapart.fr/facture/" .. id .. "/telecharger", "Facture Mediapart du " .. start_date .. " au " .. end_date .. " (" .. id .. ").pdf", {
        name = "Facture Mediapart " .. start_date .. " - " .. end_date,
        type = "invoice",
        category = "subscriptions",
        subcategory = "media",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
