-- Scraper for Free Mobile's customer area (mobile.free.fr/account): downloads every line's
-- monthly bills.
--
-- A NextAuth
-- login - `/account/v2/login/` for cookies, `/account/v2/api/auth/csrf` for `csrfToken`, then
-- `/account/v2/api/auth/callback/credentials` with username (digits only)/password (HTTP 401 =
-- bad credentials), then the same endpoint with the SMS `codeOtp` (401 = wrong code, up to 3
-- tries). Logged in when `/account/conso-et-factures` shows a "Déconnexion" button. Bills: the
-- latest (`a[download]`, `h3[class*="font-bold"]` "... - <month> <year>") and older ones
-- (`#invoices li`: `h3` month, `div > a` link), per line (`li.user a` when
-- `#multi-ligne-selector` is present). Unverified (see README.md).

local M = {}

local BASE = "https://mobile.free.fr"
local CALLBACK = BASE .. "/account/v2/api/auth/callback/credentials"
local MAIN_URL = BASE .. "/account/conso-et-factures"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local absolute = helpers.absolute
local has = helpers.has
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function is_logged_in(page)
  for _, button in ipairs(fyde.html.select(page.body, "button")) do
    if contains(button.text, "D\195\169connexion") then
      return true
    end
  end
  return false
end

local function login(params)
  fyde.progress.step("Logging in")
  if not tostring(params.username):match("^%d+$") then
    fail(INVALID_CREDENTIALS, "the Free Mobile login is a number")
  end
  local page = fyde.http.get(BASE .. "/account/v2/login/")
  if page.status >= 400 then
    error("Free Mobile login page answered HTTP " .. page.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local csrf = (json_or_nil(fyde.http.get(BASE .. "/account/v2/api/auth/csrf").body) or {}).csrfToken
  if not csrf then
    error("Free Mobile returned no CSRF token")
  end
  local resp = fyde.http.post_form(CALLBACK, {
    username = params.username,
    password = params.password,
    redirect = "false",
    csrfToken = csrf,
    callbackUrl = BASE .. "/account/v2/login",
    json = "true",
  })
  if resp.status == 401 then
    fail(INVALID_CREDENTIALS)
  elseif resp.status >= 400 then
    error("Free Mobile login answered HTTP " .. resp.status)
  end
  for try = 1, 3 do
    local code = ask_code("Code reçu par SMS de Free Mobile")
    resp = fyde.http.post_form(CALLBACK, {
      codeOtp = code,
      redirect = "false",
      isTrusted = "false",
      csrfToken = csrf,
      callbackUrl = BASE .. "/account/v2/otp",
      json = "true",
    })
    if resp.status < 400 then
      return
    elseif resp.status ~= 401 then
      error("Free Mobile OTP check answered HTTP " .. resp.status)
    end
    fyde.log.warn("wrong code (try " .. try .. "/3)")
  end
  fail(MFA_FAILED, "three wrong SMS codes")
end

local function save_bill(href, label, line)
  local month = label:gsub("^.*%-", "")
  save_pdf(BASE .. href, line .. "_" .. sanitize(trim(month)) .. "_freemobile.pdf", {
    name = "Facture Free Mobile " .. trim(month) .. " (" .. line .. ")",
    type = "invoice",
    category = "telecom",
    subcategory = "mobile",
  })
end

local function save_page_bills(page, line)
  local latest = fyde.html.select(page.body, "a[download]")[1]
  local title = fyde.html.select(page.body, "h3[class*='font-bold']")[1]
  if latest and latest.attrs.href then
    save_bill(latest.attrs.href, title and title.text or "derniere", line)
  end
  for _, item in ipairs(fyde.html.select(page.body, "#invoices li")) do
    local link = fyde.html.select(item.html, "div > a")[1]
    local h3 = fyde.html.select(item.html, "h3")[1]
    if link and link.attrs.href then
      save_bill(link.attrs.href, h3 and h3.text or "", line)
    end
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(MAIN_URL)
  if is_logged_in(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(MAIN_URL)
    if not is_logged_in(page) then
      error("no logout button after a successful login")
    end
  end

  fyde.progress.step("Downloading bills")
  if has(page, "#multi-ligne-selector") then
    for _, user in ipairs(fyde.html.select(page.body, "li.user")) do
      local link = fyde.html.select(user.html, "a")[1]
      local number = (user.text:match("0%d %d%d %d%d %d%d %d%d") or "ligne"):gsub(" ", "")
      if link and link.attrs.href then
        save_page_bills(fyde.http.get(absolute(BASE .. "/account/", link.attrs.href)), number)
      end
    end
  else
    local msisdn = fyde.html.select(page.body, "#user-msisdn")[1]
    save_page_bills(page, msisdn and (msisdn.text:gsub("%s", "")) or "ligne")
  end
  fyde.progress.step("Done")
end

return M
