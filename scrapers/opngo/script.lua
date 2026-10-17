-- Scraper for OPnGO (opngo.com), the parking app: downloads the invoices of paid parking
-- sessions.
--
-- `now.opngo.com/AppHTTP.php` with
-- operation=login_session_begin (userID, authToken = password, format=json, version 2.7, ...)
-- answers `status: 1` on success (anything else = bad credentials). Sessions:
-- `now.opngo.com/?page=history&start=01/01/2000&fmt=ajax&language=fr` (`data[]` rows of
-- rowType "sessionRow" with a non-zero totalCharge); each invoice comes from AppHTTP.php with
-- operation=invoice_check and data=<txID>. The original implementation POSTed that call; fyde.http only
-- downloads with GET, so its fields go in the query string (unconfirmed). Unverified (see
-- README.md).

local M = {}

local APP = "https://now.opngo.com/AppHTTP.php"
local HISTORY = "https://now.opngo.com/?page=history&start=01/01/2000&fmt=ajax&language=fr"

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

local function history()
  local resp = fyde.http.get(HISTORY)
  local data = json_or_nil(resp.body)
  return data and data.data
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get("https://www.opngo.com")
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(APP, {
    authToken = params.password,
    format = "json",
    language = "fr",
    operation = "login_session_begin",
    usageMethod = "Web",
    userID = params.username,
    version = "2.7",
  })
  local data = json_or_nil(resp.body) or {}
  if data.status ~= 1 then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local rows = history()
  if rows then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    rows = history() or {}
  end

  fyde.progress.step("Downloading invoices")
  for _, row in ipairs(rows) do
    if row.rowType == "sessionRow" and (tonumber(row.totalCharge) or 0) ~= 0 then
      save_pdf(APP .. "?data=" .. tostring(row.txID) .. "&format=json&initWith=session&language=fr&operation=invoice_check&usageMethod=Web&version=2.7",
        "OPnGO-" .. tostring(row.txID) .. "-" .. tostring(row.totalCharge) .. "EUR.pdf", {
          name = "Facture OPnGO " .. tostring(row.info or row.txID),
          type = "invoice",
          category = "transport",
          subcategory = "road",
        })
    end
  end
  fyde.progress.step("Done")
end

return M
