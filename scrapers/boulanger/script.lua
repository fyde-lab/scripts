-- Scraper for Boulanger (boulanger.com), the electronics/home-appliance retailer: downloads
-- order invoices.
--
-- Login posts
-- `form[name="BLAuthenticationForm"]` (`email.value`/`password.value`) from the
-- `/authentication?action=logon...` page; it failed (LOGIN_FAILED) when the login block
-- `div.mp.login` is still shown. Orders come from `BLAccountOrdersHistoryCmd?purchase=allYear`:
-- each `.order-merchant` block has a `.verifyCredentials` link (`data-modal-url`, rewritten from
-- DisplayStoreSequencesFacturePDF to DisplayStoreFacturePDF + `&sequence=001`, or `href`).
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.boulanger.com"
local SERVLET = BASE .. "/webapp/wcs/stores/servlet/"
local LOGIN_URL = BASE .. "/authentication?action=logon&catalogId=10001&storeId=10001&langId=-2"
local ORDERS_URL = SERVLET .. "BLAccountOrdersHistoryCmd?purchase=allYear&store=store-site"
local LOGIN_FORM = "form[name='BLAuthenticationForm']"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function is_logged_in(page)
  return page.status == 200 and not has(page, "div.mp.login") and not has(page, LOGIN_FORM)
    and (has(page, ".order-merchant") or contains(page.body, "Vous n'avez pas r\195\169alis\195\169 d'achat"))
end

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM) then
    error("Boulanger login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { ["email.value"] = params.username, ["password.value"] = params.password })
  if has(resp, "div.mp.login") then
    fail(INVALID_CREDENTIALS, "login block still shown")
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local page = fyde.http.get(ORDERS_URL)
  if is_logged_in(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("downloading_documents")
  for _, order in ipairs(fyde.html.select(page.body, ".order-merchant")) do
    local link = fyde.html.select(order.html, ".verifyCredentials")[1]
    if link then
      local url
      if link.attrs["data-modal-url"] then
        url = SERVLET .. link.attrs["data-modal-url"]:gsub("DisplayStoreSequencesFacturePDF", "DisplayStoreFacturePDF") .. "&sequence=001"
      elseif link.attrs.href then
        url = SERVLET .. link.attrs.href
      end
      local ref = fyde.html.select(order.html, ".number > b")[1]
      local infos = fyde.html.select(order.html, ".order-head > .infos-purchase b")
      local date = infos[1] and trim(infos[1].text) or ""
      local amount = infos[2] and trim(infos[2].text):gsub("%s", "") or ""
      if url then
        save_pdf(url, sanitize(date) .. "_" .. amount .. "_" .. (ref and trim(ref.text) or "") .. ".pdf", {
          name = "Facture Boulanger " .. date,
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      end
    end
  end
  fyde.progress.step("done")
end

return M
