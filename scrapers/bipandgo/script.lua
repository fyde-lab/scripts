-- Scraper for Bip&Go (bipandgo.com), a French motorway toll-badge provider: downloads the
-- invoices listed under "Mon compte > Factures".
--
-- The original implementation logged in by
-- solving the login page's reCAPTCHA v2 (sitekey 6Lc1dyMUAAAAAASglHuUf-6pMMFKMgCt8ASs9ck1)
-- through a paid solving service and posting the token with username/password to
-- `/volatile_cache_context/`. This sandbox has no captcha solver, so the login goes through
-- `fyde.browser` instead: the real page renders its own reCAPTCHA, which may or may not pass
-- invisibly in the embedded webview (unconfirmed). A failed login is detected as in the original implementation:
-- the invoices page still not reachable (it answered 401 / redirected back to the form).
--
-- Invoices: `tbody.badges-block__table-body tr` rows on `/mon_compte/factures`, paginated by
-- 15 with `?invoice_listbox_list_start=N` while an `a[rel="next"]` exists; the PDF link is in
-- the 4th cell. Downloaded through the browser (its cookies only reach `fyde.http` on the next
-- run). Unverified (see README.md).

local M = {}

local BASE = "https://www.bipandgo.com"
local LOGIN_URL = BASE .. "/login_form"
local BILLS_URL = BASE .. "/mon_compte/factures"
local INVOICE_ROWS = "tbody.badges-block__table-body tr"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "login failed", "incorrect" }

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

local STATES = {
  { "logged_in", selector = INVOICE_ROWS .. ", a[href*='logout']" },
  { "login", selector = "input[name='__ac_password'], input[name='password'], input[type='password']" },
}

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { STATES[2] }, 30000) ~= "login" then
    error("Bip&Go login form not found on " .. LOGIN_URL)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[name='__ac_name']", "input[name='username']", "input[type='email']" }, params.username)
  fill_first({ "input[name='__ac_password']", "input[name='password']", "input[type='password']" }, params.password)
  click_first({ "form button[type='submit']", "form input[type='submit']" })
  sleep(5000)
  if open_and_wait(BILLS_URL, STATES, 30000) ~= "logged_in" then
    if contains_any(page_text(), BAD_CREDENTIALS) or present(STATES[2].selector) then
      fail(INVALID_CREDENTIALS, "invoices page still not reachable after login")
    end
    error("login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(BILLS_URL, STATES, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local start = 0
  repeat
    fyde.browser:open(BILLS_URL .. "/?invoice_listbox_list_start=" .. start)
    wait_state({ STATES[1] }, 20000)
    local html = page_html()
    for _, row in ipairs(fyde.html.select(html, INVOICE_ROWS)) do
      local cells = fyde.html.select(row.html, "td")
      local link = cells[4] and fyde.html.select(cells[4].html, "a")[1]
      if link and link.attrs.href then
        local ref, date = trim(cells[1].text), trim(cells[2].text)
        browser_save("a[href='" .. link.attrs.href .. "']", sanitize(date) .. "_" .. ref .. ".pdf", {
          name = "Facture Bip&Go " .. date,
          type = "invoice",
          category = "transport",
          subcategory = "road",
        })
      end
    end
    start = start + 15
  until #fyde.html.select(html, "a[rel='next']") == 0
  fyde.progress.step("Done")
end

return M
