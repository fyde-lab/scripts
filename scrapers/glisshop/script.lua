-- Scraper for Glisshop (glisshop.com), a ski/board-sports retailer: downloads order invoices.
--
-- Login posts `form[role="form"]`
-- (`account[mail]`/`account[pass]`) from `/connexion/`; logged in shows a "Déconnexion"
-- `a[href='https://www.glisshop.com/customers/logout/']`. Orders: the `div.panel.panel-default`
-- blocks of `/mon_compte/mes_commandes/` (`div.order-label` with number and date,
-- `.order-amount`, invoice in `a.btn-enabled`). Unverified (see README.md).

local M = {}

local BASE = "https://www.glisshop.com"
local ORDERS_URL = BASE .. "/mon_compte/mes_commandes/"
local LOGGED_IN = "a[href='https://www.glisshop.com/customers/logout/']"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/connexion/")
  if not has(page, "form[role='form']") then
    error("Glisshop login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form[role='form']", { ["account[mail]"] = params.username, ["account[pass]"] = params.password })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if has(page, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, panel in ipairs(fyde.html.select(page.body, "div.panel.panel-default")) do
    local link = fyde.html.select(panel.html, "a.btn-enabled")[1]
    local label = fyde.html.select(panel.html, "div.order-label")[1]
    if link and link.attrs.href then
      local text = label and label.text or ""
      local date = text:match("(%d+/%d+/%d%d%d%d)") or ""
      local number = text:match("(%d%d%d%d%d+)") or "commande"
      save_pdf(absolute(BASE, link.attrs.href), sanitize(date) .. "_" .. number .. "_glisshop.pdf", {
        name = "Facture Glisshop " .. date,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
