-- Scraper for Auchan Drive's customer account, now part of auchan.fr: downloads order invoices.
--
-- The original auchandrive.fr site now
-- redirects to auchan.fr, where the old `/drive/client/identification` form is gone (404).
-- Rebuilt against the live site: `www.auchan.fr/client/mes-commandes` redirects a logged-out
-- visitor to a Keycloak SSO (compte.auchan.fr, realm `auchan.fr`) whose `form#kc-form-login`
-- takes `username`/`password`. The form carries a reCAPTCHA v3 field (`g-recaptcha-response`)
-- that this host can't fill; posted empty, bad credentials still get "Nom d'utilisateur ou mot
-- de passe invalide." (confirmed against the live site) - whether a correct login goes through
-- without a token is not. Success hands back to `mes-commandes?auth_callback=1`.
-- Documents: the original implementation rendered drive orders' print pages into PDFs itself; that page is gone
-- too. Not verified (no account): invoices are looked for as PDF/"facture" links on the orders
-- page (see README.md).

local M = {}

local ORIGIN = "https://www.auchan.fr"
local ORDERS_URL = ORIGIN .. "/client/mes-commandes"
local SSO_HOST = "compte.auchan.fr"
local LOGIN_FORM = "form#kc-form-login"
local BAD_CREDENTIALS = { "mot de passe invalide", "Invalid username or password" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function on_sso(page)
  return contains(page.url, SSO_HOST)
end

-- `page` is the SSO login page the orders page redirected to.
local function login(params, page)
  fyde.progress.step("Logging in")
  if not has(page, LOGIN_FORM) then
    error("Auchan login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, {
    username = params.username,
    password = params.password,
    rememberMe = "on",
  })
  if has(resp, LOGIN_FORM) or on_sso(resp) then
    if contains_any(resp.body, BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
    error("Auchan login did not complete (reCAPTCHA?) - still on " .. resp.url)
  end
  return resp
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if not on_sso(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params, page)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  local seen, count = {}, 0
  for _, link in ipairs(fyde.html.select(page.body, "a[href]")) do
    local href = link.attrs.href or ""
    local text = trim(link.text or "")
    if (href:lower():find("%.pdf") or contains_any(href .. " " .. text, { "facture", "invoice" })) and not seen[href] then
      seen[href] = true
      count = count + 1
      local label = text ~= "" and text or tostring(count)
      save_pdf(absolute(page.url, href), "auchan_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Facture Auchan " .. label,
        type = "invoice",
        category = "shopping",
        subcategory = "groceries",
      })
    end
  end
  if count == 0 then
    fyde.log.warn("no invoice link found on " .. page.url)
  end
  fyde.progress.step("Done")
end

return M
