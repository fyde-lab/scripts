-- Scraper for ekWateur's customer area (mon-espace.ekwateur.fr), a green energy supplier:
-- downloads the bills and the proof of residence ("justificatif de domicile").
--
-- A Symfony login - `/se_connecter`
-- gives `_csrf_token`, then `/login_check` takes _username/_password/_mode=cXI4cE93PT0 (the
-- original implementation's own comment: "Why ? I don't know") and _csrf_token; the original implementation treated an HTTP
-- 500 as bad credentials (the login form being shown again is checked too). Bills: the rows
-- of `/mes_factures_et_acomptes` (date in the first cell, `td.table__body__price`, PDF in
-- `td.table__body__file > a`). The proof of residence is `/client/justificatif_de_domicile`.
-- Unverified (see README.md).

local M = {}

local BASE = "https://mon-espace.ekwateur.fr"
local LOGIN_URL = BASE .. "/se_connecter"
local BILLS_URL = BASE .. "/mes_factures_et_acomptes"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(LOGIN_URL)
  local csrf = fyde.html.select(page.body, "input[name='_csrf_token']")[1]
  if not csrf then
    error("ekWateur login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(BASE .. "/login_check", {
    _username = params.username,
    _password = params.password,
    _mode = "cXI4cE93PT0",
    _csrf_token = csrf.attrs.value or "",
  })
  if resp.status == 500 or has(resp, "input[name='_password']") then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "td.table__body__file, a[href*='deconnexion'], a[href*='logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    fyde.http.get(BASE)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("downloading_documents")
  for _, row in ipairs(fyde.html.select(page.body, "tr")) do
    local link = fyde.html.select(row.html, "td.table__body__file > a")[1]
    local cells = fyde.html.select(row.html, "td")
    if link and link.attrs.href then
      local date = trim(cells[1].text)
      save_pdf(BASE .. trim(link.attrs.href), sanitize(date) .. "_ekwateur.pdf", {
        name = "Facture ekWateur " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  save_pdf(BASE .. "/client/justificatif_de_domicile", "attestation de contrat (justificatif de domicile).pdf", {
    name = "Justificatif de domicile ekWateur",
    type = "proof_of_residence",
    category = "housing",
    subcategory = "energy",
  })
  fyde.progress.step("done")
end

return M
