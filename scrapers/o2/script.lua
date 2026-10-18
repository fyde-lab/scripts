-- Scraper for O2 (o2.fr), the home-services company (cleaning, child care): downloads the
-- monthly invoices.
--
-- Login is the WordPress AJAX action
-- `ask_login` (login/pwd) on `client.o2.fr/wp-admin/admin-ajax.php`, answering JSON whose
-- `state` is "success" (anything else = bad credentials). Invoices: `/factures/` gives the
-- `#agence_id` and the years (`.year_invoice option`); the AJAX action `invoiceByYear`
-- (agenceId, year) lists them as `li a` links whose href embeds a JSON with the period's
-- `endDate`. Unverified (see README.md).

local M = {}

local BASE = "https://client.o2.fr"
local AJAX = BASE .. "/wp-admin/admin-ajax.php"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local has = helpers.has
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(BASE .. "/connexion/")
  if page.status >= 500 then
    error("O2 answered HTTP " .. page.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(AJAX, { action = "ask_login", login = params.username, pwd = params.password })
  local json = json_or_nil(trim(resp.body))
  if not json then
    error("unexpected O2 login answer (vendor down?)")
  end
  if json.state ~= "success" then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  local page = fyde.http.get(BASE .. "/factures/")
  if has(page, "#agence_id") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BASE .. "/factures/")
  end

  fyde.progress.step("downloading_documents")
  local agency = fyde.html.select(page.body, "#agence_id")[1]
  agency = agency and trim(agency.text) or ""
  for _, option in ipairs(fyde.html.select(page.body, ".year_invoice option")) do
    local list = fyde.http.post_form(AJAX, { action = "invoiceByYear", agenceId = agency, year = option.attrs.value or "" })
    for _, link in ipairs(fyde.html.select(list.body, "li a")) do
      local href = link.attrs.href or ""
      local end_date = href:match("endDate['\"]?%s*:%s*['\"](%d%d%d%d%-%d%d)")
      save_pdf(BASE .. href, (end_date or sanitize(link.text)) .. "_o2.pdf", {
        name = "Facture O2 " .. (end_date or trim(link.text)),
        type = "invoice",
        category = "housing",
        subcategory = "home_services",
      })
    end
  end
  fyde.progress.step("done")
end

return M
