-- Scraper for Lucca (lucca.fr), the HR software ("Pagga" payslips module): downloads the
-- employee's payslips.
--
-- Unless the company's instance URL is
-- given (`loginUrl` parameter, e.g. https://acme.ilucca.net), it is looked up by posting
-- mail/password/request=emailpass to `www.lucca.fr/login/ws-auth-service/wsauth.service.php`
-- (HTTP 404 "Wrong password" = bad credentials), which also gives the user's login. Then
-- `<instance>/login` takes login/Password/PersistentCookie ("Vos identifiants sont erronés" =
-- bad credentials). Payslips: `/api/v3/users/me?fields=id`, then `/api/v3/payslips?fields=id,
-- import[endDate]&...&ownerID=<id>`, each PDF at `/pagga/services/download/<id>`; an HTTP 400
-- mentioning a "6 digit security code" means the account requires a 2FA code the original implementation
-- couldn't provide (USER_ACTION_NEEDED.TWOFA_NEEDED) - reported here as MFA_FAILED. The instance
-- URL is kept in fyde.session to check for a still-valid session. Unverified (see README.md).

local M = {}

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

local function me(instance)
  local resp = fyde.http.get(instance .. "/api/v3/users/me?fields=id", { Accept = "application/json" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  return data and data.data and data.data.id
end

local function login(params)
  fyde.progress.step("Logging in")
  local instance, user = params.loginUrl, params.username
  if not instance or instance == "" then
    local resp = fyde.http.post_form("https://www.lucca.fr/login/ws-auth-service/wsauth.service.php",
      { mail = params.username, password = params.password, request = "emailpass" }, { Accept = "application/json" })
    fyde.log.info("LOGIN_PAGE_FOUND")
    if resp.status == 404 and contains(resp.body, "Wrong password") then
      fail(INVALID_CREDENTIALS)
    end
    local details = json_or_nil(resp.body)
    local u = details and details.data and details.data.user
    if not (u and u.instance and u.instance.href) then
      error("could not find the Lucca instance of this account (HTTP " .. resp.status .. ")")
    end
    instance, user = u.instance.href:gsub("/$", ""), u.login
  else
    instance = instance:gsub("/$", "")
    local page = fyde.http.get(instance .. "/login")
    if page.status >= 400 then
      error("Lucca login page answered HTTP " .. page.status)
    end
    fyde.log.info("LOGIN_PAGE_FOUND")
  end
  local resp = fyde.http.post_form(instance .. "/login", { login = user, Password = params.password, PersistentCookie = "true" })
  if resp.status == 400 and contains(resp.body, "Vos identifiants sont erron") then
    fail(INVALID_CREDENTIALS)
  end
  fyde.session.lucca_instance = instance
  return instance
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local instance = fyde.session.lucca_instance
  local id = instance and me(instance)
  if id then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    instance = login(params)
    id = me(instance)
    if not id then
      fail(INVALID_CREDENTIALS, "not logged in after posting the credentials")
    end
  end

  fyde.progress.step("Downloading payslips")
  local list = json_or_nil(fyde.http.get(instance .. "/api/v3/payslips?fields=id,import[endDate]&orderby=import.endDate,desc,import.startDate,desc,import.creationDate,desc&ownerID=" .. id,
    { Accept = "application/json" }).body) or {}
  local items = list.data and list.data.items or {}
  for i, payslip in ipairs(items) do
    local url = instance .. "/pagga/services/download/" .. tostring(payslip.id)
    if i == 1 then
      local probe = fyde.http.get(url)
      if probe.status == 400 and contains(probe.body, "6 digit security code") then
        fail(MFA_FAILED, "Lucca requires a 6-digit security code to download payslips")
      end
    end
    local month = tostring(payslip.import and payslip.import.endDate or ""):sub(1, 7):gsub("-", "_")
    save_pdf(url, month .. ".pdf", {
      name = "Bulletin de paie " .. month:gsub("_", "/"),
      type = "payslip",
      category = "work",
      subcategory = "payslips",
    })
  end
  fyde.progress.step("Done")
end

return M
