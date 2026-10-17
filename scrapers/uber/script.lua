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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local has = helpers.has
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

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
