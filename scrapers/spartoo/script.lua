-- Scraper for Spartoo (spartoo.com), the shoe/fashion retailer: downloads order invoices.
--
-- Login posts `.loginContent form`
-- (email_address/password) from `/securelogin.php?from=compte`; success lands on
-- `/compte.php` with an `a.deconnect` link. Orders: the `tbody tr:not(.headingTable)` rows of
-- `/ajax/compte/compte_historique.php?type=article` (date, ..., amount), whose link's onclick
-- carries the `<param>=<order id>` used by `/facturesclient.php?...`. Unverified (see
-- README.md).

local M = {}

local BASE = "https://www.spartoo.com"
local HISTORY_URL = BASE .. "/ajax/compte/compte_historique.php?type=article"

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
  local page = fyde.http.get(BASE .. "/securelogin.php?from=compte")
  if not has(page, ".loginContent form") then
    error("Spartoo login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, ".loginContent form", { email_address = params.username, password = params.password })
  if not (has(resp, "a.deconnect") and resp.url == BASE .. "/compte.php") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if has(fyde.http.get(BASE .. "/compte.php"), "a.deconnect") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local page = fyde.http.get(HISTORY_URL)
  for _, row in ipairs(fyde.html.select(page.body, "tbody tr:not(.headingTable)")) do
    local link = fyde.html.select(row.html, "a[onclick]")[1]
    local cells = fyde.html.select(row.html, "td")
    local order = link and (link.attrs.onclick or ""):match("&([^']+)'")
    if order and cells[2] then
      local date = trim(cells[2].text)
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(BASE .. "/facturesclient.php?" .. order, (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_spartoo_" .. sanitize(trim(link.text):match("^(%S+)") or "") .. ".pdf", {
        name = "Facture Spartoo " .. date,
        type = "invoice",
        source_category = "shopping",
        purpose = "invoice",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
