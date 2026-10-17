-- Scraper for Materiel.net (materiel.net), the computer-hardware retailer: downloads the
-- invoices of completed orders.
--
-- The home page,
-- the newsletter form and `/form/login` (an XHR fragment) are loaded for cookies and the
-- `__RequestVerificationToken`, then `/form/submit_login` takes Email/Password/
-- LongAuthenticationDuration; a successful login sets the `Identity`/`Customer` cookies
-- (the original implementation failed with LOGIN_FAILED when they were missing; fyde.http can't read
-- cookies, so here the login answer's own error flag/message is used, then the orders call
-- must work). Orders: `secure.materiel.net/Orders/CompletedOrdersPeriodSelection` (JSON
-- periods) -> `PartialCompletedOrdersHeader` (Duration/Value) -> one `div.historic` per order
-- whose `a.collapsed` detail page has the `.o-btn--pdf` invoice link. Unverified (see
-- README.md).

local M = {}

local WWW = "https://www.materiel.net"
local SECURE = "https://secure.materiel.net"
local XHR = { ["x-requested-with"] = "XMLHttpRequest" }

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
local json_or_nil = helpers.json_or_nil

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

local function periods()
  local resp = fyde.http.post_form(SECURE .. "/Orders/CompletedOrdersPeriodSelection", {}, XHR)
  local data = resp.status == 200 and json_or_nil(resp.body)
  -- Logged out, this answers 200 with `{"redirectUrl": ".../Login/Login"}` instead of the list.
  if type(data) ~= "table" or data.redirectUrl then
    return nil
  end
  return data
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get(WWW)
  fyde.http.post_form(WWW .. "/form/newsletter/subscribe", {}, XHR)
  local page = fyde.http.get(WWW .. "/form/login", XHR)
  local token = fyde.html.select(page.body, "input[name='__RequestVerificationToken']")[1]
  if not token then
    error("Materiel.net login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(WWW .. "/form/submit_login", {
    __RequestVerificationToken = token.attrs.value or "",
    Email = params.username,
    Password = params.password,
    LongAuthenticationDuration = "false",
  }, XHR)
  local answer = json_or_nil(resp.body) or {}
  if resp.status == 401 or answer.Success == false or answer.success == false or answer.IsValid == false
    or contains_any(resp.body, { "identifiants incorrects", "mot de passe incorrect", "invalid" }) then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local list = periods()
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = periods()
    if not list then
      -- No Identity/Customer cookies: the original implementation's LOGIN_FAILED case.
      fail(INVALID_CREDENTIALS, "orders not reachable after login")
    end
  end

  fyde.progress.step("Downloading invoices")
  for _, period in ipairs(list) do
    local page = fyde.http.post_form(SECURE .. "/Orders/PartialCompletedOrdersHeader",
      { Duration = tostring(period.Duration), Value = tostring(period.Value) }, XHR)
    for _, order in ipairs(fyde.html.select(page.body, "div.historic")) do
      local link = fyde.html.select(order.html, "a.collapsed")[1]
      local date = fyde.html.select(order.html, ".historic-cell--date")[1]
      local ref = fyde.html.select(order.html, ".historic-cell--ref")[1]
      if link and link.attrs.href then
        local detail = fyde.http.post_form(SECURE .. link.attrs.href:gsub("#.*$", ""), {}, XHR)
        local pdf = fyde.html.select(detail.body, ".o-btn--pdf")[1]
        if pdf and pdf.attrs.href then
          local d, m, y = (date and date.text or ""):match("(%d+)/(%d+)/(%d+)")
          save_pdf(SECURE .. pdf.attrs.href, (y and (y .. "-" .. m .. "-" .. d) or "commande") .. "_Materiel.net_" .. sanitize(ref and ref.text or "") .. ".pdf", {
            name = "Facture Materiel.net " .. (date and trim(date.text) or ""),
            type = "invoice",
            category = "shopping",
            subcategory = "online",
          })
        end
      end
    end
  end
  fyde.progress.step("Done")
end

return M
