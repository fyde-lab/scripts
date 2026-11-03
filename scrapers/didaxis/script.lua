-- Scraper for the "Eolys by Didaxis" employee portal (eolys.didaxis.fr).
--
-- Mirrors the reference Playwright script (doc-downloaders/scrapers/didaxis), but drives
-- everything over plain HTTP + HTML parsing instead of a real browser: login is a single POST
-- to the site's authentication endpoint, and each of the four document sections is a GET
-- whose `table#scroll` rows link to the site's readfile.php?file=<base64 path> downloads.
-- `fyde.http` runs no JS, so the DataTable's "show 100 rows" <select> and the year-tab
-- clicks from the browser-driven version aren't replayed - this script scrapes whatever the
-- section page renders server-side on first load (every row so far, 95 documents).
--
-- Names and attributes come only from each row's cells, read by column header, never from the
-- PDFs (names carry no contract/invoice number: that's the `reference` attribute); on a
-- 2026-11-03 run every value used below matched what its PDF prints:
-- - payslips: "Période" (MM/YYYY), "Salaire brut", "Salaire net" (= the PDF's "Net payé");
-- - contracts: one row per contract (n°, "Dates", "Nature" CDD/CDI/"CDD - Avenant"), linking
--   up to four documents: the URSSAF's DPAE acknowledgement ("D.U.E"), the contract to sign,
--   the signed contract and the Pôle emploi employer certificate (covering the contract dates);
-- - bills: Didaxis's invoices to the client ("Date" = date de pièce, "Échéance", "Période",
--   "Net à payer" = TTC total);
-- - personal documents: "Date" (when it was posted: one attestation prints the day before),
--   "Intitulé" (the title, sometimes with a "du ... au ..." period).
-- The issuer is "Didaxis" throughout: the legal entity (Didaxis Expertise Construction, Novea
-- Technologies, Didaxis Technologies...) is only printed in the PDFs.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.progress, fyde.save_document, fyde.helpers.

local M = {}

local helpers = fyde.helpers
local already_saved = helpers.already_saved
local mark_saved = helpers.mark_saved
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute

local BASE = "https://eolys.didaxis.fr"
local ISSUER = "Didaxis"

local MONTHS = {
  "janvier", "février", "mars", "avril", "mai", "juin",
  "juillet", "août", "septembre", "octobre", "novembre", "décembre",
}

--- The first `DD/MM/YYYY` date in `text`, as `YYYY-MM-DD` (nil if there's none).
local function iso_date(text)
  local day, month, year = text:match("(%d%d)/(%d%d)/(%d%d%d%d)")
  return day and string.format("%s-%s-%s", year, month, day)
end

--- `"01/04/2021 au 30/04/2023"` (anywhere in `text`) as two `YYYY-MM-DD` dates.
local function date_range(text)
  local from, to = text:match("(%d%d/%d%d/%d%d%d%d) au (%d%d/%d%d/%d%d%d%d)")
  if from then
    return iso_date(from), iso_date(to)
  end
end

local function days_in_month(year, month)
  if month == 2 then
    return (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) and 29 or 28
  end
  return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month]
end

--- "juin 2023" for a `YYYY-MM-DD` date.
local function month_label(iso)
  return MONTHS[tonumber(iso:sub(6, 7))] .. " " .. iso:sub(1, 4)
end

--- An amount cell ("11959.71€", "17 160,00 €", "0€") in euro cents (nil if it isn't one).
local function euro_cents(text)
  local compact = text:gsub("[^%d,%.%-]", "")
  local units, decimals = compact:match("^(%-?%d+)[,.](%d%d)$")
  if units then
    return tonumber(units .. decimals)
  end
  units = compact:match("^%-?%d+$")
  return units and tonumber(units) * 100
end

-- `fyde.save_document` attribute values (see ../sdk/src/domains/documents/attributes/lua.rs).
-- Each returns nil when there's no value, so the attribute is simply left out.
local function string_attr(value)
  if value and value ~= "" then
    return { type = "string", value = value }
  end
end

local function date_attr(value)
  return value and { type = "date", value = value }
end

local function amount_attr(minor_units)
  return minor_units and { type = "amount", value = { minor_units = minor_units, currency = "EUR" } }
end

local function set_period(attributes, from, to)
  attributes.period_start = date_attr(from)
  attributes.period_end = date_attr(to)
end

local function payslip_documents(row)
  local attributes = {
    issuer = string_attr(ISSUER),
    gross_pay = amount_attr(euro_cents(row["Salaire brut"].text)),
    net_pay = amount_attr(euro_cents(row["Salaire net"].text)),
  }
  local label = row["Période"].text
  local month, year = label:match("^(%d%d)/(%d%d%d%d)$")
  if month then
    local last_day = days_in_month(tonumber(year), tonumber(month))
    set_period(attributes, string.format("%s-%s-01", year, month), string.format("%s-%s-%02d", year, month, last_day))
    label = MONTHS[tonumber(month)] .. " " .. year
  end
  return {
    {
      href = row["Fichier"].href,
      name = "Bulletin de paie " .. ISSUER .. " " .. label,
      type = "payslip",
      attributes = attributes,
    },
  }
end

local function contract_documents(row)
  local number = row["N°"].text
  local from, to = date_range(row["Dates"].text)
  local function contract_attributes()
    local attributes = { issuer = string_attr(ISSUER), reference = string_attr(number) }
    set_period(attributes, from, to)
    return attributes
  end
  -- "CDI", "CDD" or "CDD - Avenant" (a renewal of the CDD).
  local nature = row["Nature"].text
  local renewed = nature:match("^(.-) %- Avenant$")
  local title = renewed and ("Avenant " .. renewed) or ("Contrat " .. nature)
  -- Named by its dates: the contract number goes in the `reference` attribute.
  local dates = row["Dates"].text:match("%d%d/%d%d/%d%d%d%d au %d%d/%d%d/%d%d%d%d")
  local of_dates = ISSUER .. (dates and (" du " .. dates) or "")
  local contract = title .. " " .. of_dates
  local of_contract = " - contrat " .. of_dates
  return {
    {
      href = row["D.U.E"].href,
      name = "Déclaration préalable à l'embauche (URSSAF)" .. of_contract,
      type = "employment_certificate",
      attributes = { issuer = string_attr("URSSAF"), reference = string_attr(number) },
    },
    {
      href = row["Contrat à signer"].href,
      name = contract .. " (à signer)",
      type = "contract",
      attributes = contract_attributes(),
    },
    {
      href = row["Contrat"].href,
      name = contract .. " (signé)",
      type = "contract",
      attributes = contract_attributes(),
    },
    {
      href = row["Pôle emploi"].href,
      name = "Attestation employeur Pôle emploi" .. of_contract,
      type = "employment_certificate",
      attributes = contract_attributes(),
    },
  }
end

local function bill_documents(row)
  local number = row["Facture"].text
  local from, to = date_range(row["Période"].text)
  local attributes = {
    issuer = string_attr(ISSUER),
    reference = string_attr(number),
    issued_on = date_attr(iso_date(row["Date"].text)),
    due_on = date_attr(iso_date(row["Échéance"].text)),
    total_amount = amount_attr(euro_cents(row["Net à payer"].text)),
  }
  set_period(attributes, from, to)
  local parts = { "Facture " .. ISSUER }
  local client = row["Nom du client"].text
  if client ~= "" then
    table.insert(parts, client)
  end
  if from and from:sub(1, 7) == to:sub(1, 7) then
    table.insert(parts, month_label(from))
  elseif row["Période"].text ~= "" then
    table.insert(parts, "du " .. row["Période"].text)
  end
  return {
    { href = row["Facture"].href, name = table.concat(parts, " - "), type = "invoice", attributes = attributes },
  }
end

local function personal_documents(row)
  local title = row["Intitulé"].text
  local lower = title:lower()
  local doc_type = "other"
  if lower:find("^attestation") then
    doc_type = "employment_certificate"
  elseif lower:find("^avenant") or lower:find("^contrat") then
    doc_type = "contract"
  end
  local attributes = { issued_on = date_attr(iso_date(row["Date"].text)) }
  -- An "other" document may be the employee's own (e.g. "Lettre de démission").
  if doc_type ~= "other" then
    attributes.issuer = string_attr(ISSUER)
  end
  set_period(attributes, date_range(title))
  return {
    {
      href = row["Fichier"].href,
      name = (title ~= "" and title or "Document") .. " - " .. ISSUER,
      type = doc_type,
      attributes = attributes,
    },
  }
end

-- `documents(row)` maps a `table#scroll` row (cells keyed by column header) to the documents
-- it links; one whose cell has no link (a "-") is skipped.
local SECTIONS = {
  {
    slug = "payslip",
    url = BASE .. "/mon-espace/payslip.php",
    subcategory = "payslips",
    documents = payslip_documents,
  },
  {
    slug = "employment_contract",
    url = BASE .. "/mon-espace/employment_contract.php",
    subcategory = "employment",
    documents = contract_documents,
  },
  {
    slug = "bills",
    url = BASE .. "/mon-espace/bills.php",
    subcategory = "employment",
    documents = bill_documents,
  },
  {
    slug = "personal_documents",
    url = BASE .. "/mon-espace/personal_documents.php",
    subcategory = "employment",
    documents = personal_documents,
  },
}

-- Never follow anything that looks like a logout.
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

local NO_CELL = { text = "" }

--- The rows of `html`'s `table#scroll`, each a table of `{ text, href }` cells keyed by column
--- header (`href`: the cell's readfile.php link, if any); a missing column reads as `NO_CELL`.
local function parse_rows(html)
  local headers = {}
  for i, th in ipairs(fyde.html.select(html, "table#scroll thead th")) do
    headers[i] = trim(th.text)
  end
  local rows = {}
  for _, tr in ipairs(fyde.html.select(html, "table#scroll tbody tr")) do
    local row = setmetatable({}, { __index = function() return NO_CELL end })
    -- A lone <tr> parses to nothing outside a <table>.
    for i, td in ipairs(fyde.html.select("<table>" .. tr.html .. "</table>", "td")) do
      local link = fyde.html.select(td.html, 'a[href*="readfile.php"]')[1]
      if headers[i] then
        row[headers[i]] = { text = trim(td.text), href = link and link.attrs.href }
      end
    end
    table.insert(rows, row)
  end
  return rows
end

local used_filenames = {}
-- Leaves room for " (n).pdf" within the usual 255-byte filename limit.
local MAX_FILENAME_BYTES = 150

--- `name` as a `.pdf` filename no other document of this run has (the dev documents client
--- writes files by name, so two equal names would overwrite each other).
local function unique_filename(name)
  local base = sanitize(name)
  if #base > MAX_FILENAME_BYTES then
    -- Drops the last, possibly cut, multi-byte UTF-8 character.
    base = trim((base:sub(1, MAX_FILENAME_BYTES):gsub("[\192-\255][\128-\191]*$", "")))
  end
  local filename, n = base, 1
  while used_filenames[filename] do
    n = n + 1
    filename = string.format("%s (%d)", base, n)
  end
  used_filenames[filename] = true
  return filename .. ".pdf"
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
  fyde.progress.step("checking_session")
  local check = fyde.http.get(SECTIONS[1].url)
  if is_logged_in(check.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    if not check.body:find("Se connecter", 1, true) then
      error("didaxis login page not found on " .. check.url)
    end
    fyde.log.info("LOGIN_PAGE_FOUND")
    fyde.progress.step("logging_in")
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

  fyde.progress.step("downloading_documents")
  for i, section in ipairs(SECTIONS) do
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

    local docs, extracted = {}, {}
    for _, row in ipairs(parse_rows(page.body)) do
      for _, doc in ipairs(section.documents(row)) do
        if doc.href then
          table.insert(docs, doc)
          extracted[doc.href] = true
        end
      end
    end
    fyde.log.info(string.format("%s: %d document(s) found", section.slug, #docs))

    -- Rows are read by column header: a renamed column or table would otherwise drop its
    -- documents without a trace.
    local missed = {}
    for _, link in ipairs(fyde.html.select(page.body, 'a[href*="readfile.php"]')) do
      local href = link.attrs.href
      if not extracted[href] then
        extracted[href] = true
        table.insert(missed, href)
      end
    end
    if #missed > 0 then
      local message = string.format(
        "%s: %d readfile.php link(s) outside any known column (page layout changed?), e.g. %s",
        section.slug, #missed, missed[1]
      )
      if #docs == 0 then
        error(message)
      end
      fyde.log.warn(message)
    end

    for j, doc in ipairs(docs) do
      fyde.progress.update(j, #docs)

      local url = absolute(section.url, doc.href)
      if already_saved(url) then
        fyde.log.debug("skipping '" .. doc.name .. "': already saved by a previous run")
      else
        local download = fyde.http.download(url)

        if download.status == 200 and not download.content_type:find("html", 1, true) then
          fyde.save_document(unique_filename(doc.name), download.body, {
            name = doc.name,
            type = doc.type,
            subcategory = section.subcategory,
            attributes = doc.attributes,
          })
          mark_saved(url)
        else
          fyde.log.warn(string.format(
            "failed to download '%s' (status %d, content-type %s)",
            doc.name, download.status, download.content_type
          ))
        end
      end
    end
  end

  fyde.progress.step("done")
end

return M
