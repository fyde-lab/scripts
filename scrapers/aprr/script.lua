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
local contains = helpers.contains
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has

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
