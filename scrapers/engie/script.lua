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
local INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
local MFA_FAILED = "MFA_FAILED"

local function fail(code, detail)
  if detail then
    fyde.log.warn(code .. ": " .. detail)
  end
  error(code, 0)
end

local function contains(haystack, needle)
  return (haystack or ""):lower():find(needle:lower(), 1, true) ~= nil
end

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

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

local LOGGED_IN = { "logged_in", selector = "#header-deconnexion" }

local function login(params)
  fyde.progress.step("Logging in")
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
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "input[type=password], input[type=email]" } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
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
  fyde.progress.step("Done")
end

return M
