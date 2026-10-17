-- Scraper for Ascore Santé's member area (ascoregestion.com/assure), a health-insurance
-- (mutuelle) manager: downloads the reimbursement statements ("décomptes").
--
-- Login posts `form#form_auth`
-- (login/password) from `/assure/connexion`; a session is valid when a logout link
-- (`a[href=".../assure/logout"]`) is rendered. Each row of `table#remboursements` links (8th
-- cell) to a details page whose `div.row > div.col-sm-4 a` is the statement PDF.
-- Unverified against the live site (see README.md).

local M = {}

local BASE = "https://www.ascoregestion.com/assure"
local LOGIN_URL = BASE .. "/connexion"
local REFUNDS_URL = BASE .. "/remboursements"
local LOGGED_IN = "a[href='" .. BASE .. "/logout'], a[href='/assure/logout']"
local LOGIN_FORM = "form#form_auth"

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
local submit_form = helpers.submit_form
local has = helpers.has

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
    error("Ascore login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { login = params.username, password = params.password })
  if not has(resp, LOGGED_IN) then
    fail(INVALID_CREDENTIALS, "no logout link after login")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(REFUNDS_URL)
  if has(page, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(REFUNDS_URL)
  end

  fyde.progress.step("Downloading reimbursement statements")
  local rows = fyde.html.select(page.body, "table#remboursements > tbody > tr")
  for i, row in ipairs(rows) do
    local cells = fyde.html.select(row.html, "td")
    local link = cells[8] and fyde.html.select(cells[8].html, "a")[1]
    if link and link.attrs.href then
      local date = trim(cells[2].text)
      local number = trim(cells[3].text)
      fyde.progress.update(i, #rows, date)
      local details = fyde.http.get(absolute(page.url, link.attrs.href))
      local pdf = fyde.html.select(details.body, "div.row > div.col-sm-4 a")[1]
      if pdf and pdf.attrs.href then
        local d, m, y = date:match("(%d%d)/(%d%d)/(%d%d%d%d)")
        save_pdf(absolute(details.url, pdf.attrs.href), (y and (y .. m .. d) or date) .. "_" .. number .. ".pdf", {
          name = "Décompte Ascore Santé " .. date,
          type = "reimbursement_statement",
          category = "health",
          subcategory = "complementary_health",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
