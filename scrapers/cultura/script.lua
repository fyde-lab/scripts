-- Scraper for Cultura (cultura.com), the culture/leisure retailer: downloads order invoices.
--
-- A Magento login - `#login-form`
-- (`login[username]`/`login[password]`) on `/customer/account/`; logged in shows a
-- `.disconnect` link, errors are in `.account-login .error-msg`. Orders: the
-- `#my-orders-table .action-link` links of `/sales/order/history`; each order page has its
-- date and number in `.title-buttons li:first-child` ("Date de la commande <d> <mois> <yyyy>,
-- n°<id>"), its total in `.total-row` and the invoice in `#my-orders-table .table-link`.
-- Cultura's site has since been rebuilt, so this may be outdated. Unverified (see README.md).

local M = {}

local BASE = "https://www.cultura.com"
local ACCOUNT_URL = BASE .. "/customer/account/"

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
  local page = fyde.http.get(ACCOUNT_URL)
  if not has(page, "#login-form") then
    error("Cultura login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#login-form", { ["login[username]"] = params.username, ["login[password]"] = params.password })
  if not has(resp, ".disconnect") then
    local err = fyde.html.select(resp.body, ".account-login .error-msg")[1]
    fail(INVALID_CREDENTIALS, err and trim(err.text))
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if has(fyde.http.get(ACCOUNT_URL), ".disconnect") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  local history = fyde.http.get(BASE .. "/sales/order/history")
  for _, link in ipairs(fyde.html.select(history.body, "#my-orders-table .action-link")) do
    local order = fyde.http.get(absolute(BASE, link.attrs.href))
    local title = fyde.html.select(order.body, ".title-buttons li:first-child")[1]
    local invoice = fyde.html.select(order.body, "#my-orders-table .table-link")[1]
    if invoice and invoice.attrs.href then
      local text = title and trim(title.text) or ""
      local date = text:match("commande%s+(.-),") or ""
      local number = text:match("n\194\176%s*(%S+)") or "commande"
      save_pdf(absolute(BASE, invoice.attrs.href), sanitize(date) .. "_" .. number .. "_cultura.pdf", {
        name = "Facture Cultura " .. date,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("done")
end

return M
