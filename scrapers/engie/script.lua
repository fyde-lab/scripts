-- Scraper for ENGIE's customer area (particuliers.engie.fr): downloads the gas/electricity bills
-- and the proof of residence.
--
-- Drives `fyde.browser`: `/login-page/authentification.html` has `input[type=email]`
-- and `input[type=password]` (possibly on two steps) in `form.k-oktaConnexion__form`, sent by
-- its "Me connecter" `button.k-cta` (a `type=button`; a wrong login shows "L'adresse e-mail
-- et/ou le mot de passe sont incorrects" - checked live); logged in shows `#header-deconnexion` (or
-- a "Se déconnecter" button). Bills: `/espace-client/prive/mes-factures.html`; the original implementation
-- read them from the private API (`cel-ws/api/private/...`, `/SAE/facture.pdf` documents) and
-- the proof of residence from `cel-ws/api/private/pdf/attestationTitulaireContrat`. The bills
-- page's download controls are clicked in the browser; the proof of residence is fetched with
-- fyde.http, which only has the browser's cookies from the next run on. Unverified (see
-- README.md).

local M = {}

local BASE = "https://particuliers.engie.fr"
local LOGIN_URL = BASE .. "/login-page/authentification.html"
local HOME_URL = BASE .. "/espace-client/prive/accueil.html"
local BILLS_URL = BASE .. "/espace-client/prive/mes-factures.html"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "incorrect", "invalide" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local save_pdf = helpers.save_pdf
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", selector = "#header-deconnexion" }

local function login(params)
  fyde.progress.step("logging_in")
  if open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = "input[type=email], input[type=password]" } }, 30000) ~= "login" then
    error("ENGIE login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present("input[type=email]") then
    fyde.browser:fill("input[type=email]", params.username)
  end
  if not present("input[type=password]") then
    click_first({ "button[type='submit']" })
    wait_state({ { "password", selector = "input[type=password]" } }, 20000)
  end
  fyde.browser:fill("input[type=password]", params.password)
  -- "Me connecter" is a plain `type=button` in the Okta-backed `form.k-oktaConnexion__form`.
  click_first({ "form.k-oktaConnexion__form button.k-cta[class*='rootTypePrimary']", "button[type='submit']", "input[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS } }, 45000)
  if state == "bad" or (state == nil and present("input[type=password]")) then
    fail(INVALID_CREDENTIALS)
  elseif state ~= "logged_in" then
    error("ENGIE login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "input[type=password], input[type=email]" } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  open_and_wait(BILLS_URL, { { "bills", selector = "a[href*='.pdf'], a[href*='facture']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[href*='/document/']")) do
    count = count + 1
    browser_save("a[href='" .. link.attrs.href .. "']", "Engie_facture_" .. count .. "_" .. sanitize(trim(link.text)) .. ".pdf", {
      name = "Facture ENGIE " .. trim(link.text),
      type = "invoice",
      category = "housing",
      subcategory = "energy",
    })
  end
  save_pdf(BASE .. "/cel-ws/api/private/pdf/attestationTitulaireContrat", "justificatif de domicile.pdf", {
    name = "Justificatif de domicile ENGIE",
    type = "proof_of_residence",
    category = "housing",
    subcategory = "energy",
  })
  fyde.progress.step("done")
end

return M
