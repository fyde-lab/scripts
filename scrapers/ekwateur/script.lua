-- Scraper for ekWateur's customer area (mon-espace.ekwateur.fr), a green energy supplier:
-- downloads the bills and the proof of residence ("justificatif de domicile").
--
-- A Symfony login - `/se_connecter`
-- gives `_csrf_token`, then `/login_check` takes _username/_password/_mode=cXI4cE93PT0 (the
-- original implementation's own comment: "Why ? I don't know") and _csrf_token; the original implementation treated an HTTP
-- 500 as bad credentials (the login form being shown again is checked too). Bills: the rows
-- of `/mes_factures_et_acomptes` (date in the first cell, `td.table__body__price`, PDF in
-- `td.table__body__file > a`). The proof of residence is `/client/justificatif_de_domicile`.
-- Unverified (see README.md).

local M = {}

local BASE = "https://mon-espace.ekwateur.fr"
local LOGIN_URL = BASE .. "/se_connecter"
local BILLS_URL = BASE .. "/mes_factures_et_acomptes"

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
  local page = fyde.http.get(LOGIN_URL)
  local csrf = fyde.html.select(page.body, "input[name='_csrf_token']")[1]
  if not csrf then
    error("ekWateur login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(BASE .. "/login_check", {
    _username = params.username,
    _password = params.password,
    _mode = "cXI4cE93PT0",
    _csrf_token = csrf.attrs.value or "",
  })
  if resp.status == 500 or has(resp, "input[name='_password']") then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "td.table__body__file, a[href*='deconnexion'], a[href*='logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    fyde.http.get(BASE)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("Downloading bills")
  for _, row in ipairs(fyde.html.select(page.body, "tr")) do
    local link = fyde.html.select(row.html, "td.table__body__file > a")[1]
    local cells = fyde.html.select(row.html, "td")
    if link and link.attrs.href then
      local date = trim(cells[1].text)
      save_pdf(BASE .. trim(link.attrs.href), sanitize(date) .. "_ekwateur.pdf", {
        name = "Facture ekWateur " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  save_pdf(BASE .. "/client/justificatif_de_domicile", "attestation de contrat (justificatif de domicile).pdf", {
    name = "Justificatif de domicile ekWateur",
    type = "proof_of_residence",
    category = "housing",
    subcategory = "energy",
  })
  fyde.progress.step("Done")
end

return M
