-- Scraper for Harmonie Mutuelle's member space (harmonie-et-moi.fr): downloads the health
-- documents and contract documents.
--
-- Drives `fyde.browser`: `/identification` shows either the
-- logged-in home (`.home-page-title`) or a `.already-an-account-button` leading to the
-- `#username`/`#password` form. Documents are under "Mes documents" (`a[href*="/mes-documents"]`
-- -> `.list-documents-flex-container`); the original implementation read their list from intercepted API
-- answers and downloaded them from `hapiour.harmonie-mutuelle.fr/adherent-api/v1/document/<id>`
-- with the `_cap_token` from localStorage - neither is reachable from this sandbox, so this port
-- clicks each document's download control in the list instead. Unverified (see README.md).

local M = {}

local LOGIN_URL = "https://harmonie-et-moi.fr/identification"
local DOCS_URL = "https://harmonie-et-moi.fr/mes-documents"
local LOGGED_IN = { "logged_in", selector = ".home-page-title, #logout, button[routerlink='/mon-profil']" }
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "incorrect", "invalide", "erron" }

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
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait

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
  if present(".already-an-account-button") then
    fyde.browser:click(".already-an-account-button")
  end
  if wait_state({ { "form", selector = "#username" } }, 30000) ~= "form" then
    error("Harmonie Mutuelle login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("#username", params.username)
  fyde.browser:fill("#password", params.password)
  click_first({ "button[type='submit']", "input[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "bad", selector = ".error, .alert-danger, [role='alert']" } }, 45000)
  if state == "logged_in" then
    return
  end
  if (state == "bad" and contains_any(page_text(), BAD_CREDENTIALS)) or present("#password") then
    fail(INVALID_CREDENTIALS, page_text():sub(1, 200))
  end
  error("Harmonie Mutuelle login did not complete - page says: " .. page_text():sub(1, 300))
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local state = open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = ".already-an-account-button, #username" } }, 30000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
  open_and_wait(DOCS_URL, { { "docs", selector = ".list-documents-flex-container" } }, 30000)
  sleep(3000)
  local html = page_html()
  local items = fyde.html.select(html, ".list-documents-flex-container a[href], .list-documents-flex-container button[id]")
  for i, item in ipairs(items) do
    local selector = item.attrs.href and ("a[href='" .. item.attrs.href .. "']") or ("#" .. item.attrs.id)
    browser_save(selector, "harmonie_" .. sanitize(trim(item.text) ~= "" and trim(item.text) or tostring(i)) .. ".pdf", {
      name = "Document Harmonie Mutuelle " .. trim(item.text),
      type = "medical_document",
      category = "health",
      subcategory = "complementary_health",
    })
  end
  fyde.progress.step("Done")
end

return M
