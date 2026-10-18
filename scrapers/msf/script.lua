-- Scraper for Médecins Sans Frontières' donor area (don.msf.fr): downloads the tax receipts
-- ("reçus fiscaux") of donations.
--
-- Login posts the page's `form`
-- (email/password) from `/donateur/index.php`; logged in shows an
-- `a[href='/donateur/deconnexion.php']` link. Donations: POST anneeDon=tous/typeDon=tous to
-- `/donateur/historic.php?ent_codsoc=ASSO`, one `#bloc_central table table table` per year
-- with "DON" rows and, when available, a receipt link whose page redirects (inline script) to a
-- page holding `#lien_download`. Unverified (see README.md).

local M = {}

local BASE = "https://don.msf.fr"
local LOGGED_IN = "a[href='/donateur/deconnexion.php']"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
  local page = fyde.http.get(BASE .. "/donateur/index.php")
  if not has(page, "input[name='password']") then
    error("MSF login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { email = params.username, password = params.password })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if has(fyde.http.get(BASE .. "/donateur/index.php"), LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  local page = fyde.http.post_form(BASE .. "/donateur/historic.php?ent_codsoc=ASSO", { anneeDon = "tous", typeDon = "tous" })
  for _, tbl in ipairs(fyde.html.select(page.body, "#bloc_central table table table")) do
    local link = fyde.html.select(tbl.html, "tr td a")[1]
    if link and link.attrs.href then
      local redirect = fyde.http.get(BASE .. link.attrs.href)
      local target = redirect.body:match('<script[^>]*>[^"]*"([^"]+)"')
      local final = target and fyde.http.get(BASE .. "/donateur/" .. target)
      local download = final and fyde.html.select(final.body, "#lien_download")[1]
      if download and download.attrs.href then
        save_pdf(BASE .. "/donateur/" .. download.attrs.href, sanitize(link.text) .. ".pdf", {
          name = "Reçu fiscal MSF " .. trim(link.text),
          type = "tax_certificate",
          category = "donations",
        })
      end
    end
  end
  fyde.progress.step("done")
end

return M
