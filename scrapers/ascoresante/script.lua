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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
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
  fyde.progress.step("checking_session")
  local page = fyde.http.get(REFUNDS_URL)
  if has(page, LOGGED_IN) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(REFUNDS_URL)
  end

  fyde.progress.step("downloading_documents")
  local rows = fyde.html.select(page.body, "table#remboursements > tbody > tr")
  for i, row in ipairs(rows) do
    local cells = fyde.html.select(row.html, "td")
    local link = cells[8] and fyde.html.select(cells[8].html, "a")[1]
    if link and link.attrs.href then
      local date = trim(cells[2].text)
      local number = trim(cells[3].text)
      fyde.progress.update(i, #rows)
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
  fyde.progress.step("done")
end

return M
