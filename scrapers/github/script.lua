-- Scraper for GitHub (github.com): downloads the billing receipts of the account (or of an
-- organization).
--
-- A session is valid when `/pulls`
-- answers. Login posts the page's `form` (login/password) from
-- `/login`; landing on `/sessions/two-factor` means a 2FA code is required (posted as
-- `app_otp` from that page's form - landing back on `https://github.com/` means success, so
-- anything else is MFA_FAILED), landing on `https://github.com/` means logged in, anything
-- else bad credentials. GitHub may also send a device-verification e-mail code
-- (`/sessions/verified-device`, `otp` field), handled the same way. Receipts:
-- `/account/billing/history` (or `/organizations/<org>/billing/history` when the optional
-- `organization` parameter names an org the account follows), `.payment-history .succeeded` and
-- `.refunded` rows (`td.id code`, `td.date time[title]`, `td.receipt a`). GitHub's billing
-- pages have since been redesigned, so these selectors may be outdated. Unverified (see
-- README.md).

local M = {}

local BASE = "https://github.com"

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

local function handle_code(page)
  local path = page.url:match("^https://github%.com(/sessions/[%w%-]+)")
  local field = path == "/sessions/verified-device" and "otp" or "app_otp"
  local code = ask_code("Code de vérification GitHub")
  local resp = submit_form(page, "form[action*='" .. path .. "'], form", { [field] = code })
  if resp.url ~= BASE .. "/" then
    fail(MFA_FAILED, "landed on " .. resp.url)
  end
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/login")
  if not has(page, "input[name='password']") then
    error("GitHub login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form[action='/session'], form", { login = params.username, password = params.password })
  if resp.url:find("/sessions/two-factor", 1, true) or resp.url:find("/sessions/verified-device", 1, true) then
    handle_code(resp)
  elseif resp.url ~= BASE .. "/" then
    fail(INVALID_CREDENTIALS, "landed on " .. resp.url)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local pulls = fyde.http.get(BASE .. "/pulls")
  if pulls.status == 200 and not pulls.url:find("/login", 1, true) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading receipts")
  local path = "/account/billing/history"
  if params.organization and params.organization ~= "" then
    local profile = fyde.http.get(BASE .. "/" .. params.username)
    for _, org in ipairs(fyde.html.select(profile.body, "a[data-hovercard-type=organization][itemprop=follows]")) do
      if org.attrs.href == "/" .. params.organization then
        path = "/organizations/" .. params.organization .. "/billing/history"
      end
    end
  end
  local page = fyde.http.get(BASE .. path)
  for _, row in ipairs(fyde.html.select(page.body, ".payment-history .succeeded, .payment-history .refunded")) do
    local id = fyde.html.select(row.html, "td.id code")[1]
    local time = fyde.html.select(row.html, "td.date time")[1]
    local receipt = fyde.html.select(row.html, "td.receipt a")[1]
    if receipt and receipt.attrs.href then
      local date = time and (time.attrs.title or ""):sub(1, 10) or ""
      save_pdf(BASE .. receipt.attrs.href, date .. "_Github_" .. (id and trim(id.text) or "receipt") .. ".pdf", {
        name = "Reçu GitHub " .. date,
        type = "invoice",
        category = "subscriptions",
        subcategory = "cloud_software",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
