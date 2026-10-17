-- Scraper for La Mutuelle Générale's member area (adherent.lamutuellegenerale.fr): downloads
-- the health documents (reimbursement statements, certificates).
--
-- The original implementation was a content script driving the real site, so this one
-- drives `fyde.browser` too: the member area (an Auth0 Angular app) now
-- redirects a logged-out visitor to CNP's Auth0 tenant (authentification.cnp-protectionsociale.fr,
-- behind Imperva, which the webview passes on its own), whose React login form has id/name-less
-- inputs (`form input[type='text']` for the e-mail/membership number, `form input[type='password']`)
-- and a `form button[type='submit']` (checked live; it used to be `#username`/`#password`).
-- Logged in, the member area shows an `a[analyticsbuttonlabel="Déconnexion"]` link. The original implementation read the documents from the
-- site's intercepted API answers; this port clicks the download controls of the documents page
-- (`/mes-documents`, URL unconfirmed). Unverified (see README.md).

local M = {}

local CHECK_URL = "https://adherent.lamutuellegenerale.fr/"
local LOGIN_URL = "https://adherent.lamutuellegenerale.fr/"
local DOCS_URL = "https://adherent.lamutuellegenerale.fr/mes-documents"
local BAD_CREDENTIALS = { "informations saisies ne sont pas valides", "identifiant ou mot de passe", "mot de passe incorrect", "Invalid username or password", "incorrect" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = "#otp, input[name='otp']"

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

local LOGGED_IN = { "logged_in", selector = "a[analyticsbuttonlabel='Déconnexion']" }
local LOGIN_FORM = "form input[type='password']"
local USERNAME = "form input[type='text']"

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("La Mutuelle Générale login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ USERNAME }, params.username)
  local state
  fill_first({ LOGIN_FORM }, params.password)
  click_first({ "form button[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if "" ~= "" and present("") then
      fyde.browser:click("")
      wait_state({ { "code", selector = "#otp, input[name='otp']" } }, 20000)
    end
    fill_first({ "#otp", "input[name='otp']" }, ask_code("Code de vérification La Mutuelle Générale"))
    click_first({ "button[type='submit']", "input[type='submit']" })
    state = wait_state({ LOGGED_IN, { "bad_code", text = BAD_CODE } }, 45000)
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
    return
  end
  if state ~= "logged_in" then
    if present(LOGIN_FORM) then
      fail(INVALID_CREDENTIALS, "still on the login form - page says: " .. page_text():sub(1, 300))
    end
    error("La Mutuelle Générale login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(CHECK_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
  open_and_wait(DOCS_URL, { { "docs", selector = "a[href*='.pdf'], a[download], button[id*='download'], button[id*='telecharg']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[download], button[id*='download'], button[id*='telecharg']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "lmg_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Document La Mutuelle Générale" .. " " .. label,
        type = "medical_document",
        category = "health",
        subcategory = "complementary_health",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
