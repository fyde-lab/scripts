-- Scraper for Thomann (thomann.fr), the music-instrument retailer: downloads order invoices.
--
-- The original implementation targeted thomann.de/fr, which now redirects to
-- thomann.fr - behind a Cloudflare "Just a moment..." challenge that plain HTTP can't pass, and
-- with an invisible Turnstile widget on the login form that only resolves on submit. So it is
-- driven through `fyde.browser` (with challenges.cloudflare.com allowed): `/mythomann_login.html`
-- has `input[name='uname']`/`input[name='passw']` and a "Se connecter" submit button; bad
-- credentials re-render the form with "La connexion a échouée – Email ou mot de passe
-- incorrect." after ~10s (both confirmed against the live site). Orders, unverified (no
-- account): the `.mythomann-order-teaser` blocks of `/mythomann_orderlist.html` ("Commande <n>
-- ... du dd.mm.yyyy", details link), paginated by `#order-list .fx-pagination__pages-button`
-- after the active one; each details page has an `a.mythomann-order-history__entry-pdf-button`
-- invoice, downloaded through the webview. See README.md.

local M = {}

local BASE = "https://www.thomann.fr"
local LOGIN_URL = BASE .. "/mythomann_login.html"
local ORDERS_URL = BASE .. "/mythomann_orderlist.html"
local PASSWORD_FIELD = "input[name='passw']"
local SUBMIT = "form:has(input[name='passw']) button[type='submit']"
local LOGGED_IN = "a[href*='logout'], a[href*='mythomann_orderlist']"
local BAD_CREDENTIALS = { "mot de passe incorrect", "connexion a échoué" }
local PDF_BUTTON = "a.mythomann-order-history__entry-pdf-button"

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
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local read_form = helpers.read_form

-- Fills `values` into the form matching `selector` on `page` and posts it.
local function submit_form(page, selector, values, headers)
  local action, fields = read_form(page, selector)
  if not action then
    error("no form matching '" .. selector .. "' on " .. tostring(page.url))
  end
  for name, value in pairs(values) do
    fields[name] = value
  end
  return fyde.http.post_form(action, fields, headers)
end

local function has(page_or_html, selector)
  local html = type(page_or_html) == "table" and page_or_html.body or page_or_html
  return #fyde.html.select(html or "", selector) > 0
end

local function json_or_nil(body)
  local ok, value = pcall(fyde.json.decode, body or "")
  if ok then
    return value
  end
  return nil
end

-- Downloads `url` and saves it as `filename` when it really is a PDF; returns true on success.
local function save_pdf(url, filename, fields, headers)
  local resp = fyde.http.download(url, headers)
  local content_type = resp.content_type or ""
  local is_pdf = content_type:find("pdf", 1, true) or (resp.body or ""):sub(1, 4) == "%PDF"
  if resp.status == 200 and is_pdf then
    fyde.save_document(sanitize(filename), resp.body, fields)
    return true
  end
  fyde.log.warn(string.format("skipping %s (status %d, content-type %s)", filename, resp.status, content_type))
  return false
end
-- luacheck: pop

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

-- Opens `url` and waits (up to `timeout_ms`, past the Cloudflare challenge) for one of
-- `selectors` to show up; returns the page's markup either way.
local function open(url, selectors, timeout_ms)
  fyde.browser:open(url)
  local html = ""
  for _ = 1, math.ceil(timeout_ms / 1000) do
    sleep(1000)
    html = page_html()
    for _, selector in ipairs(selectors) do
      if has(html, selector) then
        return html
      end
    end
  end
  return html
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Logging in")
  fyde.browser:fill("input[name='uname']", params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT)
  -- The invisible Turnstile runs first: the answer takes ~10s.
  for _ = 1, 45 do
    sleep(1000)
    local html = page_html()
    if has(html, PASSWORD_FIELD) and contains_any(body_text(html), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    elseif not has(html, PASSWORD_FIELD) and has(html, LOGGED_IN) then
      return
    end
  end
  if has(page_html(), PASSWORD_FIELD) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  error("Thomann login did not complete (no account page after submitting)")
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local html = open(LOGIN_URL, { PASSWORD_FIELD, LOGGED_IN }, 45000)
  if has(html, PASSWORD_FIELD) then
    login(params)
  elseif has(html, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    error("Thomann login page not found (Cloudflare challenge not passed?)")
  end

  fyde.progress.step("Downloading invoices")
  local page = open(ORDERS_URL, { ".mythomann-order-teaser", "#order-list" }, 30000)
  for _ = 1, 50 do
    for _, teaser in ipairs(fyde.html.select(page, ".mythomann-order-teaser")) do
      local details = fyde.html.select(teaser.html, ".mythomann-order-teaser__details-wrapper > a")[1]
      local text = teaser.text:gsub("%s+", " ")
      local number = text:match("Commande ([%d%.]+)") or "commande"
      local day, month, year = text:match("du (%d+)%.(%d+)%.(%d+)")
      if details and details.attrs.href then
        open(absolute(BASE, details.attrs.href), { PDF_BUTTON }, 20000)
        local ok, bytes = pcall(function()
          return fyde.browser:download(PDF_BUTTON, 60000)
        end)
        if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
          fyde.save_document(sanitize((year and (year .. "-" .. month .. "-" .. day) or "") .. "_thomann_" .. number .. ".pdf"), bytes, {
            name = "Facture Thomann " .. number,
            type = "invoice",
            category = "shopping",
            subcategory = "online",
          })
        else
          fyde.log.warn("no invoice PDF for order " .. number .. ": " .. tostring(ok and "not a PDF" or bytes))
        end
      end
    end
    local buttons = fyde.html.select(page, "#order-list > .fx-pagination > .fx-pagination__pages > .fx-pagination__pages-button")
    local next_url
    for i, button in ipairs(buttons) do
      if (button.attrs.class or ""):find("fx-pagination__pages-button--active", 1, true) and buttons[i + 1] then
        next_url = buttons[i + 1].attrs.href
      end
    end
    if not next_url then
      break
    end
    page = open(absolute(BASE, next_url), { ".mythomann-order-teaser" }, 30000)
  end
  fyde.progress.step("Done")
end

return M
