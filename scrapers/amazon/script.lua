-- Scraper for Amazon.fr: downloads the invoices of the orders.
--
-- Drives `fyde.browser`. The home page shows `#nav-greeting-name` with a session, else
-- the sign-in (`/ap/signin`, opened directly): `#ap_email_login` (formerly `#ap_email`) ->
-- `#continue` -> `#ap_password` (with `[name="rememberMe"]`) -> `#signInSubmit`. Amazon's own outcomes are recognised: the
-- `#auth-error-message-box` alert (bad e-mail/password), the "Cet e-mail est nouveau pour nous"
-- page an unknown e-mail now gets (checked live), an OTP step (`#auth-mfa-otpcode`, sent
-- with `#auth-signin-button`; a code refused again = MFA_FAILED) and captchas (not solvable).
-- Orders: "Vos commandes" (`/gp/css/order-history`), one period per `#time-filter` option,
-- `.js-order-card` cards paginated by `.a-last > a`; each card's invoice popover
-- (`.a-popover-trigger` -> `data-a-popover` url) lists `a[href*="invoice.pdf"]` links, which are
-- downloaded through the browser. Unverified (see README.md).

local M = {}

local BASE = "https://www.amazon.fr"
local ORDERS_URL = BASE .. "/gp/css/order-history"
-- The home page's `#nav-link-accountList` no longer reliably leads to the sign-in from the
-- webview, so the sign-in page is opened directly.
local SIGNIN_URL = BASE .. "/ap/signin?openid.pape.max_auth_age=0&openid.return_to=https%3A%2F%2Fwww.amazon.fr%2F%3Fref_%3Dnav_signin"
  .. "&openid.identity=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.assoc_handle=frflex"
  .. "&openid.mode=checkid_setup&openid.claimed_id=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select"
  .. "&openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0"
local EMAIL_FIELD = "#ap_email_login, #ap_email"
local BAD_CREDENTIALS = { "mot de passe est incorrect", "Impossible de trouver un compte", "adresse e-mail ou num\195\169ro de t\195\169l\195\169phone", "password is incorrect", "cannot find an account" }

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

local LOGGED_IN = { "logged_in", selector = "#nav-greeting-name, a[href*='/gp/flex/sign-out']" }

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(SIGNIN_URL, { { "email", selector = EMAIL_FIELD } }, 30000) ~= "email" then
    error("Amazon sign-in form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#ap_email_login", "#ap_email" }, params.username)
  click_first({ "#continue input[type='submit']", "#ap_login_form input[type='submit']", "#continue" })
  -- An unknown e-mail now lands on "Cet e-mail est nouveau pour nous", offering to register
  -- (`#intent-confirmation-form`, posting to /ap/register) instead of an error box.
  local state = wait_state({
    { "password", selector = "#ap_password" },
    { "bad", selector = "#auth-error-message-box, #intent-confirmation-form" },
  }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS, "unknown account")
  elseif state ~= "password" then
    error("Amazon did not show the password step (captcha?) - page says: " .. page_text():sub(1, 300))
  end
  fyde.browser:fill("#ap_password", params.password)
  if present("[name='rememberMe']") then
    fyde.browser:click("[name='rememberMe']")
  end
  fyde.browser:click("#signInSubmit")
  state = wait_state({
    LOGGED_IN,
    { "otp", selector = "#auth-mfa-otpcode, input[name='otpCode'], input[name='code']" },
    { "bad", selector = "#auth-error-message-box" },
    { "captcha", selector = "#auth-captcha-image, #captchacharacters, iframe[src*='arkoselabs']" },
  }, 30000)
  if state == "bad" then
    local box = fyde.html.select(page_html(), "#auth-error-message-box")[1]
    if contains_any(box and box.text, BAD_CREDENTIALS) or present("#ap_password") then
      fail(INVALID_CREDENTIALS, box and trim(box.text))
    end
    error("Amazon refused the login: " .. (box and trim(box.text) or ""))
  elseif state == "captcha" then
    error("Amazon asks for a captcha, which this scraper can't solve")
  elseif state == "otp" then
    local field = fill_first({ "#auth-mfa-otpcode", "input[name='otpCode']", "input[name='code']" }, ask_code("Code de vérification Amazon"))
    click_first({ "#auth-signin-button", "input[type='submit']", "button[type='submit']" })
    if wait_state({ LOGGED_IN, { "otp", selector = field .. ", #auth-error-message-box" } }, 30000) ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
  elseif state ~= "logged_in" then
    error("Amazon login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

local function save_order_invoices(card)
  local ref = fyde.html.select(card.html, "bdi")[1]
  ref = ref and trim(ref.text) or "commande"
  for _, trigger in ipairs(fyde.html.select(card.html, ".a-popover-trigger, [data-a-popover]")) do
    local popover = (trigger.attrs["data-a-popover"] or ""):gsub("&quot;", '"')
    local url = popover:match('"url"%s*:%s*"([^"]*invoice[^"]*)"')
    if url then
      fyde.browser:open(BASE .. url:gsub("\\/", "/"):gsub("&amp;", "&"))
      sleep(2000)
      for i, link in ipairs(fyde.html.select(page_html(), "a[href*='invoice.pdf']")) do
        browser_save("a[href='" .. link.attrs.href .. "']", ref .. (i > 1 and ("_" .. i) or "") .. "_amazon.pdf", {
          name = "Facture Amazon " .. ref,
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      end
    end
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(BASE, { LOGGED_IN, { "login", selector = "#nav-link-accountList, " .. EMAIL_FIELD } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  open_and_wait(ORDERS_URL, { { "orders", selector = "#time-filter, #orderFilter, .js-order-card" } }, 30000)
  local periods = {}
  for _, option in ipairs(fyde.html.select(page_html(), "#time-filter option, #orderFilter option")) do
    if option.attrs.value then
      periods[#periods + 1] = option.attrs.value
    end
  end
  for _, period in ipairs(periods) do
    local url = ORDERS_URL .. "?timeFilter=" .. period .. "&orderFilter=" .. period
    for _ = 1, 50 do
      open_and_wait(url, { { "orders", selector = ".js-order-card, .num-orders" } }, 30000)
      local html = page_html()
      local next_link = fyde.html.select(html, ".a-last > a")[1]
      for _, card in ipairs(fyde.html.select(html, ".js-order-card")) do
        save_order_invoices(card)
      end
      if not (next_link and next_link.attrs.href) then
        break
      end
      url = BASE .. next_link.attrs.href
    end
  end
  fyde.progress.step("Done")
end

return M
