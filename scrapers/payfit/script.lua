-- Scraper for PayFit (app.payfit.com), the payroll software: downloads the employee's payslips.
--
-- Drives `fyde.browser`: the login is two-step - the e-mail (formerly `#username`, now
-- an id-less `input[type=email]`) then the form's submit button ("Continuer"), then `#password`
-- and the same button (a wrong login shows "E-mail ou mot de passe incorrect" - checked live) -
-- possibly followed by a `#code` verification step (a refused code is MFA_FAILED); logged in shows the
-- `button[data-testid="accountButton"]`. The original implementation listed payslips from the intercepted
-- `api.payfit.com/files` answer and downloaded each through
-- `files/file/<id>/presigned-url` with the intercepted bearer token; neither is reachable here,
-- so this port clicks the download controls of the payslips page (`/payslips`, URL
-- unconfirmed). Unverified (see README.md).

local M = {}

local CHECK_URL = "https://app.payfit.com/"
local LOGIN_URL = "https://app.payfit.com/login"
local DOCS_URL = "https://app.payfit.com/payslips"
local BAD_CREDENTIALS = { "Wrong email or password", "mot de passe incorrect", "E-mail ou mot de passe incorrect" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = "#code"

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
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text

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

local LOGGED_IN = { "logged_in", selector = "button[data-testid='accountButton']" }
-- The e-mail field lost its `#username` id: it's now the form's only `input[type=email]`.
local LOGIN_FORM = "#username, form input[type='email']"

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("PayFit login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#username", "form input[type='email']" }, params.username)
  local state
  if not present("#password") then
    click_first({ "._button-login-id", "form button[type='submit']", "button[type='submit']" })
    state = wait_state({ { "password", selector = "#password" }, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 30000)
    if state == "bad" then
      fail(INVALID_CREDENTIALS, "unknown login")
    end
  end
  fill_first({ "#password" }, params.password)
  click_first({ "._button-login-password", "form button[type='submit']", "button[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if "" ~= "" and present("") then
      fyde.browser:click("")
      wait_state({ { "code", selector = "#code" } }, 20000)
    end
    fill_first({ "#code" }, ask_code("Code de vérification PayFit"))
    click_first({ "button[type='submit']" })
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
    error("PayFit login did not complete - page says: " .. page_text():sub(1, 300))
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
  open_and_wait(DOCS_URL, { { "docs", selector = "a[href*='.pdf'], a[download], a[href*='presigned'], button[data-testid*='download']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[download], a[href*='presigned'], button[data-testid*='download']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "payfit_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Bulletin de paie PayFit" .. " " .. label,
        type = "payslip",
        category = "work",
        subcategory = "payslips",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
