-- Scraper for Bouygues Telecom's customer area (bouyguestelecom.fr/mon-compte): downloads the
-- mobile and box bills.
--
-- Ported from github.com/konnectors/cozy-konnector-bouyguestelecom (a cozy-clisk content
-- script driving the real site), so it drives `fyde.browser` too. `/mon-compte` embeds the
-- login form in an iframe (`#bytelid_a360_login`), whose `src` is opened directly to get the
-- form (`input[name="username"]`/`input[name="password"]`, submit button); a code may then be
-- asked (`.radio-tile` channel choice, `.otp` code input) until a "C'est parfait"
-- confirmation, followed by "Continuer". Logged in shows a "Me déconnecter" entry.
-- Bills are listed under "Mes factures" (`/mon-compte/mes-factures`, "Télécharger" links,
-- more loaded with `div[class="column has-text-centered"] > a`). Unverified (see README.md).

local M = {}

local BASE = "https://www.bouyguestelecom.fr/mon-compte"
local BILLS_URL = BASE .. "/mes-factures"
local IFRAME = "#bytelid_a360_login"
local LOGGED_IN_TEXT = { "Me d\195\169connecter" }
local BAD_CREDENTIALS = { "identifiant ou votre mot de passe est incorrect", "identifiant ou mot de passe incorrect", "mot de passe est incorrect" }
local BAD_CODE = { "code est incorrect", "code incorrect", "code invalide", "code a expir" }

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper ported from github.com/konnectors - see README.md).
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

local function submit_code()
  if present(".radio-tile") then
    click_first({ ".radio-tile input", ".radio-tile" })
    click_first({ "button[type='submit']", "form button" })
    sleep(3000)
  end
  local code = ask_code("Code de vérification Bouygues Telecom")
  fill_first({ ".otp input", "input[autocomplete='one-time-code']", "input[name*='code']" }, code)
  click_first({ "button[type='submit']", "form button" })
  local state = wait_state({
    { "ok", text = { "C'est parfait" } },
    { "bad", text = BAD_CODE },
  }, 30000)
  if state ~= "ok" then
    fail(MFA_FAILED, page_text():sub(1, 200))
  end
  fyde.browser:click("a")
  sleep(3000)
end

local function login(params)
  fyde.progress.step("Logging in")
  local iframe = fyde.html.select(page_html(), IFRAME)[1]
  if iframe and iframe.attrs.src then
    open_and_wait(iframe.attrs.src, { { "form", selector = "input[name='username']" } }, 30000)
  end
  if not present("input[name='username']") then
    error("Bouygues Telecom login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("input[name='username']", params.username)
  fill_first({ "input[name='password']", "input[type='password']" }, params.password)
  click_first({ "form[data-roles='inputForm'] button[type='submit']", "button[type='submit']" })
  local state = wait_state({
    { "code", selector = ".radio-tile, .otp" },
    { "bad", text = BAD_CREDENTIALS },
    { "logged_in", text = LOGGED_IN_TEXT },
  }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  elseif state == "code" then
    submit_code()
  end
  if open_and_wait(BASE, { { "logged_in", text = LOGGED_IN_TEXT } }, 30000) ~= "logged_in" then
    if present("input[name='password']") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Bouygues Telecom login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local state = open_and_wait(BASE, { { "logged_in", text = LOGGED_IN_TEXT }, { "login", selector = IFRAME } }, 30000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  open_and_wait(BILLS_URL, { { "bills", text = { "T\195\169l\195\169charger" } } }, 30000)
  for _ = 1, 10 do
    if not present("div[class='column has-text-centered'] > a") then
      break
    end
    fyde.browser:click("div[class='column has-text-centered'] > a")
    sleep(2000)
  end
  for i, link in ipairs(fyde.html.select(page_html(), "a[href]")) do
    if contains(link.text, "T\195\169l\195\169charger") then
      browser_save("a[href='" .. link.attrs.href .. "']", "bouygues_facture_" .. i .. ".pdf", {
        name = "Facture Bouygues Telecom",
        type = "telecom_invoice",
        source_category = "telecom",
        purpose = "invoice",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
