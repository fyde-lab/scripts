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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function history()
  local resp = fyde.http.get(HISTORY)
  local data = json_or_nil(resp.body)
  return data and data.data
end

local function login(params)
  fyde.progress.step("logging_in")
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
  fyde.progress.step("checking_session")
  local rows = history()
  if rows then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    rows = history() or {}
  end

  fyde.progress.step("downloading_documents")
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
  fyde.progress.step("done")
end

return M
