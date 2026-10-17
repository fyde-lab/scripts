-- Scraper for zooplus (zooplus.fr), the online pet-supplies shop: downloads the
-- invoices of shipped orders.
--
-- `/account` then `/web/sso/login`
-- (a Keycloak page) whose inline JSON carries the form's `"actionUrl": "..."`; posting
-- username/password there answers a page containing `LOGIN_SUCCESS` on success, or an error
-- message `keycloak.login.error.invalid_credentials` / `...unknown_user` for bad credentials
-- (anything else is a vendor-side failure). Orders are listed per year from the
-- `#year-selector-filter` options of `/account/orders/overview`; each shipped
-- ("Commande expédiée") `.order-overview-table__row` has an `/account/orders/invoice...` link.
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.zooplus.fr"
local ORDERS_URL = BASE .. "/account/orders/overview"

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
local contains_any = helpers.contains_any
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

local function is_logged_in(page)
  return has(page, "#year-selector-filter, .order-overview-table__row")
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get(BASE .. "/account")
  local page = fyde.http.get(BASE .. "/web/sso/login")
  local action = page.body:match('"actionUrl"%s*:%s*"([^"]+)"')
  if not action then
    error("zooplus SSO login form (actionUrl) not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form((action:gsub("\\/", "/"):gsub("&amp;", "&")), {
    username = params.username,
    password = params.password,
    _target8 = "",
  })
  if resp.body:find("LOGIN_SUCCESS", 1, true) then
    return
  end
  if contains_any(resp.body, { "invalid_credentials", "unknown_user" }) then
    fail(INVALID_CREDENTIALS)
  end
  error("zooplus login failed for an unknown reason (vendor down?)")
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
  for _, option in ipairs(fyde.html.select(page.body, "#year-selector-filter option")) do
    local year_page = fyde.http.get(absolute(BASE, option.attrs.value))
    for _, row in ipairs(fyde.html.select(year_page.body, ".order-overview-table__row")) do
      local state = fyde.html.select(row.html, ".markMeIfFailed")[1]
      local link = fyde.html.select(row.html, "a[href^='/account/orders/invoice']")[1]
      if link and state and trim(state.text) == "Commande exp\195\169di\195\169e" then
        local date = fyde.html.select(row.html, ".col-xs-12.col-md-3:not(.keep-text-right) p")[1]
        local number = fyde.html.select(row.html, ".col-xs-12.col-md-4 a")[1]
        date = date and trim(date.text) or ""
        number = number and trim(number.text) or ""
        save_pdf(BASE .. link.attrs.href, sanitize(date) .. "_zooplus_" .. number .. ".pdf", {
          name = "Facture zooplus " .. date,
          type = "invoice",
          category = "shopping",
          subcategory = "pets",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
