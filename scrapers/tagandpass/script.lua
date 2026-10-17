-- Scraper for TAG & Pass (tag.fr), Grenoble's public-transport mobility account: downloads the
-- monthly invoices.
--
-- The login form of
-- `www.tag.fr/171-votre-compte-pass-mobilites.htm` (ECN_EMAIL, ECN_PASSWORD, login, idtf=171,
-- from, TPL_CODE=TPL_TAGANDGO) answers, on success, a page with an `a.disconnected` link and an
-- `iframe` whose `src` carries a `token=` for the tag-and-pass.tag.fr API (no such link/iframe
-- = bad credentials). Invoices: `tag-and-pass.tag.fr/api/factures` with `Authorization: Bearer
-- <token>` (date, montant in cents, numero, urlPdf); each `urlPdf` answers JSON whose
-- `content` is the base64 PDF. The token is kept in fyde.session to skip the login while still
-- accepted. Unverified (see README.md).

local M = {}

local LOGIN_URL = "https://www.tag.fr/171-votre-compte-pass-mobilites.htm"
local API = "https://tag-and-pass.tag.fr"

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


local function invoices(token)
  local resp = fyde.http.get(API .. "/api/factures", { Authorization = "Bearer " .. token, Accept = "application/json" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  return type(data) == "table" and data or nil
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "input[name='ECN_PASSWORD']") then
    error("TAG login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(LOGIN_URL, {
    ECN_EMAIL = params.username,
    ECN_PASSWORD = params.password,
    login = "Accédez à votre espace",
    idtf = "171",
    from = LOGIN_URL,
    TPL_CODE = "TPL_TAGANDGO",
  })
  local iframe = fyde.html.select(resp.body, "iframe")[1]
  local src = iframe and iframe.attrs.src
  if #fyde.html.select(resp.body, "a.disconnected") ~= 1 or not src or not src:find("token=", 1, true) then
    fail(INVALID_CREDENTIALS)
  end
  fyde.http.get(src)
  fyde.session.tagandpass_token = src:match("token=([^&]+)")
  return fyde.session.tagandpass_token
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local token = fyde.session.tagandpass_token
  local list = token and invoices(token)
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    token = login(params)
    list = invoices(token) or {}
  end

  fyde.progress.step("Downloading invoices")
  for _, item in ipairs(list) do
    if item.urlPdf then
      local file = json_or_nil(fyde.http.get(API .. item.urlPdf, { Authorization = "Bearer " .. token }).body)
      local pdf = file and file.content and base64url_decode(file.content)
      if pdf and pdf:sub(1, 4) == "%PDF" then
        local amount = string.format("%.2f", (tonumber(item.montant) or 0) / 100)
        fyde.save_document(tostring(item.date) .. "_tagandpass_" .. amount .. "EUR_" .. tostring(item.numero) .. ".pdf", pdf, {
          name = "Facture TAG " .. tostring(item.date),
          type = "invoice",
          category = "transport",
          subcategory = "road",
        })
      else
        fyde.log.warn("invoice " .. tostring(item.numero) .. " did not decode to a PDF")
      end
    end
  end
  fyde.progress.step("Done")
end

return M
