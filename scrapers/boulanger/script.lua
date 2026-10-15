-- Scraper for Boulanger (boulanger.com), the electronics/home-appliance retailer: downloads
-- order invoices.
--
-- Login posts
-- `form[name="BLAuthenticationForm"]` (`email.value`/`password.value`) from the
-- `/authentication?action=logon...` page; it failed (LOGIN_FAILED) when the login block
-- `div.mp.login` is still shown. Orders come from `BLAccountOrdersHistoryCmd?purchase=allYear`:
-- each `.order-merchant` block has a `.verifyCredentials` link (`data-modal-url`, rewritten from
-- DisplayStoreSequencesFacturePDF to DisplayStoreFacturePDF + `&sequence=001`, or `href`).
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.boulanger.com"
local SERVLET = BASE .. "/webapp/wcs/stores/servlet/"
local LOGIN_URL = BASE .. "/authentication?action=logon&catalogId=10001&storeId=10001&langId=-2"
local ORDERS_URL = SERVLET .. "BLAccountOrdersHistoryCmd?purchase=allYear&store=store-site"
local LOGIN_FORM = "form[name='BLAuthenticationForm']"

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

local function is_logged_in(page)
  return page.status == 200 and not has(page, "div.mp.login") and not has(page, LOGIN_FORM)
    and (has(page, ".order-merchant") or contains(page.body, "Vous n'avez pas r\195\169alis\195\169 d'achat"))
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM) then
    error("Boulanger login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { ["email.value"] = params.username, ["password.value"] = params.password })
  if has(resp, "div.mp.login") then
    fail(INVALID_CREDENTIALS, "login block still shown")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if is_logged_in(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, order in ipairs(fyde.html.select(page.body, ".order-merchant")) do
    local link = fyde.html.select(order.html, ".verifyCredentials")[1]
    if link then
      local url
      if link.attrs["data-modal-url"] then
        url = SERVLET .. link.attrs["data-modal-url"]:gsub("DisplayStoreSequencesFacturePDF", "DisplayStoreFacturePDF") .. "&sequence=001"
      elseif link.attrs.href then
        url = SERVLET .. link.attrs.href
      end
      local ref = fyde.html.select(order.html, ".number > b")[1]
      local infos = fyde.html.select(order.html, ".order-head > .infos-purchase b")
      local date = infos[1] and trim(infos[1].text) or ""
      local amount = infos[2] and trim(infos[2].text):gsub("%s", "") or ""
      if url then
        save_pdf(url, sanitize(date) .. "_" .. amount .. "_" .. (ref and trim(ref.text) or "") .. ".pdf", {
          name = "Facture Boulanger " .. date,
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
