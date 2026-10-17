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
local contains_any = helpers.contains_any
local trim = helpers.trim

local function sanitize(name)
  name = trim((name or ""):gsub("%s+", " "))
  name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

-- Asks the user for a one-time code through fyde.input.ask; an unanswered/empty prompt (or no
-- input handler at all, e.g. an unattended run) is an MFA failure.
local function ask_code(question)
  local ok, code = pcall(fyde.input.ask, question)
  if not ok or type(code) ~= "string" or trim(code) == "" then
    fail(MFA_FAILED, "no one-time code was provided")
  end
  return (code:gsub("%s", ""))
end

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

-- Fills `values` into the form matching `selector` on `page` and posts it.
local function submit_form(page, selector, values, headers)
  local action, fields = read_form(page, selector)
  if not action then
    error("no form matching '" .. selector .. "' on " .. tostring(page.url))
  end
  for name, value in pairs(values) do
    fields[name] = value
  end
  return fyde.http.post_form(action, fields, headers)
end

local function has(page_or_html, selector)
  local html = type(page_or_html) == "table" and page_or_html.body or page_or_html
  return #fyde.html.select(html or "", selector) > 0
end

local function json_or_nil(body)
  local ok, value = pcall(fyde.json.decode, body or "")
  if ok then
    return value
  end
  return nil
end

-- Downloads `url` and saves it as `filename` when it really is a PDF; returns true on success.
local function save_pdf(url, filename, fields, headers)
  local resp = fyde.http.download(url, headers)
  local content_type = resp.content_type or ""
  local is_pdf = content_type:find("pdf", 1, true) or (resp.body or ""):sub(1, 4) == "%PDF"
  if resp.status == 200 and is_pdf then
    fyde.save_document(sanitize(filename), resp.body, fields)
    return true
  end
  fyde.log.warn(string.format("skipping %s (status %d, content-type %s)", filename, resp.status, content_type))
  return false
end

-- `wait_for` only waits for a selector to appear, so sleeping means waiting on one that never
-- exists.
local function sleep(ms)
  pcall(function()
    fyde.browser:wait_for("#__fyde_scraper_sleep__", ms)
  end)
end

local function page_html()
  local ok, html = pcall(function()
    return fyde.browser:html()
  end)
  return ok and html or ""
end

local function present(selector)
  return #fyde.html.select(page_html(), selector) > 0
end

local function page_text()
  local body = fyde.html.select(page_html(), "body")[1]
  return body and body.text or ""
end

-- Polls the current page until one of `states` matches and returns its name (or nil after
-- `timeout_ms`). Each state is `{ name, selector = css }` or `{ name, text = { needles } }`.
-- Polling in short chunks also survives `fyde.browser:open` not waiting for navigation (a
-- `wait_for` issued against the previous page just times out and gets retried).
local function wait_state(states, timeout_ms)
  local waited = 0
  repeat
    local html = page_html()
    local text
    for _, state in ipairs(states) do
      if state.selector and #fyde.html.select(html, state.selector) > 0 then
        return state[1]
      end
      if state.text then
        if not text then
          local body = fyde.html.select(html, "body")[1]
          text = body and body.text or ""
        end
        if contains_any(text, state.text) then
          return state[1]
        end
      end
    end
    sleep(1000)
    waited = waited + 1000
  until waited >= (timeout_ms or 30000)
  return nil
end

local function open_and_wait(url, states, timeout_ms)
  fyde.browser:open(url)
  sleep(1500)
  return wait_state(states, timeout_ms)
end

-- Fills the first present selector of each candidate list.
local function fill_first(selectors, value)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:fill(selector, value)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

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
  fyde.progress.step("Logging in")
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
    local file = fyde.http.post_form("https://secure.digiposte.fr/rest/content/document", { ["document_ids[]"] = doc.id })
    if file.status == 200 and (file.body or ""):sub(1, 4) == "%PDF" then
      fyde.save_document(sanitize(doc.filename or doc.title or doc.id) .. (tostring(doc.filename):match("%.pdf$") and "" or ".pdf"), file.body, {
        name = doc.title or doc.filename,
        -- A digital safe holds anything: only payslips, the one category it names, are classified.
        type = doc.category == "Bulletin de paie" and "payslip" or nil,
        subcategory = doc.category == "Bulletin de paie" and "payslips" or nil,
      })
    end
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "input[name='password']" } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
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
  fyde.progress.step("Done")
end

return M
