-- Scraper for TotalEnergies' customer area (totalenergies.fr, ex Direct Énergie): downloads the
-- electricity/gas bills and the contract.
--
-- Drives `fyde.browser`: `/clients/accueil` shows either a
-- logged-in page (logout link `a[href*="/clients/connexion?logintype=logout"]` or
-- `a[href="/clients/mon-compte/gerer-mes-comptes"]`) or the login form
-- (`#formz-authentification-form-login`, `#formz-authentification-form-password`,
-- `#js--btn-validation`); a maintenance page (maintenance.direct-energie.com) means the vendor
-- is down. Bills: `/clients/mes-factures/mon-historique-de-factures`, one `div.detail-facture`
-- per bill in `#js--historique-container-elec` / `#js--historique-container-gaz`, and the
-- contract's `a[href*="/telechargement-des-contrats"]`; all downloaded through the browser.
-- Accounts with several contracts only get the selected one (the original implementation looped over
-- `[id*="js--listjs-comptes-"]`). Unverified (see README.md).

local M = {}

local BASE = "https://www.totalenergies.fr"
local HOME_URL = BASE .. "/clients/accueil"
local BILLS_URL = BASE .. "/clients/mes-factures/mon-historique-de-factures"
local LOGIN = "#formz-authentification-form-login"
local PASSWORD = "#formz-authentification-form-password"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "identifiants sont incorrects", "incorrect" }

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
local contains_any = helpers.contains_any
local sanitize = helpers.sanitize
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait

local function click_first(selectors)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:click(selector)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

-- Clicks `selector` (a download link/button) and saves what the browser downloads.
local function browser_save(selector, filename, fields)
  local ok, bytes = pcall(function()
    return fyde.browser:download(selector, 60000)
  end)
  if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
    fyde.save_document(sanitize(filename), bytes, fields)
    return true
  end
  fyde.log.warn("could not download " .. filename .. ": " .. tostring(ok and "not a PDF" or bytes))
  return false
end
-- luacheck: pop

local LOGGED_IN = { "logged_in", selector = "a[href*='/clients/connexion?logintype=logout'], a[href='/clients/mon-compte/gerer-mes-comptes']" }

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN) then
    error("TotalEnergies login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(LOGIN, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  fyde.browser:click("#js--btn-validation")
  local state = wait_state({ LOGGED_IN, { "bad", selector = ".formz-error, .alert-danger, .message-erreur" } }, 45000)
  if state == "logged_in" then
    return
  end
  if contains_any(page_text(), BAD_CREDENTIALS) or present(PASSWORD) then
    fail(INVALID_CREDENTIALS)
  end
  error("TotalEnergies login did not complete - page says: " .. page_text():sub(1, 300))
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local state = open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = LOGIN }, { "maintenance", text = { "maintenance" } } }, 45000)
  if state == "maintenance" then
    error("TotalEnergies' customer area is under maintenance (vendor down)")
  elseif state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  open_and_wait(BILLS_URL, { { "bills", selector = "div.detail-facture, a[href*='/telechargement-des-contrats']" } }, 30000)
  local html = page_html()
  local count = 0
  for _, bill in ipairs(fyde.html.select(html, "div.detail-facture")) do
    local link = fyde.html.select(bill.html, "a[href]")[1]
    if link then
      count = count + 1
      local date = bill.text:match("(%d%d/%d%d/%d%d%d%d)") or tostring(count)
      browser_save("a[href='" .. link.attrs.href .. "']", sanitize(date) .. "_TotalEnergies_facture.pdf", {
        name = "Facture TotalEnergies " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  local contract = fyde.html.select(html, "a[href*='/telechargement-des-contrats']")[1]
  if contract then
    browser_save("a[href='" .. contract.attrs.href .. "']", "TotalEnergies_Contrat.pdf", {
      name = "Contrat TotalEnergies",
      type = "contract",
      category = "housing",
      subcategory = "energy",
    })
  end
  fyde.progress.step("Done")
end

return M
