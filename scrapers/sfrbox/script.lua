-- Scraper for SFR's fixed-line/box customer area (espace-client.sfr.fr), legacy box area:
-- downloads the box bills.
--
-- The CAS login page
-- (`www.sfr.fr/bounce?...casforcetheme=mire-sfr-et-moi`) gives the `lt` token (a `.g-recaptcha`
-- there means a captcha is required - CHALLENGE_ASKED), then `www.sfr.fr/cas/login?domain=
-- mire-sfr-et-moi&service=...` takes lt, execution=e1s1, _eventId=submit, username, password,
-- remember-me; the `#loginForm` still being shown means bad credentials. Bills:
-- `espace-client.sfr.fr/facture-fixe/consultation` (being redirected elsewhere means not
-- logged in), the latest in `#lastFacture a.sr-chevron`, older ones linked from
-- `table.sr-multi-payment tbody tr` (2nd cell) to pages with their own `a.sr-chevron`. See also
-- `sfr`, the newer browser-based port. Unverified (see README.md).

local M = {}

local BOUNCE_URL = "https://www.sfr.fr/bounce?target=//www.sfr.fr/sfr-et-moi/bounce.html&casforcetheme=mire-sfr-et-moi&mire_layer"
local CAS_URL = "https://www.sfr.fr/cas/login?domain=mire-sfr-et-moi&service=https://www.sfr.fr/accueil/j_spring_cas_security_check"
local CLIENT = "https://espace-client.sfr.fr"
local BILLS_URL = CLIENT .. "/facture-fixe/consultation"

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
  local page = fyde.http.get(BOUNCE_URL)
  if has(page, ".g-recaptcha") then
    error("SFR asks for a captcha (CHALLENGE_ASKED)")
  end
  local lt = fyde.html.select(page.body, "input[name='lt']")[1]
  if not lt then
    error("SFR login form (lt token) not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(CAS_URL, {
    lt = lt.attrs.value or "",
    execution = "e1s1",
    _eventId = "submit",
    username = params.username,
    password = params.password,
    ["remember-me"] = "on",
    identifier = "",
  })
  if has(resp, "#loginForm") then
    fail(INVALID_CREDENTIALS)
  end
end

local function bill_from(html, container, label)
  local block = fyde.html.select(html, container)[1]
  local link = block and fyde.html.select(block.html, "a.sr-chevron")[1]
  if not (link and link.attrs.href) then
    return
  end
  local date = (block.text:match("(%d%d/%d%d/%d%d%d%d)") or label)
  local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
  save_pdf(CLIENT .. link.attrs.href, (y and (y .. m .. d) or sanitize(date)) .. "_SFR_box.pdf", {
    name = "Facture SFR box " .. date,
    type = "invoice",
    category = "housing",
    subcategory = "internet",
  })
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if page.url:find("/facture-fixe/consultation", 1, true) and has(page, "#lastFacture, table.sr-multi-payment") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
    if not page.url:find("/facture-fixe/consultation", 1, true) then
      fail(INVALID_CREDENTIALS, "redirected away from the bills page after login")
    end
  end

  fyde.progress.step("Downloading bills")
  bill_from(page.body, "#lastFacture", "derniere")
  for _, row in ipairs(fyde.html.select(page.body, "table.sr-multi-payment tbody tr")) do
    local cells = fyde.html.select(row.html, "td")
    local link = cells[2] and fyde.html.select(cells[2].html, "a")[1]
    if link and link.attrs.href then
      local detail = fyde.http.get(CLIENT .. link.attrs.href)
      bill_from(detail.body, ".sr-container-wrapper-m", trim(cells[1].text))
    end
  end
  fyde.progress.step("Done")
end

return M
