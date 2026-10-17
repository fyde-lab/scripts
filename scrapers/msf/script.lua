-- Scraper for Médecins Sans Frontières' donor area (don.msf.fr): downloads the tax receipts
-- ("reçus fiscaux") of donations.
--
-- Login posts the page's `form`
-- (email/password) from `/donateur/index.php`; logged in shows an
-- `a[href='/donateur/deconnexion.php']` link. Donations: POST anneeDon=tous/typeDon=tous to
-- `/donateur/historic.php?ent_codsoc=ASSO`, one `#bloc_central table table table` per year
-- with "DON" rows and, when available, a receipt link whose page redirects (inline script) to a
-- page holding `#lien_download`. Unverified (see README.md).

local M = {}

local BASE = "https://don.msf.fr"
local LOGGED_IN = "a[href='/donateur/deconnexion.php']"

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
local trim = helpers.trim
local sanitize = helpers.sanitize
local read_form = helpers.read_form

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/donateur/index.php")
  if not has(page, "input[name='password']") then
    error("MSF login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { email = params.username, password = params.password })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if has(fyde.http.get(BASE .. "/donateur/index.php"), LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading tax receipts")
  local page = fyde.http.post_form(BASE .. "/donateur/historic.php?ent_codsoc=ASSO", { anneeDon = "tous", typeDon = "tous" })
  for _, tbl in ipairs(fyde.html.select(page.body, "#bloc_central table table table")) do
    local link = fyde.html.select(tbl.html, "tr td a")[1]
    if link and link.attrs.href then
      local redirect = fyde.http.get(BASE .. link.attrs.href)
      local target = redirect.body:match('<script[^>]*>[^"]*"([^"]+)"')
      local final = target and fyde.http.get(BASE .. "/donateur/" .. target)
      local download = final and fyde.html.select(final.body, "#lien_download")[1]
      if download and download.attrs.href then
        save_pdf(BASE .. "/donateur/" .. download.attrs.href, sanitize(link.text) .. ".pdf", {
          name = "Reçu fiscal MSF " .. trim(link.text),
          type = "tax_certificate",
          category = "donations",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
