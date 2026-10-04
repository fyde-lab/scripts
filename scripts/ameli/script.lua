-- Scraper for the "compte ameli" personal space (assure.ameli.fr), the French public health
-- insurance (Assurance Maladie / CPAM) site.
--
-- UNVERIFIED SCAFFOLD - unlike didaxis.lua and impots.lua, the login flow and document
-- selectors below have NOT been confirmed against the live site. assure.ameli.fr runs bot
-- protection (Akamai-style) that returns a "Request Rejected" page to the plain HTTP client
-- used to write didaxis.lua/impots.lua, and there was no test account available to drive the
-- real flow by hand through a browser's devtools (the approach both of those scripts note they
-- used). Finishing this script requires:
--   1. Logging into a real compte ameli account through an actual browser with devtools open,
--      to capture the real login POST target, form field names, and any OTP/2FA step.
--   2. Doing the same for the personal-space pages listing documents ("Mes paiements" /
--      decomptes de remboursement, "Mes attestations"), to get real selectors and PDF link
--      patterns to replace the TODOs below.
--   3. Checking the response for the bot-protection challenge path (the WAF responds instead
--      of the real page to some request shapes) and adjusting headers/order of requests so
--      fyde.http - with no JS engine or browser fingerprint beyond wreq's Chrome emulation -
--      doesn't trip it.
--
-- Everything here only calls into the `fyde` host table, implemented by fyde-sdk's scrapers
-- domain (see ../sdk/src/domains/scrapers/host/*.rs): fyde.log, fyde.http, fyde.html,
-- fyde.progress, fyde.input, fyde.save_document.

local M = {}

local BASE = "https://assure.ameli.fr"
-- TODO: confirm the real login entrypoint (publicly known to live somewhere under
-- BASE .. "/PortailAS/" - the exact path and query params need to be captured from a live
-- browser session, not guessed).
local LOGIN_URL = BASE .. "/PortailAS/appmanager/PortailAS/assure"

-- TODO: confirm the real personal-space section URLs once logged in. "Mes paiements"
-- (decomptes de remboursement) and "Mes attestations" are the two document sections the
-- public site exposes; the slugs/paths below are placeholders.
local SECTIONS = {
  { slug = "decomptes", url = BASE .. "/PortailAS/paiements.do" },
  { slug = "attestations", url = BASE .. "/PortailAS/attestations.do" },
}

local FORBIDDEN_PATTERNS = { "deconnexion", "logout", "/deco" }

local function matches_any(haystack, patterns)
  local lower = haystack:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function sanitize(name)
  name = name:gsub("%s+", " ")
  name = name:match("^%s*(.-)%s*$")
  name = name:gsub('[<>:"/\\|%?%*]', "_")
  name = name:gsub("%c", "")
  if #name > 150 then
    name = name:sub(1, 150)
  end
  if name == "" then
    name = "document"
  end
  return name
end

--- Resolves a possibly-relative href found on `page_url` into an absolute URL.
local function resolve_url(page_url, href)
  if href:match("^https?://") then
    return href
  end
  if href:sub(1, 1) == "/" then
    return BASE .. href
  end
  local dir = page_url:match("(.*/)") or (BASE .. "/")
  return dir .. href
end

-- TODO: replace with the bot-protection challenge page's real marker once seen live (e.g. a
-- page title or a known script src), so a blocked request fails loudly instead of being
-- misread as "logged out".
local function is_bot_challenge(html)
  return html:find("Request Rejected", 1, true) ~= nil
end

-- TODO: replace with the real login form's marker, the same way didaxis.lua/impots.lua detect
-- their own login pages (an element id, a piece of text only the login page shows).
local function is_logged_in(html)
  return not html:find('id="formulaireConnexion"', 1, true)
end

-- TODO: confirm the real field names (likely an identifiant/NIR + password pair) and whether
-- there's an intermediate step (captcha, OTP) the way impots.lua's idp has.
local function login(identifiant, password)
  return fyde.http.post_form(LOGIN_URL, {
    identifiant = identifiant,
    password = password,
  })
end

-- TODO: confirm the real selectors for document links once a real logged-in page is captured
-- - this is a placeholder mirroring didaxis.lua/impots.lua's "any PDF-looking link" heuristic.
local function extract_documents(html)
  local docs = {}
  local seen = {}
  local anchors = fyde.html.select(html, "a[href]")
  for _, anchor in ipairs(anchors) do
    local href = anchor.attrs.href or ""
    if href ~= "" and not matches_any(href, FORBIDDEN_PATTERNS) and href:lower():find(".pdf", 1, true) then
      if not seen[href] then
        seen[href] = true
        local text = anchor.text:match("^%s*(.-)%s*$")
        if text == "" then
          text = "document"
        end
        table.insert(docs, { text = text, href = href })
      end
    end
  end
  return docs
end

function M.run(params)
  local identifiant = params.identifiant
  local password = params.password

  -- fyde.http's cookie jar is restored from fyde.session (see host/session.rs) before this
  -- script even starts, so a still-valid cookie from a previous run can land us on an
  -- already-authenticated section page here, skipping the login POST entirely.
  fyde.progress.step("Checking for an existing session")
  local check = fyde.http.get(SECTIONS[1].url)
  if is_bot_challenge(check.body) then
    error(
      "ameli.fr's bot protection rejected this request - this script's login/scraping flow "
        .. "hasn't been verified against the live site yet, see the header comment"
    )
  end

  if is_logged_in(check.body) then
    fyde.log.info("restored session is still valid, skipping login")
  else
    fyde.progress.step("Logging in")
    local login_resp = login(identifiant, password)
    if login_resp.status >= 400 then
      error("login request failed with HTTP status " .. login_resp.status)
    end
    if is_bot_challenge(login_resp.body) then
      error("ameli.fr's bot protection rejected the login request")
    end

    check = fyde.http.get(SECTIONS[1].url)
    if not is_logged_in(check.body) then
      error("login failed: still showing a login page after authenticating")
    end
    fyde.log.info("login succeeded")
  end

  for i, section in ipairs(SECTIONS) do
    fyde.progress.step(string.format("Section %s (%d/%d)", section.slug, i, #SECTIONS))

    local page
    if i == 1 then
      page = check
    else
      page = fyde.http.get(section.url)
    end

    if not is_logged_in(page.body) then
      fyde.log.warn("session was logged out while browsing " .. section.slug .. ", stopping")
      break
    end

    local docs = extract_documents(page.body)
    fyde.log.info(string.format("%s: %d document(s) found", section.slug, #docs))

    for j, doc in ipairs(docs) do
      fyde.progress.update(j, #docs, doc.text)

      local url = resolve_url(section.url, doc.href)
      local download = fyde.http.download(url)

      if download.status == 200 and not download.content_type:find("html", 1, true) then
        local filename = section.slug .. "/" .. sanitize(doc.text) .. ".pdf"
        fyde.save_document(filename, download.body)
      else
        fyde.log.warn(string.format(
          "failed to download '%s' (status %d, content-type %s)",
          doc.text, download.status, download.content_type
        ))
      end
    end
  end

  fyde.progress.step("Done")
end

return M
