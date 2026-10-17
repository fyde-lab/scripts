-- Scraper for Mediapart (mediapart.fr), the online newspaper: downloads the subscription
-- invoices.
--
-- Login posts `#logFormEl`
-- (name/password) from `www.mediapart.fr/login`; logged in shows an `a[href='/logout']` link.
-- Invoices: the `.billing__list__item` entries of `moncompte.mediapart.fr` with a
-- `/facture/<id>/telecharger` link, a "Du dd/mm/yyyy au dd/mm/yyyy" period and an amount.
-- Unverified (see README.md).

local M = {}

local ACCOUNT_URL = "https://moncompte.mediapart.fr/"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get("https://www.mediapart.fr/login")
  if not has(page, "#logFormEl") then
    error("Mediapart login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#logFormEl", { name = params.username, password = params.password })
  if not has(resp, "a[href='/logout']") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ACCOUNT_URL)
  if has(page, ".billing__list__item, a[href='/logout']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ACCOUNT_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, item in ipairs(fyde.html.select(page.body, ".billing__list__item")) do
    local id = item.html:match('href="/facture/(%d*)/telecharger"')
    if id then
      local s1, s2, s3, e1, e2, e3 = item.text:match("Du (%d%d)/(%d%d)/(%d%d%d%d) au (%d%d)/(%d%d)/(%d%d%d%d)")
      local start_date = s1 and (s3 .. "-" .. s2 .. "-" .. s1) or "?"
      local end_date = e1 and (e3 .. "-" .. e2 .. "-" .. e1) or "?"
      save_pdf("https://moncompte.mediapart.fr/facture/" .. id .. "/telecharger", "Facture Mediapart du " .. start_date .. " au " .. end_date .. " (" .. id .. ").pdf", {
        name = "Facture Mediapart " .. start_date .. " - " .. end_date,
        type = "invoice",
        category = "subscriptions",
        subcategory = "media",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
