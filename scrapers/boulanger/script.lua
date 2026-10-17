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
local fail = helpers.fail
local contains = helpers.contains
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has

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

local function is_logged_in(page)
  return page.status == 200 and not has(page, "div.mp.login") and not has(page, LOGIN_FORM)
    and (has(page, ".order-merchant") or contains(page.body, "Vous n'avez pas r\195\169alis\195\169 d'achat"))
end

local function login(params)
  fyde.progress.step("Logging in")
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
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if is_logged_in(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
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
  fyde.progress.step("Done")
end

return M
