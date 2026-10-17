-- Scraper for Uber's rider account (riders.uber.com): downloads the trip invoices.
--
-- Based on a 2017-era implementation:
-- `login.uber.com/login` gives the `_csrf_token`, then email/password/_csrf_token are posted
-- back to it (an HTTP error meant LOGIN_FAILED); trips are listed on `riders.uber.com/trips`
-- (`tbody .trip-expand__origin[data-target="#trip-<uuid>"]`, `a.btn.pagination__next` for
-- the next page) and each trip's invoice comes from `get_invoices?q={"trip_uuid":"<uuid>"}`
-- (`document_path` under `/invoice-gen`). Uber's login has long been replaced by
-- auth.uber.com (a JS app with phone/e-mail codes), so this flow is almost certainly
-- outdated; the login failure detection also checks that the login form is gone. Unverified
-- (see README.md).

local M = {}

local LOGIN_URL = "https://login.uber.com/login"
local TRIPS_URL = "https://riders.uber.com/trips"

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
local trim = helpers.trim
local sanitize = helpers.sanitize

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  local token = fyde.html.select(page.body, "input[name='_csrf_token']")[1]
  if not token then
    error("Uber login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(LOGIN_URL, { email = params.username, password = params.password, _csrf_token = token.attrs.value or "" })
  if resp.status >= 400 or has(resp, "input[name='_csrf_token'][value]") and has(resp, "input[name='password']") then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(TRIPS_URL)
  if has(page, "tbody .trip-expand__origin") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(TRIPS_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _ = 1, 100 do
    for _, origin in ipairs(fyde.html.select(page.body, "tbody .trip-expand__origin")) do
      local uuid = (origin.attrs["data-target"] or ""):gsub("^#trip%-", "")
      local invoices = json_or_nil(fyde.http.get(TRIPS_URL:gsub("/trips$", "") .. '/get_invoices?q={"trip_uuid":"' .. uuid .. '"}').body)
      if type(invoices) == "table" and invoices[1] and invoices[1].document_path then
        local date = tostring(invoices[1].invoice_date or ""):sub(1, 10)
        save_pdf("https://riders.uber.com/invoice-gen" .. invoices[1].document_path, date .. "_uber_" .. uuid .. ".pdf", {
          name = "Facture Uber " .. date,
          type = "invoice",
          category = "transport",
          subcategory = "ride",
        })
      end
    end
    local next_link = fyde.html.select(page.body, "a.btn.pagination__next")[1]
    if not (next_link and next_link.attrs.href) then
      break
    end
    page = fyde.http.get(TRIPS_URL .. next_link.attrs.href)
  end
  fyde.progress.step("Done")
end

return M
