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
local fail = helpers.fail
local sanitize = helpers.sanitize
local base64url_decode = helpers.base64url_decode

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
