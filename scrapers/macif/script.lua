-- Scraper for MACIF's customer area (macif.fr), the mutual insurer: downloads the payment
-- notices ("avis d'échéance") and certificates ("attestations").
--
-- Drives `fyde.browser`: the login is two-step - `#login` then
-- `button[name="submitButton"]`, then `#password` and `button[onclick="postOk();"]` - possibly
-- followed by a strong-authentication step (`.auth-factor` choice, then a `#passcode` code; a
-- refused code is MFA_FAILED) and a "Continuer vers mon espace" link. Logged in shows
-- `#profil-avatar`/`.mcf-navbar__nav`. The original implementation read the documents from
-- `ssm.macif.fr/internet-espaceclient-rest/personnes/<id>/document/...` with intercepted
-- credentials; this port clicks the download links of the documents page (`#avisecheances`,
-- `#attestations`). Unverified (see README.md).

local M = {}

local CHECK_URL = "https://www.macif.fr/assurance/particuliers/acceder-vos-espaces"
local LOGIN_URL = "https://www.macif.fr/assurance/particuliers/acceder-vos-espaces"
local DOCS_URL = "https://www.macif.fr/assurance/particuliers/vos-espaces-macif/espace-assurance/documents"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe est incorrect", "incorrect", "invalide" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = ".auth-factor, #passcode"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", selector = "#profil-avatar, .mcf-navbar__nav, button[data-logout]" }
local LOGIN_FORM = "#login"

local function login(params)
  fyde.progress.step("logging_in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("MACIF login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#login" }, params.username)
  local state
  if not present("#password") then
    click_first({ "button[name='submitButton']" })
    state = wait_state({ { "password", selector = "#password" }, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 30000)
    if state == "bad" then
      fail(INVALID_CREDENTIALS, "unknown login")
    end
  end
  fill_first({ "#password" }, params.password)
  click_first({ "button[onclick='postOk();']", "button[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if ".auth-factor" ~= "" and present(".auth-factor") then
      fyde.browser:click(".auth-factor")
      wait_state({ { "code", selector = "#passcode" } }, 20000)
    end
    fill_first({ "#passcode" }, ask_code("Code de vérification MACIF"))
    click_first({ "button[type='submit']", "button" })
    state = wait_state({ LOGGED_IN, { "bad_code", text = BAD_CODE } }, 45000)
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
    return
  end
  if state ~= "logged_in" then
    if present("#password") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("MACIF login did not complete - page says: " .. page_text():sub(1, 300))
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
  open_and_wait(DOCS_URL, { { "docs", selector = "#avisecheances a[href], #attestations a[href], a[href*='.pdf']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "#avisecheances a[href], #attestations a[href], a[href*='.pdf']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "macif_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Document MACIF" .. " " .. label,
        type = "contract",
        category = "housing",
        subcategory = "home_insurance",
      })
    end
  end
  fyde.progress.step("done")
end

return M
