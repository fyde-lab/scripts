-- Scraper for Viasanté Mutuelle's member area (adherent.viasante.fr, formerly
-- adherent.mutuelle-viasante.fr): downloads the mail documents (reimbursement statements,
-- certificates...) of every contract.
--
-- The original JSON login
-- (`POST /api/identity/login` with {userName, password}) is gone: `GET /api/identity/login` now
-- redirects to an IdentityServer page (`/identity/account/login`, `form#login-form` with
-- `username`/`password`/`button=login`) that answers a wrong login with "Aucun compte n'est
-- associé à cet identifiant ou le mot de passe entré est incorrect" (checked live, with made-up
-- credentials), and a good one with a `form_post` to `/signin-oidc` (unconfirmed). Then
-- `/api/adherent/contrats` lists the contracts (numContrat, souscripteur.numPers), and
-- `/api/adherent/courriers/list?startDate=..&endDate=..` (headers X-NumContrat/X-NumPers) the
-- documents (id, fileName, type, creationDate), each served by `/api/adherent/courriers/
-- document?fileName=..&numContrat=..&codeCentreGestion=VIASANTE&docId=..&type=..`. The
-- original implementation also matched payments to the "PRESTATIONS" mails as bill metadata - not ported.
-- Unverified (see README.md).

local M = {}

local BASE = "https://adherent.viasante.fr"
local LOGIN_FORM = "form#login-form"
local BAD_CREDENTIALS = { "Aucun compte n’est associé", "Aucun compte n'est associé", "mot de passe entré est incorrect" }

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

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function contracts()
  local resp = fyde.http.get(BASE .. "/api/adherent/contrats", { Accept = "application/json" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  return data and data.contrats
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/api/identity/login")
  if not has(page, LOGIN_FORM .. " input[name='password']") then
    error("Viasanté login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { username = params.username, password = params.password, button = "login" })
  if contains_any(resp.body, BAD_CREDENTIALS) or has(resp, LOGIN_FORM .. " input[name='password']") then
    fail(INVALID_CREDENTIALS)
  end
  -- response_mode=form_post: the identity server answers with a self-submitting form carrying
  -- the authorization code to /signin-oidc, which a browser would post on its own.
  if has(resp, "form[action*='signin-oidc']") then
    submit_form(resp, "form[action*='signin-oidc']", {})
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local list = contracts()
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = contracts()
    if not list then
      fail(INVALID_CREDENTIALS, "contracts not reachable after login")
    end
  end

  fyde.progress.step("Downloading documents")
  for _, contract in ipairs(list) do
    local number = tostring(math.tointeger(tonumber(contract.numContrat)) or contract.numContrat)
    local person = tostring(contract.souscripteur and contract.souscripteur.numPers or "")
    local headers = { ["X-NumContrat"] = number, ["X-NumPers"] = person, Accept = "application/json" }
    local docs = json_or_nil(fyde.http.get(BASE .. "/api/adherent/courriers/list?startDate=2000-01-01T00:00:00.000Z&endDate=2099-12-31T00:00:00.000Z", headers).body) or {}
    for _, doc in ipairs(docs) do
      local date = tostring(doc.creationDate):sub(1, 10)
      save_pdf(BASE .. "/api/adherent/courriers/document?fileName=" .. url_encode(doc.fileName) .. "&numContrat=" .. number
        .. "&codeCentreGestion=VIASANTE&docId=" .. tostring(doc.id) .. "&type=" .. url_encode(doc.type),
        date .. "_viasante_" .. tostring(doc.id) .. ".pdf", {
          name = "Viasanté " .. tostring(doc.type) .. " " .. date,
          type = doc.type == "PRESTATIONS" and "health_invoice" or "other_health_document",
          source_category = "insurance",
          source_sub_category = "health",
        }, { ["Content-Type"] = "application/json" })
    end
  end
  fyde.progress.step("Done")
end

return M
