-- Scraper for Thomann (thomann.de), the music-instrument retailer: downloads order invoices.
--
-- Ported from github.com/konnectors/thomann (src/index.js): the French index page for cookies,
-- then `/fr/mythomann_login.html` takes uname/passw/loginpermanent/o/logintry/usezip; not
-- landing on `/fr/mythomann.html` means bad credentials. Orders: the `.mythomann-order-teaser`
-- blocks of `/fr/mythomann_orderlist.html` ("Commande <n> Prix total <amount> € ... du
-- dd.mm.yyyy", details link), paginated by `#order-list .fx-pagination__pages-button` after the
-- active one; each details page has an `a.mythomann-order-history__entry-pdf-button` invoice.
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.thomann.de"
local LOGIN_URL = BASE .. "/fr/mythomann_login.html"
local ACCOUNT_URL = BASE .. "/fr/mythomann.html"
local ORDERS_URL = BASE .. "/fr/mythomann_orderlist.html"

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper ported from github.com/konnectors - see README.md).
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

-- Port of cozy-konnector-libs' `signin({ formSelector })`: reads the first form matching
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
-- luacheck: pop

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get(BASE .. "/fr/index.html")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "input[name='passw']") then
    error("Thomann login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(LOGIN_URL, {
    uname = params.username,
    passw = params.password,
    loginpermanent = "on",
    o = LOGIN_URL,
    logintry = "1",
    usezip = "0",
  })
  if resp.url ~= ACCOUNT_URL then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local check = fyde.http.get(ACCOUNT_URL)
  if check.url == ACCOUNT_URL and not has(check, "input[name='passw']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local page = fyde.http.get(ORDERS_URL)
  for _ = 1, 50 do
    for _, teaser in ipairs(fyde.html.select(page.body, ".mythomann-order-teaser")) do
      local details = fyde.html.select(teaser.html, ".mythomann-order-teaser__details-wrapper > a")[1]
      local text = teaser.text:gsub("%s+", " ")
      local number = text:match("Commande ([%d%.]+)") or "commande"
      local day, month, year = text:match("du (%d+)%.(%d+)%.(%d+)")
      if details and details.attrs.href then
        local detail = fyde.http.get(absolute(BASE, details.attrs.href))
        local pdf = fyde.html.select(detail.body, "a.mythomann-order-history__entry-pdf-button")[1]
        if pdf and pdf.attrs.href then
          save_pdf(absolute(BASE, pdf.attrs.href), (year and (year .. "-" .. month .. "-" .. day) or "") .. "_thomann_" .. number .. ".pdf", {
            name = "Facture Thomann " .. number,
            type = "other_invoice",
            source_category = "shopping",
            purpose = "invoice",
          })
        end
      end
    end
    local buttons = fyde.html.select(page.body, "#order-list > .fx-pagination > .fx-pagination__pages > .fx-pagination__pages-button")
    local next_url
    for i, button in ipairs(buttons) do
      if (button.attrs.class or ""):find("fx-pagination__pages-button--active", 1, true) and buttons[i + 1] then
        next_url = buttons[i + 1].attrs.href
      end
    end
    if not next_url then
      break
    end
    page = fyde.http.get(BASE .. next_url)
  end
  fyde.progress.step("Done")
end

return M
