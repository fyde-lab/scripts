-- Scraper for Silae (silaexpert01.fr), the payroll software's employee space: downloads the
-- payslips.
--
-- Ported from github.com/konnectors/silae (src/index.js), which spoke SOAP to the SWS web
-- service (`/Silae/SWS/SWS.asmx`): `SWS_SiteLoginEx` (SWSLogin/SWSPassword empty, USRLogin,
-- USRPassword) is called on silaexpert01.fr, then again on the returned
-- `AdresseFermeDistante`, then on its `RepartiteurAdresse`, which answers the `Token` and the
-- first tab's `ID_DOMAINE`/`ID_PAISALARIE`; an `Error` in the result means bad credentials.
-- `SWS_UtilisateurSalarieListeBulletins` lists the payslips (`ID_PAIBULLETIN`, `BUL_Periode`)
-- and `SWS_UtilisateurSalarieRecupererImage` (NatureImage=1) returns each as a base64 `Image`.
-- fyde.http can't post a raw SOAP envelope, so this port uses ASMX's plain HTTP-POST binding of
-- the same operations (`/SWS.asmx/<operation>`, form-encoded parameters, XML answer) - which
-- only works if the server enables that binding (unconfirmed). Unverified (see README.md).

local M = {}

local PATH = "/Silae/SWS/SWS.asmx/"

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

local function base64url_decode(s)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  s = s:gsub("-", "+"):gsub("_", "/"):gsub("[^%w%+/]", "")
  local bits = s:gsub(".", function(c)
    local v = alphabet:find(c, 1, true) - 1
    local out = ""
    for i = 6, 1, -1 do
      out = out .. ((v >> (i - 1)) & 1)
    end
    return out
  end)
  return (bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
    if #byte ~= 8 then
      return ""
    end
    return string.char(tonumber(byte, 2))
  end))
end


local function call(host, operation, form)
  local resp = fyde.http.post_form("https://" .. host .. PATH .. operation, form)
  return resp.status, resp.body or ""
end

local function field(xml, name)
  return xml:match("<" .. name .. ">(.-)</" .. name .. ">")
end

local function site_login(host, params)
  local status, xml = call(host, "SWS_SiteLoginEx", { SWSLogin = "", SWSPassword = "", USRLogin = params.username, USRPassword = params.password })
  if status >= 500 or status == 404 then
    error("Silae web service answered HTTP " .. status .. " on " .. host .. " (HTTP-POST binding disabled?)")
  end
  local err = field(xml, "Error")
  if err and trim(err) ~= "" then
    fail(INVALID_CREDENTIALS, trim(err))
  end
  return xml
end

function M.run(params)
  -- SWS tokens are per call chain, so there is no reusable session: valid credentials are
  -- checked first by a cheap login on the entry host.
  fyde.progress.step("Logging in")
  local first = site_login("www.silaexpert01.fr", params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  local farm = field(first, "AdresseFermeDistante")
  if not farm then
    error("Silae login answered no AdresseFermeDistante")
  end
  local dispatcher = field(site_login(farm, params), "RepartiteurAdresse")
  local final = site_login(dispatcher, params)
  local token, domain, employee = field(final, "Token"), field(final, "ID_DOMAINE"), field(final, "ID_PAISALARIE")
  if not token then
    error("Silae login answered no token")
  end

  fyde.progress.step("Downloading payslips")
  local _, list = call(dispatcher, "SWS_UtilisateurSalarieListeBulletins", { Token = token, ID_DOMAINE = domain, ID_PAISALARIE = employee })
  for element in list:gmatch("<CPAISWSUtilisateurSalarieListeBulletinsElement>(.-)</CPAISWSUtilisateurSalarieListeBulletinsElement>") do
    local id, period = field(element, "ID_PAIBULLETIN"), (field(element, "BUL_Periode") or ""):sub(1, 10)
    local _, image = call(dispatcher, "SWS_UtilisateurSalarieRecupererImage",
      { Token = token, ID_DOMAINE = domain, ID_PAISALARIE = employee, NatureImage = "1", ID_IMAGE = id or "" })
    local pdf = field(image, "Image")
    pdf = pdf and base64url_decode(pdf)
    if pdf and pdf:sub(1, 4) == "%PDF" then
      fyde.save_document("bulletin_" .. period:gsub("-", "_") .. ".pdf", pdf, {
        name = "Bulletin de paie " .. period:sub(1, 7),
        type = "pay_sheet",
        source_category = "employer",
        purpose = "employment",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
