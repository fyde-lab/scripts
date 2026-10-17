-- Scraper for Cultura (cultura.com), the culture/leisure retailer: downloads order invoices.
--
-- A Magento login - `#login-form`
-- (`login[username]`/`login[password]`) on `/customer/account/`; logged in shows a
-- `.disconnect` link, errors are in `.account-login .error-msg`. Orders: the
-- `#my-orders-table .action-link` links of `/sales/order/history`; each order page has its
-- date and number in `.title-buttons li:first-child` ("Date de la commande <d> <mois> <yyyy>,
-- n°<id>"), its total in `.total-row` and the invoice in `#my-orders-table .table-link`.
-- Cultura's site has since been rebuilt, so this may be outdated. Unverified (see README.md).

local M = {}

local BASE = "https://www.cultura.com"
local ACCOUNT_URL = BASE .. "/customer/account/"

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(ACCOUNT_URL)
  if not has(page, "#login-form") then
    error("Cultura login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#login-form", { ["login[username]"] = params.username, ["login[password]"] = params.password })
  if not has(resp, ".disconnect") then
    local err = fyde.html.select(resp.body, ".account-login .error-msg")[1]
    fail(INVALID_CREDENTIALS, err and trim(err.text))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if has(fyde.http.get(ACCOUNT_URL), ".disconnect") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local history = fyde.http.get(BASE .. "/sales/order/history")
  for _, link in ipairs(fyde.html.select(history.body, "#my-orders-table .action-link")) do
    local order = fyde.http.get(absolute(BASE, link.attrs.href))
    local title = fyde.html.select(order.body, ".title-buttons li:first-child")[1]
    local invoice = fyde.html.select(order.body, "#my-orders-table .table-link")[1]
    if invoice and invoice.attrs.href then
      local text = title and trim(title.text) or ""
      local date = text:match("commande%s+(.-),") or ""
      local number = text:match("n\194\176%s*(%S+)") or "commande"
      save_pdf(absolute(BASE, invoice.attrs.href), sanitize(date) .. "_" .. number .. "_cultura.pdf", {
        name = "Facture Cultura " .. date,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
