-- Scraper for O2 (o2.fr), the home-services company (cleaning, child care): downloads the
-- monthly invoices.
--
-- Login is the WordPress AJAX action
-- `ask_login` (login/pwd) on `client.o2.fr/wp-admin/admin-ajax.php`, answering JSON whose
-- `state` is "success" (anything else = bad credentials). Invoices: `/factures/` gives the
-- `#agence_id` and the years (`.year_invoice option`); the AJAX action `invoiceByYear`
-- (agenceId, year) lists them as `li a` links whose href embeds a JSON with the period's
-- `endDate`. Unverified (see README.md).

local M = {}

local BASE = "https://client.o2.fr"
local AJAX = BASE .. "/wp-admin/admin-ajax.php"

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
local absolute = helpers.absolute

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/connexion/")
  if page.status >= 500 then
    error("O2 answered HTTP " .. page.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(AJAX, { action = "ask_login", login = params.username, pwd = params.password })
  local json = json_or_nil(trim(resp.body))
  if not json then
    error("unexpected O2 login answer (vendor down?)")
  end
  if json.state ~= "success" then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BASE .. "/factures/")
  if has(page, "#agence_id") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BASE .. "/factures/")
  end

  fyde.progress.step("Downloading invoices")
  local agency = fyde.html.select(page.body, "#agence_id")[1]
  agency = agency and trim(agency.text) or ""
  for _, option in ipairs(fyde.html.select(page.body, ".year_invoice option")) do
    local list = fyde.http.post_form(AJAX, { action = "invoiceByYear", agenceId = agency, year = option.attrs.value or "" })
    for _, link in ipairs(fyde.html.select(list.body, "li a")) do
      local href = link.attrs.href or ""
      local end_date = href:match("endDate['\"]?%s*:%s*['\"](%d%d%d%d%-%d%d)")
      save_pdf(BASE .. href, (end_date or sanitize(link.text)) .. "_o2.pdf", {
        name = "Facture O2 " .. (end_date or trim(link.text)),
        type = "invoice",
        category = "housing",
        subcategory = "home_services",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
