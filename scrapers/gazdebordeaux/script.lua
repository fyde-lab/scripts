-- Scraper for Gaz de Bordeaux's customer area (espaceclient.gazdebordeaux.fr): downloads the
-- gas/electricity bills.
--
-- Login posts `form#loginForm`
-- (username/password/rememberMe=N/submitButton) from `/login`; logged in shows an
-- `a[href='/logout']` link; "Aucun compte ne correspond à l'identifiant et au mot de passe
-- fournis" (or a "Ce champ est obligatoire" field error) means bad credentials. Bills: the
-- `form#BillsForm div.grid-item` blocks of `/invoice` (`span.invoice-code` date,
-- `span.invoice-price`, `ul.plan-features li:first-child` reference, `a.btn-info` PDF).
-- Unverified (see README.md).

local M = {}

local BASE = "https://espaceclient.gazdebordeaux.fr"

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
  fyde.progress.step("logging_in")
  local page = fyde.http.get(BASE .. "/login")
  if not has(page, "form#loginForm") then
    error("Gaz de Bordeaux login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form#loginForm", {
    username = params.username,
    password = params.password,
    rememberMe = "N",
    submitButton = "Se connecter",
  })
  if not has(resp, "a[href='/logout']") then
    fail(INVALID_CREDENTIALS, contains(resp.body, "Aucun compte ne correspond") and "no matching account" or nil)
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local page = fyde.http.get(BASE .. "/invoice")
  if has(page, "a[href='/logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BASE .. "/invoice")
  end

  fyde.progress.step("downloading_documents")
  for _, item in ipairs(fyde.html.select(page.body, "form#BillsForm div.grid-item")) do
    local link = fyde.html.select(item.html, "a.btn-info")[1]
    local date = fyde.html.select(item.html, "span.invoice-code")[1]
    local ref = fyde.html.select(item.html, "ul.plan-features li:first-child")[1]
    if link and link.attrs.href then
      date = date and trim(date.text) or ""
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(BASE .. link.attrs.href, (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_gaz_de_bordeaux_facture_" .. sanitize(ref and ref.text or "") .. ".pdf", {
        name = "Facture Gaz de Bordeaux " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  fyde.progress.step("done")
end

return M
