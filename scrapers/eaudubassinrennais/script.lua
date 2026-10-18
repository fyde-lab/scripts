-- Scraper for "Mon Espace" / "Agence en Ligne", the customer portal of Eau du Bassin Rennais
-- (monespace.eaudubassinrennais.fr), a French water utility.
--
-- The portal is a server-rendered Java webapp (Struts-style *.action/*.external endpoints,
-- JSESSIONID cookie) - plain HTTP + HTML parsing is enough, no JS engine needed. The login
-- form's onsubmit handler ("submitAuthForm", in utils.js) looks like it encrypts the password
-- (the POST target is literally "encryptionCheck.external" and the page loads md5.js), but all
-- it actually does is copy the plaintext password into a hidden "j_password" field and blank out
-- the visible "password" one - so this script posts the plaintext password directly, same as
-- the real login form ends up doing.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.progress, fyde.save_document.

local M = {}

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local BASE = "https://monespace.eaudubassinrennais.fr"
local HOME_URL = BASE .. "/wp/home.action"
local LOGIN_URL = BASE .. "/wp/encryptionCheck.external"

-- The authenticated dashboard's top menu (confirmed from a real login's home.action body) has
-- a single "factures" (bills) entry pointing here - no other document-shaped section exists.
-- showDisplayBills.action is just the page shell; the actual bill rows are loaded into it via
-- a separate AJAX call to displayBills.action (see its "$('#billsBlockContainer').load(...)").
local SECTIONS = {
  { slug = "bills", url = BASE .. "/wp/displayBills.action" },
}

--- Logged out if the login form (name="loginForm") is still present in the page - the portal
--- re-renders the same home.action URL with either the login form or the authenticated
--- dashboard depending on session state, so this is the only reliable signal available before
--- the authenticated menu structure is known.
local function is_logged_in(html)
  return html:find('name="loginForm"', 1, true) == nil
end

--- True when the page is showing the "wrong credentials" error after a failed login attempt.
local function has_invalid_credentials_error(html)
  return html:find("Utilisateur ou mot de passe invalide", 1, true) ~= nil
end

--- Resolves a possibly-relative href found on `page_url` into an absolute URL.
local function resolve_url(page_url, href)
  if href:match("^https?://") then
    return href
  end
  local dir = page_url:match("(.*/)") or (BASE .. "/wp/")
  return dir .. href
end

local function sanitize(name)
  name = name:gsub("%s+", " ")
  name = name:match("^%s*(.-)%s*$")
  name = name:gsub('[<>:"/\\|%?%*]', "_")
  name = name:gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

--- #billTable's rows have no stable column ids/classes beyond the "action" cell holding the
--- buildBillPdf.action link, so this walks each <td> in document order: date, reference,
--- amount, then the action cell last.
local function extract_bills(html)
  local bills = {}
  local rows = fyde.html.select(html, "table#billTable tbody tr")
  for _, row in ipairs(rows) do
    local href = row.html:match('href="(buildBillPdf%.action%?id=[^"]+)"')
    if href then
      local date = row.html:match("<td[^>]*>%s*([%d/]+)%s*</td>")
      local ref = row.html:match("<td[^>]*>%s*[%d/]+%s*</td>%s*<td[^>]*>%s*(%d+)%s*</td>")
      table.insert(bills, { href = href, date = date or "unknown-date", ref = ref or "unknown-ref" })
    end
  end
  return bills
end

local function login(username, password)
  return fyde.http.post_form(LOGIN_URL, {
    j_username = username,
    j_password = password,
    password = "",
  })
end

function M.run(params)
  local username = params.username
  local password = params.password

  -- fyde.http's cookie jar is restored from the previous run's saved cookies before this script
  -- even starts, so a still-valid JSESSIONID can land us on the authenticated dashboard here,
  -- skipping the login POST entirely.
  fyde.progress.step("checking_session")
  local check = fyde.http.get(HOME_URL)
  if is_logged_in(check.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    fyde.progress.step("logging_in")
    if check.body:find('name="loginForm"', 1, true) then
      fyde.log.info("LOGIN_PAGE_FOUND")
    end
    local login_resp = login(username, password)
    if login_resp.status >= 400 then
      error("login request failed with HTTP status " .. login_resp.status)
    end

    check = fyde.http.get(HOME_URL)
    if has_invalid_credentials_error(check.body) then
      fyde.log.warn("login failed: invalid username or password")
      error("INVALID_CREDENTIALS", 0)
    end
    if not is_logged_in(check.body) then
      error("login failed: still showing a login page after authenticating")
    end
    fyde.log.info("login succeeded")
  end

  for _, section in ipairs(SECTIONS) do
    fyde.progress.step("downloading_documents")
    local page = fyde.http.get(section.url)
    if not is_logged_in(page.body) then
      fyde.log.warn("session was logged out while browsing " .. section.slug .. ", stopping")
      break
    end

    local bills = extract_bills(page.body)
    fyde.log.info(string.format("%s: %d document(s) found", section.slug, #bills))

    for i, bill in ipairs(bills) do
      fyde.progress.update(i, #bills, bill.date)

      local url = resolve_url(section.url, bill.href)
      local download = fyde.http.download(url)

      if download.status == 200 and not download.content_type:find("html", 1, true) then
        local filename = section.slug .. "/" .. sanitize(bill.date) .. "_" .. sanitize(bill.ref) .. ".pdf"
        fyde.save_document(filename, download.body, {
          name = "Facture " .. bill.date,
          type = "invoice",
          category = "housing",
          subcategory = "water",
        })
      else
        fyde.log.warn(string.format(
          "failed to download bill '%s' (status %d, content-type %s)",
          bill.date, download.status, download.content_type
        ))
      end
    end
  end

  fyde.progress.step("done")
end

return M
