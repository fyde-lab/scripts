-- Scraper for Numericable's customer area (moncompte.numericable.fr): downloads the bills.
--
-- The app key
-- is read from `#PostForm input[name="appkey"]` on `/pages/connection/Login.aspx`, then
-- `connexion.numericable.fr/Oauth/Oauth.php` (action=connect, linkSSO, appkey) and
-- `/Oauth/login/` (login/pwd) answer a page with `#accessToken` - no token means bad
-- credentials (LOGIN_FAILED) - which is posted back to `Login.aspx?link=HOME&accessToken=...`.
-- Bills: `/pages/billing/Invoice.aspx`, `#firstFact` (date in `h2 span`) and the other
-- `#facture > div` blocks (date in `h3`), each with an `a.linkBtn` PDF link. Numericable has
-- since been merged into SFR, so this site may be gone. Unverified (see README.md).

local M = {}

local ACCOUNT = "https://moncompte.numericable.fr"
local CONNECTION = "https://connexion.numericable.fr"
local BILLS_URL = ACCOUNT .. "/pages/billing/Invoice.aspx"

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
-- luacheck: pop

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(ACCOUNT .. "/pages/connection/Login.aspx")
  local appkey = fyde.html.select(page.body, "#PostForm input[name='appkey']")[1]
  if not appkey then
    error("Numericable login form (appkey) not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.http.post_form(CONNECTION .. "/Oauth/Oauth.php", {
    action = "connect",
    linkSSO = CONNECTION .. "/pages/connection/Login.aspx?link=HOME",
    appkey = appkey.attrs.value or "",
    isMobile = "",
  })
  local resp = fyde.http.post_form(CONNECTION .. "/Oauth/login/", { login = params.username, pwd = params.password })
  local token = fyde.html.select(resp.body, "#accessToken")[1]
  if not token or not token.attrs.value or token.attrs.value == "" then
    fail(INVALID_CREDENTIALS, "no access token issued")
  end
  fyde.http.post_form(ACCOUNT .. "/pages/connection/Login.aspx?link=HOME&accessToken=" .. token.attrs.value, {})
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "#firstFact, #facture") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("Downloading bills")
  for _, block in ipairs(fyde.html.select(page.body, "#firstFact, #facture > div")) do
    local link = fyde.html.select(block.html, "a.linkBtn")[1]
    local title = fyde.html.select(block.html, "h2 span, h3")[1]
    local date = title and title.text:match("(%d%d/%d%d/%d%d%d%d)") or ""
    if link and link.attrs.href and date ~= "" then
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(ACCOUNT .. link.attrs.href, "Numericable-" .. y .. "-" .. m .. "-" .. d .. ".pdf", {
        name = "Facture Numericable " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "internet",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
