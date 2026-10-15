-- Scraper for the "Eolys by Didaxis" employee portal (eolys.didaxis.fr).
--
-- Mirrors the reference Playwright script (doc-downloaders/scrapers/didaxis), but drives
-- everything over plain HTTP + HTML parsing instead of a real browser: login is a single POST
-- to the site's authentication endpoint, and each of the four document sections is a GET
-- followed by scraping <a href> links for the site's readfile.php?file=<base64 path> downloads.
-- `fyde.http` runs no JS, so the DataTable's "show 100 rows" <select> and the year-tab
-- clicks from the browser-driven version aren't replayed - this script scrapes whatever the
-- section page renders server-side on first load.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.progress, fyde.save_document.

local M = {}

local BASE = "https://eolys.didaxis.fr"

local SECTIONS = {
  {
    slug = "payslip",
    url = BASE .. "/mon-espace/payslip.php",
    fields = { type = "payslip", subcategory = "payslips" },
  },
  {
    slug = "employment_contract",
    url = BASE .. "/mon-espace/employment_contract.php",
    fields = { type = "contract", subcategory = "employment" },
  },
  {
    slug = "bills",
    url = BASE .. "/mon-espace/bills.php",
    fields = { type = "invoice", subcategory = "employment" },
  },
  {
    slug = "personal_documents",
    url = BASE .. "/mon-espace/personal_documents.php",
    fields = { type = "other", subcategory = "employment", purpose = "description" },
  },
}

-- Never follow anything that looks like a logout, and only treat links that look like real
-- documents as documents - a broader keyword list would false-match the section nav itself
-- (bills.php, personal_documents.php, ...).
local FORBIDDEN_PATTERNS = { "logout", "deconnexion", "signout", "/deco" }

local function matches_any(haystack, patterns)
  local lower = haystack:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function is_document_href(href)
  local lower = href:lower()
  return lower:find(".pdf", 1, true) or lower:find("readfile.php", 1, true)
end

--- Mirrors the reference script's `is_logged_out`: logged out if the page still shows a
--- "Se connecter" link without a "Déconnexion" one, or we're sitting on the login page.
local function is_logged_in(html)
  if matches_any(html, FORBIDDEN_PATTERNS) and html:find("login") then
    return false
  end
  local has_login_link = html:find("Se connecter", 1, true) ~= nil
  local has_logout_link = html:find("D\195\169connexion", 1, true) ~= nil -- "Déconnexion" (UTF-8)
  if has_login_link and not has_logout_link then
    return false
  end
  return true
end

-- Minimal pure-Lua base64 decoder, used only to recover the real filename from
-- readfile.php?file=<base64 server path> links that carry no visible text.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_decode(data)
  data = data:gsub("[^" .. B64_CHARS .. "=]", "")
  local decoded = {}
  for i = 1, #data, 4 do
    local chunk = data:sub(i, i + 3)
    local bits = 0
    local bit_count = 0
    local chars = 0
    for c in chunk:gmatch(".") do
      if c ~= "=" then
        local index = B64_CHARS:find(c, 1, true)
        if not index then
          return nil
        end
        bits = bits * 64 + (index - 1)
        bit_count = bit_count + 6
        chars = chars + 1
      end
    end
    bits = bits * (2 ^ (bit_count % 8 == 0 and 0 or (8 - bit_count % 8)))
    bit_count = bit_count + (bit_count % 8 == 0 and 0 or (8 - bit_count % 8))
    local byte_count = bit_count // 8
    for b = byte_count - 1, 0, -1 do
      local byte = (bits // (2 ^ (b * 8))) % 256
      table.insert(decoded, string.char(byte))
    end
  end
  return table.concat(decoded)
end

local function document_name_from_href(href)
  local encoded = href:match("file=([A-Za-z0-9+/=]+)")
  if encoded then
    local decoded = base64_decode(encoded)
    if decoded then
      local name = decoded:match("([^/]+)$")
      if name and name ~= "" and utf8.len(name) then
        return name
      end
    end
  end
  return "document"
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

local function extract_documents(html)
  local docs = {}
  local seen = {}
  local anchors = fyde.html.select(html, "a[href]")
  for _, anchor in ipairs(anchors) do
    local href = anchor.attrs.href or ""
    if href ~= "" and not matches_any(href, FORBIDDEN_PATTERNS) and is_document_href(href) then
      if not seen[href] then
        seen[href] = true
        local text = anchor.text
        if text == "" then
          text = document_name_from_href(href)
        end
        table.insert(docs, { text = text, href = href })
      end
    end
  end
  return docs
end

local function login(username, password)
  return fyde.http.post_form(BASE .. "/", {
    action = "authenticate",
    login = username,
    password = password,
    submit = "Se connecter",
  })
end

function M.run(params)
  local username = params.username
  local password = params.password

  -- fyde.http's cookie jar is restored from the previous run's saved cookies (see
  -- ../sdk/src/domains/scrapers/cookies/) before this script even starts, so a still-valid
  -- cookie can land us on an already-authenticated section page here, skipping the login POST
  -- entirely.
  fyde.progress.step("Checking for an existing session")
  local check = fyde.http.get(SECTIONS[1].url)
  if is_logged_in(check.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    if not check.body:find("Se connecter", 1, true) then
      error("didaxis login page not found on " .. check.url)
    end
    fyde.log.info("LOGIN_PAGE_FOUND")
    fyde.progress.step("Logging in as " .. username)
    local login_resp = login(username, password)
    if login_resp.status >= 400 then
      error("login request failed with HTTP status " .. login_resp.status)
    end

    check = fyde.http.get(SECTIONS[1].url)
    if not is_logged_in(check.body) then
      -- The login POST went through but we're still logged out: the credentials were refused.
      fyde.log.warn("login failed: still showing a login page after authenticating")
      error("INVALID_CREDENTIALS", 0)
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
        fyde.save_document(filename, download.body, {
          name = doc.text,
          type = section.fields.type,
          subcategory = section.fields.subcategory,
          purpose = section.fields.purpose,
        })
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
