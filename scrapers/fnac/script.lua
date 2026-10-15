-- Scraper for Fnac (fnac.com), the retailer: downloads order invoices.
--
-- The original implementation's login needed the
-- value of the `authorize_request_identifier` cookie set by the OAuth redirect of
-- `secure.fnac.com/identity/gateway/signin` (posted with email/password to
-- `identity/server/api/v1/login`; any failure = LOGIN_FAILED). fyde.http can't read cookie
-- values, so the login goes through `fyde.browser` on that same signin page instead. A session
-- is valid when `MyAccount/Order/GetOrders` answers without redirecting to the login. Orders:
-- `GetOrders?DateRangeType=<3..6>&OrderType=0`, one `.ma-Order` per order (section
-- `data-order-id`, date in `.ma-OrderTop>div>div>span:nth-child(1)`) whose invoice URL is
-- inside a `javascript:...('https...')` `.ma-OrderDetails-Link`. Those are downloaded with
-- fyde.http, which only gets the browser's cookies from the next run on - so right after a
-- browser login the documents come on the following run. Unverified (see README.md).

local M = {}

local SIGNIN_URL = "https://secure.fnac.com/identity/gateway/signin"
local ORDERS_URL = "https://secure.fnac.com/MyAccount/Order/GetOrders?OrderType=0&DateRangeType="
local BAD_CREDENTIALS = { "adresse e-mail ou mot de passe incorrect", "identifiants incorrects", "mot de passe incorrect", "incorrect" }

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

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

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

local function logged_in_http()
  local page = fyde.http.get(ORDERS_URL .. "2")
  return page.status == 200 and page.url:find("GetOrders", 1, true) ~= nil and not has(page, "input[type='password']")
end

-- Fnac (like Darty) is behind DataDome, which answers the webview with its stub page (an inline
-- `var dd={'rt':'i', ..., 'host':'geo.captcha-delivery.com'}` loading a "Device Check"
-- interstitial from that host - hence it in manifest.json's `allowed_domains`) instead of the
-- page. Seen live from the home page on, the interstitial never clears in this webview (still
-- there after a minute), and once its iframe has loaded the page may stop answering `html()`
-- (it then reads back as ""). The script never touches the challenge: when it can see it, it
-- gives a human `CAPTCHA_TIMEOUT_MS` to get past it in a `--visible` window; otherwise it fails
-- with an explicit DataDome error.
local CAPTCHA_TIMEOUT_MS = 120000

local function datadome_shown()
  return page_html():find("captcha-delivery.com", 1, true) ~= nil
end

local function wait_past_datadome(states, timeout_ms)
  local waited = 0
  repeat
    local state = wait_state(states, 1000)
    if state then
      return state
    end
    if datadome_shown() then
      fyde.progress.step("Waiting for the Fnac captcha to be solved in the browser window")
      fyde.log.warn("DataDome captcha shown; it must be solved by hand in the browser window (--visible)")
      state = wait_state(states, CAPTCHA_TIMEOUT_MS)
      if not state then
        error("Fnac is blocked by a DataDome captcha - run with --visible and solve it in the browser window")
      end
      return state
    end
    waited = waited + 1000
  until waited >= timeout_ms
  return nil
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.browser:open(SIGNIN_URL)
  sleep(1500)
  if wait_past_datadome({ { "login", selector = "input[type='password'], input[type='email']" } }, 30000) ~= "login" then
    if datadome_shown() or page_html() == "" then
      error("Fnac's sign-in page never showed its form: blocked by DataDome's device check (geo.captcha-delivery.com)")
    end
    error("Fnac login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[type='email']", "input[name='email']" }, params.username)
  if not present("input[type='password']") then
    click_first({ "button[type='submit']" })
    wait_state({ { "password", selector = "input[type='password']" } }, 20000)
  end
  fyde.browser:fill("input[type='password']", params.password)
  click_first({ "button[type='submit']" })
  local state = wait_state({ { "bad", text = BAD_CREDENTIALS }, { "done", text = { "Mon compte", "Mes commandes", "Bonjour" } } }, 30000)
  if state == "bad" or (state == nil and present("input[type='password']")) then
    fail(INVALID_CREDENTIALS)
  elseif state == nil then
    error("Fnac login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if logged_in_http() then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  for range = 3, 6 do
    local page = fyde.http.get(ORDERS_URL .. range)
    for _, order in ipairs(fyde.html.select(page.body, ".ma-Order")) do
      local link = fyde.html.select(order.html, ".ma-OrderDetails-Link[href^='javascript']")[1]
      local url = link and (link.attrs.href or ""):match("(https.*)'%)$")
      if url then
        local date = fyde.html.select(order.html, ".ma-OrderTop>div>div>span:nth-child(1)")[1]
        date = date and trim(date.text) or ""
        save_pdf(url, sanitize(date) .. "_Fnac_" .. (order.attrs["data-order-id"] or "commande") .. ".pdf", {
          name = "Facture Fnac " .. date,
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
