-- Scraper for APRR's toll-badge customer area, now Fulli (www.fulli.com, which replaced APRR's
-- espaceclient.aprr.fr and Mango Mobilités in 2023): downloads the toll-badge invoices.
--
-- The original ASP.NET espaceclient.aprr.fr now just
-- redirects to a dead mango-mobilitesbyaprr.com host (its TLS certificate doesn't match). Rebuilt
-- against the live site: `www.fulli.com/customer/login` hands over to a Keycloak SSO
-- (sso.aprr.fr, realm `Clients`) whose login is passwordless - `form#kc-form-identifier` takes
-- the email/customer number, then `form#kc-otp-form` asks for a 6-digit code sent by email
-- ("si une adresse e-mail correspond", so an unknown identifier is never reported as such: a
-- wrong login surfaces as MFA_FAILED, not INVALID_CREDENTIALS). A rejected code re-renders the
-- OTP form with "Le code est invalide ou a expiré.". The password parameter is unused.
-- Confirmed against the live site: the SSO hand-over, both forms and the rejected-code answer.
-- Not verified (no account): the page a successful login lands on and where invoices are
-- listed - invoices are looked for as PDF/"facture" links on that page (see README.md).

local M = {}

local ORIGIN = "https://www.fulli.com"
local LOGIN_URL = ORIGIN .. "/customer/login"
local SSO_HOST = "sso.aprr.fr"
local IDENTIFIER_FORM = "form#kc-form-identifier"
local OTP_FORM = "form#kc-otp-form"
local BAD_CODE = { "code est invalide", "a expiré" }

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

local function on_sso(page)
  return contains(page.url, SSO_HOST)
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, IDENTIFIER_FORM) then
    error("Fulli login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  page = submit_form(page, IDENTIFIER_FORM, { identifier = params.username })
  if not has(page, OTP_FORM) then
    error("Fulli did not ask for the emailed code after the identifier (landed on " .. page.url .. ")")
  end
  local code = ask_code("Code de vérification reçu par e-mail de Fulli (APRR)")
  page = submit_form(page, OTP_FORM, { otp = code, form_action = "" })
  if has(page, OTP_FORM) or on_sso(page) then
    fail(MFA_FAILED, contains_any(page.body, BAD_CODE) and "code rejected by Fulli" or "still on the SSO after the code")
  end
  return page
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  -- With a session, the login link no longer hands over to the SSO.
  local page = fyde.http.get(LOGIN_URL)
  if not on_sso(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    page = login(params)
  end

  fyde.progress.step("Downloading invoices")
  local seen, count = {}, 0
  for _, link in ipairs(fyde.html.select(page.body, "a[href]")) do
    local href = link.attrs.href or ""
    local text = trim(link.text or "")
    if (href:lower():find("%.pdf") or contains_any(href .. " " .. text, { "facture", "invoice" })) and not seen[href] then
      seen[href] = true
      count = count + 1
      local label = text ~= "" and text or tostring(count)
      save_pdf(absolute(page.url, href), "fulli_" .. sanitize(label) .. ".pdf", {
        name = "Facture Fulli (APRR) " .. label,
        type = "invoice",
        category = "transport",
        subcategory = "road",
      })
    end
  end
  if count == 0 then
    fyde.log.warn("no invoice link found on " .. page.url)
  end
  fyde.progress.step("Done")
end

return M
