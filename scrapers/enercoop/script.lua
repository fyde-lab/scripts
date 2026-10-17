-- Scraper for Enercoop's customer area (mon-espace.enercoop.fr), the cooperative green
-- electricity supplier: downloads the bills.
--
-- A Rails/Devise
-- login - `/clients/sign_in`'s `#new_ecppp_client` form (authenticity_token,
-- `ecppp_client[email]`, `ecppp_client[password]`, `ecppp_client[remember_me]`). The original implementation
-- treated any non-200 answer as LOGIN_FAILED; Devise also re-renders the form with a flash
-- message on bad credentials, which is checked too. Bills: `/factures` has one link per year
-- (`div.dropdown.dropdown-top a`); each year page has `.table-line-collapse > .row` rows reading
-- "<year> - <month>Réf. Facture<ref>Total TTC<amount>", the PDF being
-- `/invoice/<ref>/pdf?invoice_type=factures`. Unverified (see README.md).

local M = {}

local BASE = "https://mon-espace.enercoop.fr"
local LOGIN_URL = BASE .. "/clients/sign_in"
local BILLS_URL = BASE .. "/factures"
local LOGIN_FORM = "#new_ecppp_client"
local MONTHS = { "janvier", "f\195\169vrier", "mars", "avril", "mai", "juin", "juillet", "ao\195\187t", "septembre", "octobre", "novembre", "d\195\169cembre" }

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
local sanitize = helpers.sanitize
local absolute = helpers.absolute
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
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, LOGIN_FORM) then
    error("Enercoop login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, {
    ["ecppp_client[email]"] = params.username,
    ["ecppp_client[password]"] = params.password,
    ["ecppp_client[remember_me]"] = "true",
    commit = "Se connecter",
  })
  if resp.status ~= 200 or has(resp, LOGIN_FORM) then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "a[href*='sign_out'], div.dropdown.dropdown-top") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("Downloading bills")
  for _, year_link in ipairs(fyde.html.select(page.body, "div.dropdown.dropdown-top a")) do
    local year_page = fyde.http.get(absolute(BASE, year_link.attrs.href))
    for _, row in ipairs(fyde.html.select(year_page.body, "div.table-line.table-line-collapse.js-accordion-trigger > div.row")) do
      local text = row.text:gsub("%s+", "")
      local year, month, ref, amount = text:match("^(%d%d%d%d)%-(.-)R\195\169f%.Facture([%u%d%-]*)TotalTTC([%d,]*)")
      if ref and ref ~= "" then
        local month_number = 0
        for i, name in ipairs(MONTHS) do
          if name == month then
            month_number = i
          end
        end
        save_pdf(BASE .. "/invoice/" .. ref .. "/pdf?invoice_type=factures", string.format("%s%02d_enercoop_%s.pdf", year, month_number, ref), {
          name = "Facture Enercoop " .. month .. " " .. year .. " (" .. amount .. " €)",
          type = "invoice",
          category = "housing",
          subcategory = "energy",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
