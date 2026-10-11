-- Scraper for Harmonie Mutuelle's member space (harmonie-et-moi.fr): downloads the health
-- documents and contract documents.
--
-- Drives `fyde.browser`: `/identification` shows either the
-- logged-in home (`.home-page-title`) or a `.already-an-account-button` leading to the
-- `#username`/`#password` form. Documents are under "Mes documents" (`a[href*="/mes-documents"]`
-- -> `.list-documents-flex-container`); the original implementation read their list from intercepted API
-- answers and downloaded them from `hapiour.harmonie-mutuelle.fr/adherent-api/v1/document/<id>`
-- with the `_cap_token` from localStorage - neither is reachable from this sandbox, so this port
-- clicks each document's download control in the list instead. Unverified (see README.md).

local M = {}

local LOGIN_URL = "https://harmonie-et-moi.fr/identification"
local DOCS_URL = "https://harmonie-et-moi.fr/mes-documents"
local LOGGED_IN = { "logged_in", selector = ".home-page-title, #logout, button[routerlink='/mon-profil']" }
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "incorrect", "invalide", "erron" }

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
  if present(".already-an-account-button") then
    fyde.browser:click(".already-an-account-button")
  end
  if wait_state({ { "form", selector = "#username" } }, 30000) ~= "form" then
    error("Harmonie Mutuelle login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("#username", params.username)
  fyde.browser:fill("#password", params.password)
  click_first({ "button[type='submit']", "input[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "bad", selector = ".error, .alert-danger, [role='alert']" } }, 45000)
  if state == "logged_in" then
    return
  end
  if (state == "bad" and contains_any(page_text(), BAD_CREDENTIALS)) or present("#password") then
    fail(INVALID_CREDENTIALS, page_text():sub(1, 200))
  end
  error("Harmonie Mutuelle login did not complete - page says: " .. page_text():sub(1, 300))
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local state = open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = ".already-an-account-button, #username" } }, 30000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
  open_and_wait(DOCS_URL, { { "docs", selector = ".list-documents-flex-container" } }, 30000)
  sleep(3000)
  local html = page_html()
  local items = fyde.html.select(html, ".list-documents-flex-container a[href], .list-documents-flex-container button[id]")
  for i, item in ipairs(items) do
    local selector = item.attrs.href and ("a[href='" .. item.attrs.href .. "']") or ("#" .. item.attrs.id)
    browser_save(selector, "harmonie_" .. sanitize(trim(item.text) ~= "" and trim(item.text) or tostring(i)) .. ".pdf", {
      name = "Document Harmonie Mutuelle " .. trim(item.text),
      type = "other_health_document",
      source_category = "insurance",
      source_sub_category = "health",
    })
  end
  fyde.progress.step("Done")
end

return M
