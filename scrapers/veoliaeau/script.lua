-- Scraper for Veolia Eau's customer area (service.eau.veolia.fr): downloads the water bills and
-- correspondence.
--
-- Drives `fyde.browser`: `/home/espace-client.html` shows the login form
-- (`#identifiant`, password field) without a session (`.block-deconnecte`), and the documents are
-- listed on `/home/espace-client/vos-factures-et-correspondances.html` (`?voirPlus` for more),
-- whose PDF links are clicked in the browser. Unverified (see README.md).

local M = {}

local CHECK_URL = "https://www.service.eau.veolia.fr/home/espace-client/vos-factures-et-correspondances.html"
local LOGIN_URL = "https://www.service.eau.veolia.fr/home/espace-client.html#inside-space"
local DOCS_URL = "https://www.service.eau.veolia.fr/home/espace-client/vos-factures-et-correspondances.html?voirPlus"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "incorrect", "invalide" }
local MFA = "#__no_mfa__"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", selector = "a[href*='deconnexion'], a[href*='logout'], .block-connecte" }
local LOGIN_FORM = "#identifiant"

local function login(params)
  fyde.progress.step("logging_in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("Veolia Eau login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#identifiant" }, params.username)
  local state
  fill_first({ "#mot_de_passe", "input[type='password']" }, params.password)
  click_first({ "button[type='submit']", "input[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state ~= "logged_in" then
    if present("#mot_de_passe, input[type='password']") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Veolia Eau login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if open_and_wait(CHECK_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  open_and_wait(DOCS_URL, { { "docs", selector = "a[href*='.pdf'], a[href*='telecharger'], a[href*='document']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[href*='telecharger'], a[href*='document']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "veolia_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Document Veolia Eau" .. " " .. label,
        type = "invoice",
        category = "housing",
        subcategory = "water",
      })
    end
  end
  fyde.progress.step("done")
end

return M
