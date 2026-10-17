-- Scraper for Veepee (ex vente-privee.com, veepee.fr): downloads order invoices.
--
-- The original implementation's
-- `form#authenticationForm` post and `/memberaccount/order/` table are gone: `/memberaccount/
-- order/` now answers "400 Bad request", and the login is a client-rendered Next.js form
-- (`/gr/authentication`, `input[name=email]`/`input[name=password]`, `button#loginBt`) that a
-- plain form post just gets back unchanged. So it is driven through `fyde.browser`: a wrong login
-- shows "Adresse email et/ou mot de passe incorrect" under the form within a second, with no
-- captcha so far (both checked live, with made-up credentials). Logged out, `/gr/my-orders`
-- redirects to the login form; every page's `__NEXT_DATA__` carries `"isAnonymous":true` then, so
-- a session only counts as restored when the page has no password field and says
-- `"isAnonymous":false` (unconfirmed, no account). Orders, unverified (no account): the
-- `/gr/my-orders/<type>/<id>` links of `/gr/my-orders` (routes from the app's build manifest),
-- each details page's "Télécharger la facture" link downloaded through the webview. See
-- README.md.

local M = {}

local BASE = "https://www.veepee.fr"
local ORDERS_URL = BASE .. "/gr/my-orders"
local LOGIN_URL = BASE .. "/gr/authentication?ReturnUrl=%2Fgr%2Fmy-orders"
local EMAIL = "form#authenticationForm input[name='email']"
local PASSWORD = "form#authenticationForm input[name='password']"
local SUBMIT = "form#authenticationForm button#loginBt"
local BAD_CREDENTIALS = { "mot de passe incorrect", "identifiants sont incorrects" }
local CAPTCHA = "iframe[src*='captcha'], iframe[src*='challenges.cloudflare.com'], iframe[src*='datadome']"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local contains_any = helpers.contains_any
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local has = helpers.has

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

local function body_text(html)
  local body = fyde.html.select(html, "body")[1]
  return body and body.text or ""
end

-- A member page: no login form, and the app's own state says the visitor isn't anonymous.
local function logged_in(html)
  return not has(html, PASSWORD)
    and html:find('"isAnonymous":false', 1, true) ~= nil
    and html:find('"isAnonymous":true', 1, true) == nil
end

-- Opens `url` and waits (up to `timeout_ms`) for the login form or a member page; returns the
-- page's markup either way.
local function open(url, timeout_ms)
  fyde.browser:open(url)
  local html = ""
  for _ = 1, math.ceil(timeout_ms / 1000) do
    sleep(1000)
    html = page_html()
    if has(html, PASSWORD) or logged_in(html) then
      return html
    end
  end
  return html
end

local function login(params)
  fyde.progress.step("Logging in")
  local html = has(page_html(), PASSWORD) and page_html() or open(LOGIN_URL, 20000)
  if not has(html, PASSWORD) then
    error("Veepee login form not found on " .. LOGIN_URL)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(EMAIL, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  sleep(500)
  fyde.browser:click(SUBMIT)
  for _ = 1, 30 do
    sleep(1000)
    html = page_html()
    if has(html, PASSWORD) and contains_any(body_text(html), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    elseif html ~= "" and not has(html, PASSWORD) then
      break
    end
  end
  if has(html, PASSWORD) then
    if has(html, CAPTCHA) then
      error("Veepee login is waiting on a captcha")
    end
    error("Veepee login did not complete (still on the login form, no error shown)")
  end
  if not logged_in(open(ORDERS_URL, 20000)) then
    error("Veepee login did not complete (no member page after submitting)")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local html = open(ORDERS_URL, 20000)
  if logged_in(html) then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif has(html, PASSWORD) then
    login(params)
  else
    error("Veepee: neither the login form nor the orders page showed up on " .. ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  -- The orders list renders client-side: give it a few seconds to show its order links.
  local orders, seen = {}, {}
  for _ = 1, 10 do
    html = page_html()
    for _, link in ipairs(fyde.html.select(html, "a[href*='/my-orders/']")) do
      local href = link.attrs.href or ""
      local kind, id = href:match("/my%-orders/([^/?#]+)/([^/?#]+)")
      if kind and not seen[id] then
        seen[id] = true
        orders[#orders + 1] = { id = id, url = absolute(BASE, href:gsub("/details.*$", "") .. "/details") }
      end
    end
    if #orders > 0 then
      break
    end
    sleep(1000)
  end
  if #orders == 0 then
    fyde.log.warn("no orders found on " .. ORDERS_URL)
  end

  for _, order in ipairs(orders) do
    fyde.browser:open(order.url)
    local invoice
    for _ = 1, 10 do
      sleep(1000)
      for _, link in ipairs(fyde.html.select(page_html(), "a[href]")) do
        if contains(link.text, "facture") and not contains(link.text, "demande") then
          invoice = link.attrs.href
          break
        end
      end
      if invoice then
        break
      end
    end
    if invoice then
      local ok, bytes = pcall(function()
        return fyde.browser:download("a[href='" .. invoice:gsub("'", "\\'") .. "']", 60000)
      end)
      if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
        fyde.save_document(sanitize("Veepee_" .. order.id .. ".pdf"), bytes, {
          name = "Facture Veepee " .. order.id,
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      else
        fyde.log.warn("no invoice PDF for order " .. order.id .. ": " .. tostring(ok and "not a PDF" or bytes))
      end
    else
      fyde.log.warn("no invoice link for order " .. order.id)
    end
  end
  fyde.progress.step("Done")
end

return M
