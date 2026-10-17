-- Scraper for Eau du Grand Lyon's online agency (agence.eaudugrandlyon.com), the Lyon water
-- utility: downloads the water bills.
--
-- Login posts the page's
-- `form` (login/pass/connect=OK) from `/default.aspx`; "Identifiant ou mot de passe invalide"
-- in the answer means bad credentials. Bills: the table rows of
-- `/mon-espace-compte-consulter-facture.aspx` (date, reference, amount, ..., PDF link in the
-- 5th cell). Unverified (see README.md).

local M = {}

local BASE = "https://agence.eaudugrandlyon.com"
local LOGIN_URL = BASE .. "/default.aspx"
local BILLS_URL = BASE .. "/mon-espace-compte-consulter-facture.aspx"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "input[name='pass'], input[name='login']") then
    error("Eau du Grand Lyon login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { login = params.username, pass = params.password, connect = "OK" })
  if contains(resp.body, "Identifiant ou mot de passe invalide") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "tr td a[href]") and not has(page, "input[name='pass']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("Downloading bills")
  for _, row in ipairs(fyde.html.select(page.body, "tr")) do
    local cells = fyde.html.select(row.html, "td")
    local link = cells[5] and fyde.html.select(cells[5].html, "a")[1]
    local amount = cells[3] and tonumber((trim(cells[3].text):gsub(",", ".")))
    if link and link.attrs.href and amount then
      local date, ref = trim(cells[1].text), trim(cells[2].text)
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(BASE .. "/" .. link.attrs.href:gsub("^/", ""), (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_eaudugrandlyon_" .. string.format("%.2f", amount) .. "EUR_" .. ref .. ".pdf", {
        name = "Facture Eau du Grand Lyon " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "water",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
