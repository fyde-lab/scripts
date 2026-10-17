-- Scraper for Mint Énergie's customer area (mint-energie.com): downloads the bills.
--
-- An ASP.NET login posting the
-- page's `form` (TB_Login/TB_Password/BT_Connexion) from `/Pages/Connexion/connexion.aspx`;
-- logged in shows `#header1_LB_Exit`. Bills: the `.factulist` entries of
-- `/Pages/Compte/informations_paiement.aspx` (`div.colA b` date, `div.colB b` amount,
-- `div.colC a` PDF). Unverified (see README.md).

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
    error("Mint Énergie login form not found on " .. page.url)
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
      save_pdf(absolute(BILLS_URL, link.attrs.href), (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_mint-energie_" .. sanitize(amount and amount.text or "") .. ".pdf", {
        name = "Facture Mint Énergie " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  fyde.progress.step("done")
end

return M
