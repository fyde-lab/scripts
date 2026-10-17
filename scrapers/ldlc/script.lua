-- Scraper for LDLC (ldlc.com), the computer-hardware retailer: downloads order invoices.
--
-- The original implementation solved the login's
-- reCAPTCHA (sitekey 6LdgbxgUAAAAAHvdiswvziUz_XecIWb1sWTW7pnz) through a paid service and
-- posted `#loginForm` (__RequestVerificationToken, Email, Password, g-recaptcha-response) to
-- `secure2.ldlc.com/fr-fr/Login/Login?returnUrl=/fr-fr/Account`: an `/fr-fr/Account/Logout` link
-- in the answer means success, a "Connexion" page saying "Identifiants incorrects" bad
-- credentials. Without a captcha solver, the login goes through `fyde.browser` on that page
-- (the widget may or may not pass in the webview - unconfirmed). Orders: POST
-- `Orders/CompletedOrdersPeriodSelection` (JSON periods) -> `PartialCompletedOrdersHeader`
-- (duration/value) -> `div.order` blocks whose `a.collapsed` href
-- (`...PartialCompletedOrderContent<query>#...`) maps to `Orders/DownloadOrderInvoice<query>`.
-- Those go through fyde.http, which only gets the browser's cookies from the next run on - so
-- after a browser login the invoices come on the following run. Unverified (see README.md).

local M = {}

local SECURE = "https://secure2.ldlc.com/fr-fr"
local LOGIN_URL = SECURE .. "/Login/Login?returnUrl=/fr-fr/Account"

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
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf
local sleep = helpers.sleep
local page_html = helpers.page_html

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

local function periods()
  local resp = fyde.http.post_form(SECURE .. "/Orders/CompletedOrdersPeriodSelection", {}, { ["x-requested-with"] = "XMLHttpRequest" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  -- Logged out, this answers 200 with `{"redirectUrl": ".../Login/Login"}` instead of the list.
  if type(data) ~= "table" or data.redirectUrl then
    return nil
  end
  return data
end

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { { "login", selector = "#loginForm, input[name='Password']" } }, 30000) ~= "login" then
    error("LDLC login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#Email", "input[name='Email']" }, params.username)
  fill_first({ "#Password", "input[name='Password']" }, params.password)
  click_first({ "#loginForm button[type='submit']", "#loginForm input[type='submit']", "button[type='submit']" })
  local state = wait_state({
    { "logged_in", selector = "a[href*='/Account/Logout']" },
    { "bad", text = { "Identifiants incorrects" } },
  }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  elseif state ~= "logged_in" then
    error("LDLC login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local list = periods()
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = periods()
    if not list then
      fyde.log.warn("logged in through the browser; invoices will be fetched on the next run (cookies reach fyde.http then)")
      return
    end
  end

  fyde.progress.step("Downloading invoices")
  for _, period in ipairs(list) do
    local page = fyde.http.post_form(SECURE .. "/Orders/PartialCompletedOrdersHeader",
      { duration = tostring(period.duration), value = tostring(period.value) }, { ["x-requested-with"] = "XMLHttpRequest" })
    for _, order in ipairs(fyde.html.select(page.body, "div.order")) do
      local link = fyde.html.select(order.html, "a.collapsed")[1]
      local query = link and (link.attrs.href or ""):match("PartialCompletedOrderContent([^#]*)")
      if query then
        local date = fyde.html.select(order.html, ".cell-date")[1]
        local d, m, y = (date and date.text or ""):match("(%d+)/(%d+)/(%d+)")
        local ref = fyde.html.select(order.html, ".cell-nb-order")[1]
        save_pdf(SECURE .. "/Orders/DownloadOrderInvoice" .. query, (y and (y .. "-" .. m .. "-" .. d) or "commande") .. "_ldlc_" .. sanitize(ref and ref.text or "") .. ".pdf", {
          name = "Facture LDLC " .. (date and trim(date.text) or ""),
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
