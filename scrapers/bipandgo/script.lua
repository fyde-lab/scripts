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
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first

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
