-- Scraper for e-Ticket by Qiis (eticket.qiis.fr), a school canteen/after-school billing
-- service: downloads the invoices and the family's documents.
--
-- `eticket-app.qiis.fr/api/v1/auth/
-- login?login=..&password=..&requestFirebaseCustomToken=true` answers `status: "Success"` and a
-- Firebase custom token (anything else = bad credentials), exchanged for an ID token at
-- Google's `identitytoolkit/v3/relyingparty/verifyCustomToken` (with the app's public API key).
-- The original implementation then spoke Firebase's realtime-database websocket protocol; this sandbox has no
-- websocket, so the same database is read through Firebase's REST API instead
-- (`qiis-eticket-production.firebaseio.com/<path>.json?auth=<ID token>`), with the
-- `metaManagerId`/`familyId` taken from the ID token's claims (what the websocket `auth`
-- answer returned): `/meta/<m>/family/<f>/invoice` (entries with an `attachment.url`) and
-- `/meta/<m>/family/<f>/document/native` (`dlUrl`). Tokens expire, so every run logs in again
-- unless the ID token kept in fyde.session still works. Unverified (see README.md).

local M = {}

local API_KEY = "AIzaSyDERcRUv900BN5lb4TIAFooo2aoqu4T32c"
local DB = "https://qiis-eticket-production.firebaseio.com"

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

-- A `kind:value` subject for fyde.save_document's `subjects`: who or what the document concerns
-- when the account covers several (`person`, `line`, `account`, `contract`, `place`, `vehicle`
-- or `trip`). The value is lowercased with runs of spaces/punctuation turned into "-"; nil for a
-- blank value, which a `subjects` list simply skips.
local function subject(kind, value)
  local slug = trim(value or ""):lower():gsub("[%s%p]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return nil
  end
  return kind .. ":" .. slug
end

-- Masks all but the last `keep` characters of an identifier (phone number, IBAN, contract
-- number...), enough to tell them apart without spelling them out in a subject.
local function mask(value, keep)
  value = (value or ""):gsub("%s", "")
  if #value <= keep then
    return value
  end
  return string.rep("x", #value - keep) .. value:sub(-keep)
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

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function claims(id_token)
  return json_or_nil(base64url_decode(id_token:match("^[^.]+%.([^.]+)") or "")) or {}
end

local function query(path, token)
  local resp = fyde.http.get(DB .. path .. ".json?auth=" .. token)
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("Logging in")
  local resp = fyde.http.get("https://eticket-app.qiis.fr/api/v1/auth/login?login=" .. url_encode(params.username)
    .. "&password=" .. url_encode(params.password) .. "&requestFirebaseCustomToken=true")
  if resp.status >= 500 then
    error("e-Ticket login answered HTTP " .. resp.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local body = json_or_nil(resp.body) or {}
  if body.status ~= "Success" or not body.firebaseCustomToken then
    fail(INVALID_CREDENTIALS, tostring(body.status))
  end
  local verify = fyde.http.post_json("https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyCustomToken?key=" .. API_KEY,
    { returnSecureToken = true, token = body.firebaseCustomToken })
  local id = (json_or_nil(verify.body) or {}).idToken
  if not id then
    error("could not exchange the e-Ticket token (HTTP " .. verify.status .. ")")
  end
  fyde.session.eticket_id_token = id
  return id
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local token = fyde.session.eticket_id_token
  local auth = token and claims(token) or {}
  local base = auth.metaManagerId and ("/meta/" .. auth.metaManagerId .. "/family/" .. tostring(auth.familyId))
  if base and query(base .. "/invoice", token) == 200 then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    token = login(params)
    auth = claims(token)
    if not auth.metaManagerId then
      error("the e-Ticket token carries no metaManagerId/familyId claims")
    end
    base = "/meta/" .. auth.metaManagerId .. "/family/" .. tostring(auth.familyId)
  end

  fyde.progress.step("Downloading invoices")
  local _, invoices = query(base .. "/invoice", token)
  for _, invoice in pairs(type(invoices) == "table" and invoices or {}) do
    if type(invoice) == "table" and invoice.attachment and invoice.attachment.url then
      local body = invoice.body or {}
      local date = tostring(body.invoiceDate or ""):sub(1, 10)
      save_pdf(invoice.attachment.url, date .. "_eTickets_" .. tostring((tonumber(body.totalAmountTTCCent) or 0) / 100) .. "EUR_" .. tostring(body.reference) .. ".pdf", {
        name = tostring(body.label or "Facture e-Ticket"),
        type = "invoice",
        category = "family",
        subcategory = "childcare_school",
      })
    end
  end

  fyde.progress.step("Downloading documents")
  local _, documents = query(base .. "/document/native", token)
  for _, doc in pairs(type(documents) == "table" and documents or {}) do
    if type(doc) == "table" and doc.dlUrl then
      save_pdf(doc.dlUrl, tostring(doc.name) .. ".pdf", {
        name = tostring(doc.name),
        category = "family",
        subcategory = "childcare_school",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
