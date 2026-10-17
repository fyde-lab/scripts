-- Scraper for Planète OUI's customer area, now Mint Énergie's (client.mint-energie.com):
-- downloads the electricity/gas bills.
--
-- The original planete-oui.fr customer area
-- (`/Espace-Client/Connexion`, `/Espace-Client/Mes-Factures`) is gone: every planete-oui.fr page
-- now redirects to mint-energie.com, Planète OUI's customers having moved to Mint Énergie. So this
-- now uses the same flow as `scrapers/mint-energie` (whose bad-credentials answer is confirmed
-- against the live site): the ASP.NET `Pages/Connexion/connexion.aspx` form (`TB_Login`/
-- `TB_Password`), a session shown by the `#header1_LB_Exit` logout link, bills listed as
-- `.factulist` entries on `Pages/Compte/informations_paiement.aspx`. Successful login and bills
-- not verified (no account, see README.md).

local M = {}

local BASE = "https://www.mint-energie.com"
local BILLS_URL = BASE .. "/Pages/Compte/informations_paiement.aspx"

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
  local page = fyde.http.get(BASE .. "/Pages/Connexion/connexion.aspx")
  if not has(page, "input[name='TB_Password'], input[id$='TB_Password']") then
    error("Mint Énergie (ex-Planète OUI) login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { TB_Login = params.username, TB_Password = params.password, BT_Connexion = "se connecter" })
  if not has(resp, "#header1_LB_Exit") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "#header1_LB_Exit") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("downloading_documents")
  for _, bill in ipairs(fyde.html.select(page.body, ".factulist")) do
    local link = fyde.html.select(bill.html, "div.colC a")[1]
    local date = fyde.html.select(bill.html, "div.colA b")[1]
    local amount = fyde.html.select(bill.html, "div.colB b")[1]
    if link and link.attrs.href then
      date = date and trim(date.text) or ""
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(absolute(BILLS_URL, link.attrs.href), (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_planete-oui-mint_" .. sanitize(amount and amount.text or "") .. ".pdf", {
        name = "Facture Mint Énergie (ex-Planète OUI) " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  fyde.progress.step("done")
end

return M
