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
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize(name)
  name = trim((name or ""):gsub("%s+", " "))
  name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

-- Asks the user for a one-time code through fyde.input.ask; an unanswered/empty prompt (or no
-- input handler at all, e.g. an unattended run) is an MFA failure.
local function ask_code(question)
  local ok, code = pcall(fyde.input.ask, question)
  if not ok or type(code) ~= "string" or trim(code) == "" then
    fail(MFA_FAILED, "no one-time code was provided")
  end
  return (code:gsub("%s", ""))
end

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

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
