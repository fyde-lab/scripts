-- Scraper for Spartoo (spartoo.com), the shoe/fashion retailer: downloads order invoices.
--
-- Login posts `.loginContent form`
-- (email_address/password) from `/securelogin.php?from=compte`; success lands on
-- `/compte.php` with an `a.deconnect` link. Orders: the `tbody tr:not(.headingTable)` rows of
-- `/ajax/compte/compte_historique.php?type=article` (date, ..., amount), whose link's onclick
-- carries the `<param>=<order id>` used by `/facturesclient.php?...`. Unverified (see
-- README.md).

local M = {}

local BASE = "https://www.spartoo.com"
local HISTORY_URL = BASE .. "/ajax/compte/compte_historique.php?type=article"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/securelogin.php?from=compte")
  if not has(page, ".loginContent form") then
    error("Spartoo login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, ".loginContent form", { email_address = params.username, password = params.password })
  if not (has(resp, "a.deconnect") and resp.url == BASE .. "/compte.php") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if has(fyde.http.get(BASE .. "/compte.php"), "a.deconnect") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local page = fyde.http.get(HISTORY_URL)
  for _, row in ipairs(fyde.html.select(page.body, "tbody tr:not(.headingTable)")) do
    local link = fyde.html.select(row.html, "a[onclick]")[1]
    local cells = fyde.html.select(row.html, "td")
    local order = link and (link.attrs.onclick or ""):match("&([^']+)'")
    if order and cells[2] then
      local date = trim(cells[2].text)
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(BASE .. "/facturesclient.php?" .. order, (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_spartoo_" .. sanitize(trim(link.text):match("^(%S+)") or "") .. ".pdf", {
        name = "Facture Spartoo " .. date,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
