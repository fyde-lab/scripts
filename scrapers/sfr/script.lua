-- Scraper for SFR's customer area (espace-client.sfr.fr): downloads the mobile and box bills.
--
-- Drives `fyde.browser`: `www.sfr.fr/mon-espace-client/` shows the SFR login (`#username`,
-- `#password`) without a session; logged in shows a logout link
-- (`a[href*="openid-connect/logout"]`). Bills: `/facture-mobile/consultation` (or
-- `/facture-fixe/consultation`), `#lastFacture` and the `#historique`, more loaded with
-- `#plusFac`; their download links are clicked in the browser. See also `sfrbox`, the older
-- plain-HTTP port. Unverified (see README.md).

local M = {}

local CHECK_URL = "https://www.sfr.fr/mon-espace-client/"
local LOGIN_URL = "https://www.sfr.fr/mon-espace-client/#sfrclicid=EC_mire_Me-Connecter"
local DOCS_URL = "https://espace-client.sfr.fr/facture-mobile/consultation"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe est incorrect", "identifiants sont incorrects", "incorrect" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = "input[name='otp'], #otp"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", selector = "a[href*='openid-connect/logout'], a[href*='sfr.fr/cas/logout']" }
local LOGIN_FORM = "#username"

-- `wait_state`, except that a "logged_in" match only counts once the login form is gone: the CAS
-- login page carries SFR's shared header, whose account menu holds the openid-connect/cas logout
-- links even when logged out. Keep LOGGED_IN last in `states` so the other states get checked.
local function wait_session_state(states, timeout_ms)
  local waited = 0
  repeat
    local state = wait_state(states, 1000)
    if state and not (state == "logged_in" and present(LOGIN_FORM)) then
      return state
    end
    if state then
      sleep(1000)
    end
    waited = waited + 1000
  until waited >= timeout_ms
  return nil
end

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    fyde.browser:open(LOGIN_URL)
    wait_session_state({ { "login", selector = LOGIN_FORM }, LOGGED_IN }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("SFR login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#username" }, params.username)
  local state
  fill_first({ "#password" }, params.password)
  click_first({ "#identifier", "button[type='submit']", "input[type='submit']" })
  state = wait_session_state({ { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA }, LOGGED_IN }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if "" ~= "" and present("") then
      fyde.browser:click("")
      wait_state({ { "code", selector = "input[name='otp'], #otp" } }, 20000)
    end
    fill_first({ "input[name='otp']", "#otp" }, ask_code("Code de vérification SFR"))
    click_first({ "button[type='submit']" })
    state = wait_session_state({ { "bad_code", text = BAD_CODE }, LOGGED_IN }, 45000)
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
    return
  end
  if state ~= "logged_in" then
    if present("#password") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("SFR login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(CHECK_URL)
  if wait_session_state({ { "login", selector = LOGIN_FORM }, LOGGED_IN }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
  open_and_wait(DOCS_URL, { { "docs", selector = "#lastFacture a[href*='pdf'], #historique a[href*='pdf'], a[href*='telecharger'], a.sr-chevron" } }, 45000)
  for _ = 1, 20 do
    if not present("#plusFac") then
      break
    end
    fyde.browser:click("#plusFac")
    sleep(2000)
  end
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "#lastFacture a[href*='pdf'], #historique a[href*='pdf'], a[href*='telecharger'], a.sr-chevron")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "sfr_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Facture SFR" .. " " .. label,
        type = "invoice",
        category = "telecom",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
