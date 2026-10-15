-- Scraper for Eovi MCD Mutuelle's members, now Aésio mutuelle's member area
-- (adherent.aesio.fr): meant to download the health reimbursement statements.
--
-- The original site
-- (www.espace-particuliers.eovi-mcd-mutuelle.fr) no longer resolves: Eovi MCD merged into
-- Aésio, and eovi-mcd.fr now redirects to aesio.fr, whose "Je me connecte" leads to
-- adherent.aesio.fr/login. That is a client-rendered Angular app (an empty "Navigateur non
-- supporté" shell to plain HTTP), so the login is driven through `fyde.browser`:
-- `form.loginForm` with an `input[type=email]`, an `input[type=password]` (random ids) and a
-- submit button; a wrong login shows "Nous n'avons pas réussi à vous identifier" (checked live,
-- with made-up credentials). The app's menu (including "Déconnexion") is in the page even when
-- logged out, so it can't tell a session apart. Nothing past the login is known yet (no account
-- to look at the app with), so a successful login stops with an explicit error rather than
-- guessing at the documents pages.

local M = {}

local LOGIN_URL = "https://adherent.aesio.fr/login"
local LOGIN_FORM = "form.loginForm"
local BAD_CREDENTIALS = { "Nous n'avons pas réussi à vous identifier", "Nous n’avons pas réussi à vous identifier" }

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

-- A `kind:value` subject for fyde.save_document's `subjects`: who or what the document concerns
-- when the account covers several (`person`, `line`, `account`, `contract`, `place`, `vehicle`
-- or `trip`). The value is lowercased with runs of spaces/punctuation turned into "-"; nil for a
-- blank value, which a `subjects` list simply skips.
local function subject(kind, value)
  local slug = trim(value or ""):lower():gsub("[%s%p]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return nil
  end
  return kind .. ":" .. slug
end

-- Masks all but the last `keep` characters of an identifier (phone number, IBAN, contract
-- number...), enough to tell them apart without spelling them out in a subject.
local function mask(value, keep)
  value = (value or ""):gsub("%s", "")
  if #value <= keep then
    return value
  end
  return string.rep("x", #value - keep) .. value:sub(-keep)
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

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { { "login", selector = LOGIN_FORM .. " input[type='password']" } }, 30000) ~= "login" then
    error("Aésio login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ LOGIN_FORM .. " input[type='email']" }, params.username)
  fill_first({ LOGIN_FORM .. " input[type='password']" }, params.password)
  click_first({ LOGIN_FORM .. " button[type='submit']" })
  -- A successful login leaves /login: its form goes away.
  local waited = 0
  repeat
    sleep(1000)
    waited = waited + 1000
    if contains_any(page_text(), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
  until not present(LOGIN_FORM) or waited >= 30000
  if present(LOGIN_FORM) then
    error("Aésio login did not complete - still on the login form")
  end
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  login(params)
  error("credentials accepted, but the Aésio member area's documents pages aren't ported yet - see "
    .. "this script's header comment", 0)
end

return M
