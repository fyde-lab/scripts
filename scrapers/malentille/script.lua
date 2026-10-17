-- Scraper for Malentille (malentille.com, Digital Eyewear), an online contact-lens shop:
-- downloads order invoices.
--
-- A PrestaShop login - GET
-- `/authentification?back=my-account`, then POST `/authentification` (back=history, email,
-- passwd, SubmitLogin). The original implementation never checked the outcome; here PrestaShop's own signals
-- are used: an "Authentication failed"/"Échec d'authentification" error or the login form
-- still shown means bad credentials, the order history (`#block-history`) a valid session.
-- Invoices: `#block-history tbody tr` rows of `/historique-des-commandes` (`.history_date`,
-- `.history_price`, `.history_invoice a`). Unverified (see README.md).

local M = {}

local BASE = "https://www.malentille.com/"
local HISTORY_URL = BASE .. "historique-des-commandes"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "authentification?back=my-account")
  if not has(page, "input[name='passwd']") then
    error("Malentille login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(BASE .. "authentification", {
    back = "history",
    email = params.username,
    passwd = params.password,
    SubmitLogin = "Identifiez-vous",
  })
  if contains_any(resp.body, { "chec d'authentification", "Authentication failed", "Mot de passe invalide" })
    or (has(resp, "input[name='passwd']") and not has(resp, "#block-history")) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(HISTORY_URL)
  if has(page, "#block-history") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(HISTORY_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, row in ipairs(fyde.html.select(page.body, "#block-history tbody tr")) do
    local link = fyde.html.select(row.html, ".history_invoice a")[1]
    local date = fyde.html.select(row.html, ".history_date")[1]
    if link and link.attrs.href then
      date = date and trim(date.text) or ""
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      local number = link.text:match("%d+") or "facture"
      save_pdf(absolute(BASE, link.attrs.href), "Digital Eyewear_facture_" .. (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_n_" .. number .. ".pdf", {
        name = "Facture Malentille " .. date,
        type = "invoice",
        category = "health",
        subcategory = "care",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
