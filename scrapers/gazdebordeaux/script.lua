-- Scraper for Gaz de Bordeaux's customer area (espaceclient.gazdebordeaux.fr): downloads the
-- gas/electricity bills.
--
-- Login posts `form#loginForm`
-- (username/password/rememberMe=N/submitButton) from `/login`; logged in shows an
-- `a[href='/logout']` link; "Aucun compte ne correspond à l'identifiant et au mot de passe
-- fournis" (or a "Ce champ est obligatoire" field error) means bad credentials. Bills: the
-- `form#BillsForm div.grid-item` blocks of `/invoice` (`span.invoice-code` date,
-- `span.invoice-price`, `ul.plan-features li:first-child` reference, `a.btn-info` PDF).
-- Unverified (see README.md).

local M = {}

local BASE = "https://espaceclient.gazdebordeaux.fr"

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
local contains = helpers.contains
local trim = helpers.trim
local sanitize = helpers.sanitize
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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/login")
  if not has(page, "form#loginForm") then
    error("Gaz de Bordeaux login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form#loginForm", {
    username = params.username,
    password = params.password,
    rememberMe = "N",
    submitButton = "Se connecter",
  })
  if not has(resp, "a[href='/logout']") then
    fail(INVALID_CREDENTIALS, contains(resp.body, "Aucun compte ne correspond") and "no matching account" or nil)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BASE .. "/invoice")
  if has(page, "a[href='/logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BASE .. "/invoice")
  end

  fyde.progress.step("Downloading bills")
  for _, item in ipairs(fyde.html.select(page.body, "form#BillsForm div.grid-item")) do
    local link = fyde.html.select(item.html, "a.btn-info")[1]
    local date = fyde.html.select(item.html, "span.invoice-code")[1]
    local ref = fyde.html.select(item.html, "ul.plan-features li:first-child")[1]
    if link and link.attrs.href then
      date = date and trim(date.text) or ""
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(BASE .. link.attrs.href, (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_gaz_de_bordeaux_facture_" .. sanitize(ref and ref.text or "") .. ".pdf", {
        name = "Facture Gaz de Bordeaux " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
