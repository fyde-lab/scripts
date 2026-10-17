-- Scraper for Cdiscount (cdiscount.com), the online retailer: downloads order invoices (or
-- proofs of purchase when an order has no invoice).
--
-- Drives `fyde.browser`: the light login page
-- (now `order.cdiscount.com/Account/LoginLight.html`, reached from the home page's account
-- link), formerly one form (`#CustomerLogin_CustomerLoginFormData_Email`/`..._Password`), now
-- an e-mail step (`#EmailForm`, checked live) then a password step (unconfirmed); logged
-- in when `.leftmenu__logout` is shown; a rejected login re-renders the form with `.c-alert`
-- messages. Orders: `clients.cdiscount.com/order/orderstracking.html` shows one order at a
-- time, chosen with the `#OrderTrackingFormData_SaleFolderId` select; each `#servGuaranteeDiv`
-- block has an `a[title="Imprimer la facture"]` (or "...la preuve d'achat") link.
-- Unverified (see README.md).

local M = {}

-- Opened directly, order.cdiscount.com's login hangs on Cloudflare's interstitial; reached from
-- the home page's account link (once www.cdiscount.com has cleared the check) it loads.
local HOME_URL = "https://www.cdiscount.com/"
local ACCOUNT_LINK = "a[data-e2e='myAccount-icon']"
-- The login is now two-step: `#EmailForm` takes the e-mail alone (an unknown one gets "Aucun
-- compte n'est rattaché à cet email"), then a password field shows up. The same page also
-- holds an account creation form (`#loginCreationForm`) with its own password field.
local EMAIL_STEP = "#EmailForm input[type='email']"
local PASSWORD_STEP = "form:not(#loginCreationForm) input[type='password']"
local UNKNOWN_EMAIL = { "Aucun compte n'est rattaché", "Aucun compte n’est rattaché" }
local ORDERS_URL = "https://clients.cdiscount.com/order/orderstracking.html"
local EMAIL = "#CustomerLogin_CustomerLoginFormData_Email"
local PASSWORD = "#CustomerLogin_CustomerLoginFormData_Password"
local LOGGED_IN = ".leftmenu__logout"
local ORDER_SELECT = "#OrderTrackingFormData_SaleFolderId"
local BAD_CREDENTIALS = { "identifiants", "mot de passe", "incorrect", "invalide" }

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
local contains = helpers.contains

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
  if not present(EMAIL_STEP) and not present(EMAIL) then
    error("Cdiscount login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present(EMAIL_STEP) then
    fyde.browser:fill(EMAIL_STEP, params.username)
    fyde.browser:click("#EmailForm input[type='submit']")
    local step = wait_state({ { "password", selector = PASSWORD_STEP }, { "unknown", text = UNKNOWN_EMAIL } }, 30000)
    if step == "unknown" then
      fail(INVALID_CREDENTIALS, "no account for this e-mail")
    elseif step ~= "password" then
      error("Cdiscount did not show the password step - page says: " .. page_text():sub(1, 300))
    end
    fyde.browser:fill(PASSWORD_STEP, params.password)
    click_first({ "#LoginForm input[type='submit']", "form:not(#loginCreationForm):not(#EmailForm) input[type='submit']" })
  else
    fyde.browser:fill(EMAIL, params.username)
    fyde.browser:fill(PASSWORD, params.password)
    fyde.browser:click("#LoginForm input[type='submit'], input[type='submit']")
  end
  local state = wait_state({
    { "logged_in", selector = LOGGED_IN },
    { "error", selector = ".c-alert" },
  }, 30000)
  if state == "logged_in" then
    return
  end
  local alerts = fyde.html.select(page_html(), ".c-alert")
  local message = alerts[1] and alerts[1].text or ""
  if state == "error" and (contains_any(message, BAD_CREDENTIALS) or #alerts > 1) then
    fail(INVALID_CREDENTIALS, trim(message))
  end
  if present(EMAIL) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  error("Cdiscount login did not complete - page says: " .. page_text():sub(1, 300))
end

local function save_order_documents()
  for _, block in ipairs(fyde.html.select(page_html(), "#servGuaranteeDiv")) do
    local link = fyde.html.select(block.html, "a[title='Imprimer la facture']")[1]
      or fyde.html.select(block.html, "a[title=\"Imprimer la preuve d'achat\"]")[1]
    if link and link.attrs.href then
      local date = fyde.html.select(block.html, ".czOrderHeaderBlocLeft .date > span")[1]
      local ref = fyde.html.select(block.html, ".czOrderCustomerReference")[1]
      ref = ref and trim((ref.text:match(":(.*)$") or ref.text)) or ""
      browser_save("a[href='" .. link.attrs.href .. "']", (date and sanitize(date.text) or "") .. "_Cdiscount_" .. ref .. ".pdf", {
        name = "Facture Cdiscount " .. ref,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  open_and_wait(HOME_URL, { { "home", selector = ACCOUNT_LINK } }, 30000)
  fyde.browser:click(ACCOUNT_LINK)
  local state = wait_state({ { "logged_in", selector = LOGGED_IN }, { "login", selector = EMAIL_STEP .. ", " .. EMAIL } }, 60000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  open_and_wait(ORDERS_URL, { { "orders", selector = "#orderdetails, " .. ORDER_SELECT } }, 30000)
  local options = fyde.html.select(page_html(), ORDER_SELECT .. " option")
  for i, option in ipairs(options) do
    fyde.progress.update(i, #options, option.text)
    if i > 1 then
      -- The page submits its own form when the select changes (the original implementation called
      -- form.submit() itself; `fill` dispatches the same change event).
      fyde.browser:fill(ORDER_SELECT, option.attrs.value)
      sleep(3000)
      wait_state({ { "order", selector = ".czOrderCustomerReference" } }, 20000)
    end
    save_order_documents()
  end
  fyde.progress.step("Done")
end

return M
