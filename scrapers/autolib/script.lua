-- Scraper for Autolib' (moncompte.autolib.eu), the former Paris electric car-sharing service:
-- downloads the paid invoices.
--
-- Login posts the page's `form`
-- (username/password) from `/account/login` with that same URL as Referer (required by the
-- site); a session shows `a[href='/account/logout/']` links. Invoices are the rows of
-- `table.table-bills` whose status is "Paid", each with a PDF link.
--
-- The service shut down in 2018 - kept for completeness, very likely
-- unreachable. Unverified (see README.md).

local M = {}

local BASE = "https://moncompte.autolib.eu"
local LOGIN_URL = BASE .. "/account/login"
local BILLS_URL = BASE .. "/account/bills"
local LOGGED_IN = "a[href='/account/logout/']"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "input[name='password']") then
    error("Autolib login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { username = params.username, password = params.password }, { Referer = LOGIN_URL })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS, "no logout link after login")
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local headers = { ["Accept-Language"] = "en-GB,en-US" }
  local page = fyde.http.get(BILLS_URL, headers)
  if has(page, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL, headers)
  end

  fyde.progress.step("downloading_documents")
  local rows = fyde.html.select(page.body, "table.table-bills tbody tr")
  for i, row in ipairs(rows) do
    local cells = fyde.html.select(row.html, "td")
    local link = fyde.html.select(row.html, "a")[1]
    if link and cells[3] and trim(cells[3].text) == "Paid" then
      local id, date = trim(cells[1].text), trim(cells[2].text)
      fyde.progress.update(i, #rows, id)
      save_pdf(absolute(BASE, link.attrs.href), sanitize(date) .. "_" .. id .. "_autolib.pdf", {
        name = "Facture Autolib " .. date,
        type = "invoice",
        category = "transport",
        subcategory = "road",
      })
    end
  end
  fyde.progress.step("done")
end

return M
