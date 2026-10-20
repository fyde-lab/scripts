-- Scraper for Digiposte (secure.digiposte.fr), La Poste's digital safe: downloads every
-- document of every folder (payslips, bills, ...).
--
-- The original implementation
-- solved the La Poste login page's hCaptcha through a paid service and posted
-- username/password to the Keycloak form of moncompte.laposte.fr; this sandbox has no captcha
-- solver, so the login goes through `fyde.browser` (the widget may or may not pass in the
-- embedded webview - unconfirmed). Outcomes, as the original implementation read them from the answer:
-- "identifiant et/ou le mot de passe sont incorrects" = bad credentials; the next steps are
-- told apart by their `page_name` marker: `connexion_challenge_new_device_add_mobile` and
-- `connexion_add_2FA` (skipped: "later"), `connexion_challenge_new_device_otp_email`,
-- `connexion_totp`, `connexion_otp_sms` (6-digit code, a 401 meaning a wrong code), then
-- `connexion_otp_trusted_device` (answered "trusted"); landing on `secure.digiposte.fr/home`
-- means logged in.
--
-- Documents: `secure.digiposte.fr/rest/security/token` gives an API bearer token (it needs the
-- XSRF-TOKEN cookie echoed as an `X-XSRF-TOKEN` header), then `api.digiposte.fr/api/v3/folders`
-- and `.../documents/search` list documents, each downloaded by POSTing `document_ids[]` to
-- `/rest/content/document`. fyde.http can't read a cookie's value, so the XSRF header can't be
-- built: this port tries the token call without it and stops with a clear error if refused
-- (a known blocker, see README.md). Unverified.

local M = {}

local HOME_URL = "https://secure.digiposte.fr/home"
local LOGIN_URL = "https://secure.digiposte.fr/identification-plus"
local API = "https://api.digiposte.fr/api/v3"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains_any = helpers.contains_any
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local json_or_nil = helpers.json_or_nil
local already_saved = helpers.already_saved
local mark_saved = helpers.mark_saved
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first

local LOGGED_IN = { "logged_in", selector = "a[href*='logout'], [data-testid='logout'], dgp-header, .dgp-header" }

local function handle_challenges()
  for _ = 1, 5 do
    local html = page_html()
    if html:find("connexion_challenge_new_device_add_mobile", 1, true) or html:find("connexion_add_2FA", 1, true) then
      click_first({ "button[name='do_add_phone_skip_step']", "button[value='later']", "a[href*='later']", "button.later" })
    elseif html:find("connexion_otp_trusted_device", 1, true) then
      click_first({ "button[value='true']", "button[type='submit']" })
    elseif html:find("connexion_challenge_new_device_otp_email", 1, true) or html:find("connexion_totp", 1, true)
      or html:find("connexion_otp_sms", 1, true) then
      local code = ask_code("Code de vérification Digiposte / La Poste"):gsub("-", "")
      if present("input[name='digit1']") then
        for i = 1, 6 do
          fyde.browser:fill("input[name='digit" .. i .. "']", code:sub(i, i))
        end
      else
        fill_first({ "input[name='code']", "input[autocomplete='one-time-code']" }, code)
      end
      click_first({ "button[type='submit']" })
      sleep(4000)
      if page_html():find("connexion_otp", 1, true) and contains_any(page_text(), { "incorrect", "invalide", "expir" }) then
        fail(MFA_FAILED, "code rejected")
      end
    else
      return
    end
    sleep(4000)
  end
end

local function login(params)
  fyde.progress.step("logging_in")
  if open_and_wait(LOGIN_URL, { { "login", selector = "input[name='password']" } }, 30000) ~= "login" then
    error("La Poste login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("input[name='username']", params.username)
  fyde.browser:fill("input[name='password']", params.password)
  click_first({ "#kc-login", "button[type='submit']", "input[type='submit']" })
  sleep(5000)
  local text = page_text()
  if contains_any(text, { "identifiant et/ou le mot de passe sont incorrects" }) then
    fail(INVALID_CREDENTIALS)
  end
  if contains_any(text, { "Erreur de validation du Captcha", "Captcha validation error" }) then
    error("La Poste rejected the captcha")
  end
  handle_challenges()
  if open_and_wait(HOME_URL, { LOGGED_IN }, 30000) ~= "logged_in" then
    error("Digiposte login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

local function save_folder(folder_id, token)
  local resp = fyde.http.post_json(API .. "/documents/search?direction=DESCENDING&max_results=1000&sort=CREATION_DATE",
    { folder_id = folder_id, locations = { "SAFE", "INBOX" } }, { Authorization = "Bearer " .. token })
  for _, doc in ipairs((json_or_nil(resp.body) or {}).documents or {}) do
    -- The content endpoint is a POST taking the id in its form, so the document id is part of
    -- the key the saved-document tracking uses in place of a URL.
    local key = "https://secure.digiposte.fr/rest/content/document#" .. tostring(doc.id)
    if not already_saved(key) then
      local file = fyde.http.post_form("https://secure.digiposte.fr/rest/content/document", { ["document_ids[]"] = doc.id })
      if file.status == 200 and (file.body or ""):sub(1, 4) == "%PDF" then
        fyde.save_document(sanitize(doc.filename or doc.title or doc.id) .. (tostring(doc.filename):match("%.pdf$") and "" or ".pdf"), file.body, {
          name = doc.title or doc.filename,
          -- A digital safe holds anything: only payslips, the one category it names, are classified.
          type = doc.category == "Bulletin de paie" and "payslip" or nil,
          subcategory = doc.category == "Bulletin de paie" and "payslips" or nil,
        })
        mark_saved(key)
      end
    end
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "input[name='password']" } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  local token = json_or_nil(fyde.http.get("https://secure.digiposte.fr/rest/security/token").body)
  if not (token and token.access_token) then
    error("could not get a Digiposte API token: it needs the XSRF-TOKEN cookie's value as a header, which fyde.http can't read")
  end
  local folders = json_or_nil(fyde.http.get(API .. "/folders", { Authorization = "Bearer " .. token.access_token }).body) or {}
  save_folder("", token.access_token)
  local function walk(list)
    for _, folder in ipairs(list or {}) do
      save_folder(folder.id, token.access_token)
      walk(folder.folders)
    end
  end
  walk(folders.folders)
  fyde.progress.step("done")
end

return M
