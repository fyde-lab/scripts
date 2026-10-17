-- Scraper for Wanimo (wanimo.com), the online pet-supplies shop: downloads order invoices.
--
-- Login posts `#connect-form`
-- (`sign_in_by_email[email]`, `[password]`, `[_token]`) from `/fr/compte/identification`; logged
-- in shows `a[href$="/fr/compte/deconnexion"]` links. Orders: the `.orders-table .row` entries of
-- `/fr/compte/mes-commandes/` (`.commande` number, `.date`, `.price`, invoice in
-- `.actions :nth-child(2) a`). Unverified (see README.md).

local M = {}

local BASE = "https://www.wanimo.com/fr/compte"
local ORDERS_URL = BASE .. "/mes-commandes/"
local LOGGED_IN = "a[href$='/fr/compte/deconnexion']"

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
local trim = helpers.trim
local sanitize = helpers.sanitize

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
  local page = fyde.http.get(BASE .. "/identification")
  if not has(page, "#connect-form") then
    error("Wanimo login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#connect-form", {
    ["sign_in_by_email[email]"] = params.username,
    ["sign_in_by_email[password]"] = params.password,
  })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if has(page, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, row in ipairs(fyde.html.select(page.body, ".orders-table .row")) do
    local link = fyde.html.select(row.html, ".actions :nth-child(2) a, .actions a[href*='facture']")[1]
    local number = fyde.html.select(row.html, ".commande")[1]
    local date = fyde.html.select(row.html, ".date")[1]
    if link and link.attrs.href then
      local id = number and trim(number.text:gsub("Commande N\194\176", "")) or "commande"
      local d, m, y = (date and date.text or ""):match("(%d+)/(%d+)/(%d+)")
      save_pdf(absolute("https://www.wanimo.com/", link.attrs.href), (y and (y .. "-" .. m .. "-" .. d) or "") .. "_wanimo_" .. sanitize(id) .. ".pdf", {
        name = "Facture Wanimo " .. id,
        type = "invoice",
        category = "shopping",
        subcategory = "pets",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
