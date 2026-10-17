-- Scraper for Bitiba (bitiba.fr), an online pet-supplies shop (zooplus group): downloads the
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

local BASE = "https://www.bitiba.fr"
local ORDERS_URL = BASE .. "/account/orders/overview"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local has = helpers.has
local save_pdf = helpers.save_pdf

local function is_logged_in(page)
  return has(page, "#year-selector-filter, .order-overview-table__row")
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get(BASE .. "/account")
  local page = fyde.http.get(BASE .. "/web/sso/login")
  local action = page.body:match('"actionUrl"%s*:%s*"([^"]+)"')
  if not action then
    error("Bitiba SSO login form (actionUrl) not found on " .. page.url)
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
  error("Bitiba login failed for an unknown reason (vendor down?)")
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
        save_pdf(BASE .. link.attrs.href, sanitize(date) .. "_bitiba_" .. number .. ".pdf", {
          name = "Facture Bitiba " .. date,
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
