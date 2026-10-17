-- Scraper for MGEN's member space (mgen.fr/mon-espace-perso): downloads the health
-- reimbursement statements.
--
-- Drives `fyde.browser`: `/login-adherent/` now lands on a Keycloak
-- login (connexion.mgen.fr, `#kc-form-login` with `#username`/`#password` and `#kc-login`); a
-- wrong login shows "Email de connexion ou mot de passe invalide" (in `#input-error-password`,
-- checked live) - it used to be `#user`/`#pass`/`#loginBtn` with `.alert-danger`; logged in shows `.deconnexion_auth_link` (or
-- the `.btn-logout-group` link), and `/mon-espace-perso/` then lists the last reimbursements in
-- `#tableDernierRemboursement` (`.ligne-remboursement` rows: treatment date, beneficiary, PDF
-- link, payment date, amount), paginated by `#tableDernierRemboursement_next`. The original implementation
-- also generated the "attestation de droits" and the mutual card through api.mgen.fr with a
-- token from localStorage, which this sandbox can't read - not ported. Unverified (see
-- README.md).

local M = {}

local BASE = "https://www.mgen.fr"
local LOGIN_URL = BASE .. "/login-adherent/"
local ACCOUNT_URL = BASE .. "/mon-espace-perso/"
local LOGGED_IN = { "logged_in", selector = ".deconnexion_auth_link, .btn-logout-group > a" }
local LOGIN_FORM = "#kc-form-login"
local BAD_CREDENTIALS = { "mot de passe invalide" }

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
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait

-- Fills the first present selector of each candidate list.
local function fill_first(selectors, value)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:fill(selector, value)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

local function click_first(selectors)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:click(selector)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

-- Clicks `selector` (a download link/button) and saves what the browser downloads.
local function browser_save(selector, filename, fields)
  local ok, bytes = pcall(function()
    return fyde.browser:download(selector, 60000)
  end)
  if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
    fyde.save_document(sanitize(filename), bytes, fields)
    return true
  end
  fyde.log.warn("could not download " .. filename .. ": " .. tostring(ok and "not a PDF" or bytes))
  return false
end
-- luacheck: pop

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM .. " #password" } }, 30000) ~= "login" then
    error("MGEN login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(LOGIN_FORM .. " #username", params.username)
  fyde.browser:fill(LOGIN_FORM .. " #password", params.password)
  fyde.browser:click("#kc-login")
  local state = wait_state({ LOGGED_IN, { "error", text = BAD_CREDENTIALS } }, 45000)
  if state == "logged_in" then
    return
  elseif state == "error" or present(LOGIN_FORM .. " #password") then
    local alert = fyde.html.select(page_html(), "#input-error-password")[1]
    fail(INVALID_CREDENTIALS, alert and trim(alert.text) or "still on the login form")
  end
  error("MGEN login did not complete - page says: " .. page_text():sub(1, 300))
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(ACCOUNT_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading reimbursement statements")
  open_and_wait(ACCOUNT_URL, { { "table", selector = "#tableDernierRemboursement, #noRembFocus" } }, 30000)
  local seen = {}
  for _ = 1, 50 do
    for _, row in ipairs(fyde.html.select(page_html(), ".ligne-remboursement")) do
      local cells = fyde.html.select(row.html, "td")
      local link = cells[3] and fyde.html.select(cells[3].html, "a[href]")[1]
      if link and not seen[link.attrs.href] then
        seen[link.attrs.href] = true
        local date = trim(cells[1].text)
        local amount = cells[5] and trim(cells[5].text):match("^[^\n]*") or ""
        browser_save("a[href='" .. link.attrs.href .. "']", sanitize(date) .. "_MGEN_" .. sanitize(amount) .. ".pdf", {
          name = "Remboursement MGEN " .. date,
          type = "reimbursement_statement",
          category = "health",
          subcategory = "complementary_health",
        })
      end
    end
    if not present("#tableDernierRemboursement_next:not(.disabled)") then
      break
    end
    fyde.browser:click("#tableDernierRemboursement_next")
    sleep(2000)
  end
  fyde.progress.step("Done")
end

return M
