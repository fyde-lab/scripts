-- Scraper for the particulier space on impots.gouv.fr.
--
-- Unlike Didaxis, this site has no plain login form: impots.gouv.fr/particulier redirects to
-- an OAuth2/OIDC identity provider (cfspart-idp.impots.gouv.fr) running a legacy multi-step
-- "Gotham" login flow. The real steps (reverse-engineered from the live site - there is no
-- public documentation for this):
--   0. GET the particulier homepage (https://cfspart.impots.gouv.fr/) first. It 302s through
--      the idp's /oauth2/authorize and back, which is what actually sets the session/state
--      cookies (plus ShieldSquare bot-management ones) that `/GetContexte` below checks -
--      skip this and GetContexte always answers context "ERR" regardless of the fiscal
--      number. A real browser always does this (it's how the login form gets rendered at
--      all), so it's not optional here either.
--   1. POST the fiscal number alone to `/GetContexte`. The response isn't a normal page; it's
--      a tiny HTML snippet whose only content is a `parent.postMessage('ctx,<CODE>', ...)`
--      call. In a browser, the parent page's JS listens for this and switches the visible form
--      based on <CODE> (e.g. "LMDP" = normal password account, "3S"/"PAS" = account creation,
--      "CODE" = account locked, needs a mailed unlock code, "EXISTEPAS" = unknown number).
--      This script only knows how to continue when <CODE> is "LMDP". (Confusingly, the site's
--      own JS then sets the *separate* `lmAuth` field to the string "LDAP" when submitting the
--      password in step 2 below - that's an unrelated internal auth-backend value, not another
--      spelling of this context code.)
--   2. POST the fiscal number + password (plus the other form fields, emptied) to `/` on the
--      same idp host - found hardcoded as `urlLoginMotDePasse = '/'` in customScript.js, since
--      it's never visible as a real form `action` attribute in the HTML (set dynamically by
--      the same JS that reacts to step 1's postMessage).
--   2b. Some accounts (not all - it's a per-account setting, not universal) have an email
--      security code (OTP/MFA) enabled. When step 2 succeeds, instead of either the login form
--      again or a logged-in page, the response is a form with id="otpform" (action
--      `/restapiotp2fcheck?skin=partDsfr&authType=sso`) asking for a 6-digit code just emailed
--      to the account's address, plus a hidden `token` field tying the code back to this
--      attempt. This script detects that form, asks for the code via `fyde.input.ask` (which
--      blocks on real stdin - a human needs to read the email and type it in), and POSTs it to
--      that endpoint before continuing to step 3.
--   3. Re-visit the normal entrypoint (https://cfspart.impots.gouv.fr/). With a valid idp
--      session cookie now set, the OIDC dance completes silently instead of showing the login
--      form again, landing on the authenticated particulier space.
-- From there, scraping mirrors the heuristics in demo-fyde's impots_scraper.js (its JS
-- equivalent for a WebView-driven crawl): find the "Documents" nav link, visit it once, and
-- read its document cards, one accordion tab per year.
--
-- Names and the listing's attributes come from each card (title, year tab, description lines,
-- amount badge). Titles seen: "Avis d'impôt <Y> sur les revenus [et prélèvements sociaux] <R>",
-- "Avis de situation déclarative à l'impôt <Y> sur les revenus <R> (le <date>, à <time>)",
-- "Déclaration en ligne des revenus <R> (le <date>, à <time>)" (several per year, two on the
-- same day), "Déclaration automatique : ... (revenus <R>)", "Avis de taxes foncières <Y>" /
-- "Avis de taxe d'habitation-CAP <Y>" (with "<address>, <dept> <TOWN>" and the payment deadline
-- underneath), "Impôt sur les revenus <R> – Montant de l’avance de réductions et crédits
-- d’impôt" (with a "Montant : N €" badge), and the yearless "Lettre de relance taxes foncières
-- ..." and "Mise en demeure de payer". tax_year is the year of income (<R>) for income tax and
-- the tax's own year for local taxes.
--
-- Each notice and letter is then read with fyde.pdf (see read_pdf): its reference, établissement
-- date and amount (tax_amount: the balance due, negative when refunded) only exist there, and the
-- year of income and payment deadline the listing gave are checked against it (a mismatch is
-- logged, the PDF's value kept). On the 45 documents of a 2026-11-03 run, every notice and
-- letter got its établissement date and amount, and every one but the payment demand its
-- reference (the 2023 reminder letter's amount aside: its text comes out letter-spaced); no
-- listing value disagreed with its PDF. Returns print none of these.
--
-- The login page also runs ShieldSquare/Radware bot-management (aperture.js / perfdrive.com /
-- eupulse.shieldsquare.net) in the browser. `fyde.http` doesn't evaluate that script (it runs
-- no JS), so requests may get flagged or rate-limited in ways a real browser wouldn't be - if login
-- keeps failing with a plausible-looking response, that's the most likely cause, not a bug in
-- the field names below.
--
-- IMPORTANT: repeated failed login attempts against a real fiscal number can lock the account
-- (the site's own recovery flow for that is mailing a physical unlock code - see the "CODE"
-- case above). Don't loop/retry this blindly against real credentials.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.progress, fyde.input, fyde.save_document, fyde.helpers.

local M = {}

local helpers = fyde.helpers
local already_saved = helpers.already_saved
local mark_saved = helpers.mark_saved

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local PART_BASE = "https://cfspart.impots.gouv.fr"
local IDP_BASE = "https://cfspart-idp.impots.gouv.fr"

-- Never follow anything that looks like a logout, and only treat links that look like real
-- documents as documents - mirrors impots_scraper.js's DOC_HREF/FORBIDDEN regexes exactly.
local FORBIDDEN_PATTERNS = { "logout", "deconnexion", "decoglobale", "/deco" }
local DOC_HREF_PATTERNS = { ".pdf", "affichage_document", "idensua", "telecharg" }

local function matches_any(haystack, patterns)
  local lower = haystack:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local ISSUER = "Direction générale des Finances publiques"

local MONTHS = {
  "janvier", "février", "mars", "avril", "mai", "juin",
  "juillet", "août", "septembre", "octobre", "novembre", "décembre",
}

--- The first `DD/MM/YYYY` date in `text`, as `YYYY-MM-DD` (nil if there's none).
local function iso_date(text)
  local day, month, year = text:match("(%d%d)/(%d%d)/(%d%d%d%d)")
  return day and string.format("%s-%s-%s", year, month, day)
end

--- "28 mai 2026 à 12h02" (or "1er mai ...") for a listing title's "le 28/05/2026, à 12:02".
local function long_datetime(day, month, year, hour, minute)
  day = tonumber(day)
  return string.format(
    "%s %s %s à %sh%s", day == 1 and "1er" or day, MONTHS[tonumber(month)], year, hour, minute
  )
end

--- "BETTON" / "SAINT-ÉTIENNE" as "Betton" / "Saint-Étienne" (ASCII and Latin-1 capitals only).
local function title_case(text)
  local lower = text:lower():gsub("\195([\128-\158])", function(c)
    return "\195" .. string.char(c:byte() + 32)
  end)
  return (lower:gsub("()([%a\195][\128-\191]?)", function(pos, letter)
    local before = pos > 1 and lower:sub(pos - 1, pos - 1) or " "
    if not before:match("[%s%-']") then
      return letter
    end
    if #letter == 2 then
      return "\195" .. string.char(letter:byte(2) - 32)
    end
    return letter:upper()
  end))
end

--- An amount ("3518 €", "1 080,00 €") in euro cents (nil if it isn't one).
local function euro_cents(text)
  local compact = text:gsub("[^%d,%-]", "")
  local units, decimals = compact:match("^(%-?%d+),(%d%d)$")
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

local function integer_attr(value)
  value = value and tonumber(value)
  return value and { type = "integer", value = math.tointeger(value) }
end

local function amount_attr(minor_units)
  return minor_units and { type = "amount", value = { minor_units = minor_units, currency = "EUR" } }
end

--- Name, type, subcategory and attributes of a listing card, from its title, the year tab it
--- sits under, and its optional description lines and amount badge.
local function describe(card)
  local title = card.title
  local attributes = {
    issuer = string_attr(ISSUER),
    due_on = date_attr(card.due_on),
  }
  local doc = { name = title, type = "tax_notice", attributes = attributes }

  local notice_year, income_year = title:match("^Avis d'impôt (%d%d%d%d) sur les revenus.- (%d%d%d%d)$")
  if notice_year then
    doc.kind, doc.year = "income_notice", notice_year
    doc.subcategory = "income_tax"
    attributes.tax_year = integer_attr(income_year)
    return doc
  end

  local d, m, y, hh, mm
  notice_year, income_year, d, m, y, hh, mm = title:match(
    "^Avis de situation déclarative à l'impôt (%d%d%d%d) sur les revenus (%d%d%d%d) "
      .. "%(le (%d%d)/(%d%d)/(%d%d%d%d), à (%d%d):(%d%d)%)$"
  )
  if notice_year then
    doc.name = string.format(
      "Avis de situation déclarative %s sur les revenus %s du %s",
      notice_year, income_year, long_datetime(d, m, y, hh, mm)
    )
    doc.kind, doc.year = "situation_notice", notice_year
    doc.subcategory = "income_tax"
    attributes.tax_year = integer_attr(income_year)
    attributes.issued_on = date_attr(string.format("%s-%s-%s", y, m, d))
    return doc
  end

  income_year, d, m, y, hh, mm = title:match(
    "^Déclaration en ligne des revenus (%d%d%d%d) %(le (%d%d)/(%d%d)/(%d%d%d%d), à (%d%d):(%d%d)%)$"
  )
  if income_year then
    doc.name = string.format(
      "Déclaration en ligne des revenus %s du %s", income_year, long_datetime(d, m, y, hh, mm)
    )
    doc.type = "tax_return"
    doc.subcategory = "income_tax"
    attributes.tax_year = integer_attr(income_year)
    attributes.issued_on = date_attr(string.format("%s-%s-%s", y, m, d))
    return doc
  end

  -- "Déclaration automatique : vos informations connues de l'administration (revenus 2022)"
  income_year = title:match("^Déclaration automatique.-%(revenus (%d%d%d%d)%)$")
  if income_year then
    doc.name = "Déclaration automatique des revenus " .. income_year
    doc.type = "tax_return"
    doc.subcategory = "income_tax"
    attributes.tax_year = integer_attr(income_year)
    return doc
  end

  -- "Impôt sur les revenus 2025 – Montant de l’avance de réductions et crédits d’impôt": the
  -- January advance on the year's tax credits, paid to the taxpayer (hence a negative tax_amount).
  income_year = title:match("^Impôt sur les revenus (%d%d%d%d) .-avance de réductions et crédits")
  if income_year then
    doc.name = "Avance de réductions et crédits d'impôt sur les revenus " .. income_year
    doc.kind = "advance"
    doc.subcategory = "income_tax"
    attributes.tax_year = integer_attr(income_year)
    local cents = card.amount and euro_cents(card.amount)
    attributes.tax_amount = amount_attr(cents and -cents)
    return doc
  end

  -- "Avis de taxes foncières 2026", "Avis de taxe d'habitation-CAP 2022": local taxes, one notice
  -- per property, so the property's town goes in the name.
  local local_year = title:match("^Avis de taxes? .-(%d%d%d%d)$")
  if local_year then
    doc.kind, doc.year = "local_notice", local_year
    attributes.tax_year = integer_attr(local_year)
    if card.town then
      doc.name = title .. " - " .. title_case(card.town)
    end
    return doc
  end

  -- "Lettre de relance taxes foncières ...", "Mise en demeure de payer": no year in the title.
  doc.kind, doc.year = "letter", card.year
  if not title:find("%d%d%d%d") then
    doc.name = title .. " - " .. card.year
  end
  return doc
end

local used_filenames = {}

--- `name` as a `.pdf` filename no other document of this run has (the dev documents client
--- writes files by name, so two equal names would overwrite each other).
local function unique_filename(name)
  local base = helpers.sanitize(name)
  local filename, n = base, 1
  while used_filenames[filename] do
    n = n + 1
    filename = string.format("%s (%d)", base, n)
  end
  used_filenames[filename] = true
  return filename .. ".pdf"
end

--- Resolves a possibly-relative href found on `page_url` into an absolute URL.
local function resolve_url(page_url, href)
  if href:match("^https?://") then
    return href
  end
  if href:sub(1, 1) == "/" then
    local domain = page_url:match("^(https?://[^/]+)")
    return (domain or PART_BASE) .. href
  end
  local dir = page_url:match("(.*/)") or (PART_BASE .. "/")
  return dir .. href
end

--- Calls `request(...)`, once more if it fails before any response: both hosts close idle
--- keep-alive connections within about a second, and a request sent on one as it closes fails
--- with "client error (SendRequest)" (every request issued ~800ms after the previous one did,
--- on 2026-11-03). Only for requests that are safe to repeat.
local function retry_stale(request, ...)
  local ok, result = pcall(request, ...)
  if ok then
    return result
  end
  if not tostring(result):find("SendRequest", 1, true) then
    error(result, 0)
  end
  fyde.log.debug("connection closed by the site, retrying once: " .. tostring(result))
  return request(...)
end

--- Extracts the `<CODE>` out of a `/GetContexte` response's
--- `parent.postMessage('ctx,<CODE>', ...)` payload.
local function parse_context_code(body)
  return body:match("postMessage%s*%(%s*['\"]ctx,([%w]+)['\"]")
end

--- Step 1 of the login flow: tells the server which fiscal number we're trying to log in as,
--- and gets back a context code describing what kind of account it is. `referer` is the
--- login page's own URL (see M.run) - a real browser sends it as the Referer on this POST
--- since it's submitting a form from that page, and the idp may check it.
local function get_context(spi, referer)
  local resp = retry_stale(fyde.http.post_form, IDP_BASE .. "/GetContexte", {
    url = "",
    lmAuth = "",
    authType = "",
    spi = spi,
    pwd = "",
    fg = "",
    rfr = "",
    teledec = "",
    dateNaissance = "",
  }, { Referer = referer })
  if resp.status >= 400 then
    error("GetContexte request failed with HTTP status " .. resp.status)
  end
  return parse_context_code(resp.body)
end

--- Step 2: submits the fiscal number + password to the real (hardcoded, see header comment)
--- login endpoint, once GetContexte has confirmed this is a normal password-protected account.
--- Same `referer` as `get_context` - same page, same form.
local function submit_password(spi, password, referer)
  return fyde.http.post_form(IDP_BASE .. "/", {
    url = "",
    lmAuth = "LDAP",
    authType = "",
    spi = spi,
    pwd = password,
    fg = "",
    rfr = "",
    teledec = "",
    dateNaissance = "",
  }, { Referer = referer })
end

--- True once the password step comes back asking for an emailed security code (OTP/MFA)
--- instead of either the login form again or a logged-in page - some accounts (not all) have
--- this enabled. Identified by the id of its real `<form>`, same approach as `is_logged_in`.
local function is_otp_challenge(html)
  return html:find('id="otpform"', 1, true) ~= nil
end

--- Pulls the per-session `token` hidden field out of the OTP form - it ties the code the user
--- enters back to this specific login attempt, and must be echoed back in step 3.
local function parse_otp_token(html)
  return html:match('name="token"%s+value="([^"]+)"')
end

--- Step 3 (only when `is_otp_challenge` is true): submits the user-entered emailed code to the
--- real (found in the OTP form's `action`) verification endpoint, alongside the token from
--- step 2's response and the form's other fields (always the same defaults - `stayconnected`
--- aside, which just avoids a second code on a future run from the same session).
local function submit_otp(token, code, referer)
  return fyde.http.post_form(IDP_BASE .. "/restapiotp2fcheck?skin=partDsfr&authType=sso", {
    token = token,
    checkLogins = "",
    stayconnected = "1",
    reselect = "",
    escape = "",
    skin = "partDsfr",
    code = code,
  }, { Referer = referer })
end

--- True once we're past the login form - i.e. the page no longer contains the Gotham login
--- form's marker id.
local function is_logged_in(html)
  return not html:find('id="formulairePrincipal"', 1, true)
end

local function find_documents_link(html, page_url)
  local anchors = fyde.html.select(html, "a")
  for _, anchor in ipairs(anchors) do
    local text = anchor.text:match("^%s*(.-)%s*$")
    if text:lower() == "documents" and anchor.attrs.href then
      return resolve_url(page_url, anchor.attrs.href)
    end
  end
  return nil
end

local function clean_text(text)
  return helpers.trim((text:gsub("\194\160", " "):gsub("%s+", " ")))
end

--- Every document card of the Documents page, per year tab (`div.fr-collapse#<year>`; the page
--- renders each card twice, in its mobile and desktop layouts, hence the dedup by href). A card
--- is a title link, optional description lines ("<address>, <dept> <TOWN>" and/or "Date limite
--- de paiement : DD/MM/YYYY") and an optional "Montant : N €" badge.
local function extract_documents(html)
  local docs = {}
  local seen = {}
  for _, section in ipairs(fyde.html.select(html, "div.fr-collapse")) do
    local year = (section.attrs.id or ""):match("^(%d%d%d%d)$")
    if year then
      for _, card in ipairs(fyde.html.select(section.html, "div.unDocument")) do
        local link = fyde.html.select(card.html, "a[href]")[1]
        local href = link and link.attrs.href or ""
        if href ~= "" and not seen[href] and not matches_any(href, FORBIDDEN_PATTERNS) then
          seen[href] = true
          local doc = { href = href, year = year, title = clean_text(link.text) }
          local desc = fyde.html.select(card.html, "p.fr-card__desc")[1]
          if desc then
            doc.due_on = iso_date(desc.text:match("Date limite de paiement[^%d]*(%d%d/%d%d/%d%d%d%d)") or "")
            local first_line = clean_text(desc.html:match("^<p[^>]*>(.-)<br") or "")
            doc.town = first_line:match(",%s*%d+%s+(.+)$")
          end
          local badge = fyde.html.select(card.html, "p.badgeMontant")[1]
          doc.amount = badge and badge.text:match(":%s*(.-€)")
          if doc.title == "" then
            doc.title = "Document " .. year
          end
          table.insert(docs, doc)
        end
      end
    end
  end

  local missed = 0
  for _, anchor in ipairs(fyde.html.select(html, "a[href]")) do
    local href = anchor.attrs.href
    if not seen[href] and matches_any(href, DOC_HREF_PATTERNS) and not matches_any(href, FORBIDDEN_PATTERNS) then
      missed = missed + 1
    end
  end
  if missed > 0 then
    fyde.log.warn(string.format("%d document link(s) outside any year tab's cards (page layout changed?)", missed))
  end
  return docs
end

-- First-page areas read with fyde.pdf.text_in_rect, in points from the page's bottom-left corner,
-- measured on every layout from 2017 to 2026: the title band ("Impôt et prélèvements sociaux sur
-- les revenus de 2024"), the amount box ("Somme qui vous est remboursée 5 955,00 €") and the "Vos
-- références" box. Most labels in these boxes are images: only their values are text, so the
-- full text alone can't tell a refund from an amount due, nor the établissement date from the
-- payment deadline printed next to it.
local TITLE_BAND = { x = 100, y = 770, width = 360, height = 72 }
local AMOUNT_BOX = { x = 215, y = 500, width = 340, height = 80 }
local REFERENCES_BOX = { x = 10, y = 430, width = 205, height = 260 }

local DATE = "(%d%d/%d%d/%d%d%d%d)"

--- The euro amount printed right after `label` ("Somme à payer 1 260,00 €", "Total dû : 318,00
--- €", "MONTANT DE VOTRE IMPÔT 0 €"), in cents.
local function amount_after(text, label)
  local raw = text:match(label .. "%s*:?%s*(%d[%d ,]*)%s*€")
  return raw and euro_cents(raw)
end

--- Sets `doc.attributes[key]` from the PDF, warning when the listing said otherwise (the PDF is
--- the document itself, so its value wins).
local function from_pdf(doc, key, attribute)
  if not attribute then
    return
  end
  local listed = doc.attributes[key]
  local function shown(a)
    return type(a.value) == "table" and tostring(a.value.minor_units) or tostring(a.value)
  end
  if listed and shown(listed) ~= shown(attribute) then
    fyde.log.warn(string.format(
      "'%s': the listing gives %s = %s but the PDF %s, keeping the PDF's", doc.name, key, shown(listed), shown(attribute)
    ))
  end
  doc.attributes[key] = attribute
end

--- The signed balance of an income tax notice (negative for a refund), in cents.
local function income_balance(text, amount_box)
  local refund = amount_after(amount_box, "Somme qui vous est remboursée")
  if refund then
    return -refund
  end
  local due = amount_after(amount_box, "Somme qu'il vous reste à payer")
    or amount_after(text, "MONTANT DE VOTRE IMPÔT")
    or amount_after(text, "Montant de votre impôt sur le revenu")
  if due then
    return due
  end
  -- 2020's amount box has no label: fall back on the detail pages' last line, in whole euros.
  due = text:match("RESTANT A PAYER[%s%.]*(%d+)")
  if due then
    return tonumber(due) * 100
  end
  local back = text:match("SERA REMBOURSE.-EST DE[%s%.]*(%d+)")
  return back and -tonumber(back) * 100
end

--- Completes and checks `doc`'s attributes from the PDF itself: the notice's reference, its
--- établissement date, the amount due or refunded, and the year of income / payment deadline the
--- listing already gave. Returns are left as they are: they print no reference or date of their
--- own. A PDF that can't be read only costs these attributes.
local function read_pdf(doc, body)
  if not doc.kind then
    return
  end
  local ok, err = pcall(function()
    local text = fyde.pdf.text(body)
    local function area(rect)
      return clean_text(fyde.pdf.text_in_rect(body, 1, rect))
    end

    -- "Référence de l'avis" / "du document", e.g. "25 35 A226334 19" or "26 A2 5448416 24", whose
    -- first group is the notice's year: often unlabelled, and the only number of that shape.
    if doc.year then
      local reference = text:match(
        "%f[%w](" .. doc.year:sub(3, 4) .. " [%dA-Z]%d [%dA-Z]%d%d%d%d%d%d %d%d)%f[%D]"
      )
      from_pdf(doc, "reference", string_attr(reference))
    end

    local issued_on = text:match("Date d'établissement%s*:%s*" .. DATE)
    if not issued_on and (doc.kind == "letter" or doc.kind == "advance") then
      issued_on = text:match("%f[%w]Le " .. DATE)
    end
    if not issued_on and doc.kind ~= "advance" then
      -- The "Vos références" box's first date, the "Adresse d'imposition au 01/01/..." aside:
      -- établissement, then mise en recouvrement.
      issued_on = area(REFERENCES_BOX):gsub("au " .. DATE, ""):match(DATE)
    end
    from_pdf(doc, "issued_on", date_attr(issued_on and iso_date(issued_on)))

    if doc.kind == "income_notice" or doc.kind == "situation_notice" then
      local income_year = area(TITLE_BAND):lower():match("revenus de [^%d]-(%d%d%d%d)")
      from_pdf(doc, "tax_year", integer_attr(income_year))
      local balance = income_balance(text, doc.kind == "income_notice" and area(AMOUNT_BOX) or "")
      from_pdf(doc, "tax_amount", amount_attr(balance))
    elseif doc.kind == "local_notice" then
      local deadline = text:match("Date limite de paiement%s*:%s*" .. DATE)
      from_pdf(doc, "due_on", date_attr(deadline and iso_date(deadline)))
      from_pdf(doc, "tax_amount", amount_attr(amount_after(area(AMOUNT_BOX), "Somme à payer")))
    elseif doc.kind == "letter" then
      local due = amount_after(text, "Reste à payer") or amount_after(text, "Total dû")
      from_pdf(doc, "tax_amount", amount_attr(due))
    elseif doc.kind == "advance" then
      local advance = euro_cents(text:match("montant de ([%d ]+) €") or "")
      from_pdf(doc, "tax_amount", amount_attr(advance and -advance))
    end
  end)
  if not ok then
    fyde.log.warn("could not read '" .. doc.name .. "' as a PDF: " .. tostring(err))
  end
end

function M.run(params)
  local spi = params["fiscal-number"]
  local password = params.password

  -- Step 0 (see header comment): picks up the session/bot-management cookies GetContexte
  -- needs - without this it always answers context "ERR". `login_page_url` is where this
  -- lands after following the oauth2 redirect - the same URL a real browser would send back
  -- as Referer on the GetContexte/login POSTs below, since it's submitting the form found on
  -- that page. fyde.http's cookie jar is restored from the previous run's saved cookies
  -- before this script even starts, so a still-valid idp session cookie from a previous run can
  -- also mean this GET already lands us on the authenticated homepage, completing the OIDC
  -- dance silently and skipping the rest of the login flow below entirely.
  fyde.progress.step("checking_session")
  local home = fyde.http.get(PART_BASE .. "/")
  local login_page_url = home.url

  if is_logged_in(home.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    fyde.log.info("LOGIN_PAGE_FOUND")
    fyde.progress.step("logging_in")
    local context_code = get_context(spi, login_page_url)
    if context_code == "EXISTEPAS" then
      -- No account for this fiscal number: a wrong username.
      fyde.log.warn("GetContexte: unknown fiscal number")
      error("INVALID_CREDENTIALS", 0)
    end
    if context_code ~= "LMDP" then
      error(
        "GetContexte returned context '"
          .. tostring(context_code)
          .. "' instead of 'LMDP' (a normal password account) - this script doesn't support "
          .. "account creation, locked-account unlock codes, or unrecognized fiscal numbers."
      )
    end
    fyde.log.info("account recognized as a password account, logging in")

    local login_resp = submit_password(spi, password, login_page_url)
    if login_resp.status >= 400 then
      error("login request failed with HTTP status " .. login_resp.status)
    end

    local otp_submitted = false
    if is_otp_challenge(login_resp.body) then
      local otp_token = parse_otp_token(login_resp.body)
      if not otp_token then
        error(
          "detected the emailed security code (OTP) form but couldn't find its 'token' field"
        )
      end
      fyde.log.info("account requires an emailed security code")
      local asked, code = pcall(fyde.input.ask, "Enter the 6-digit security code emailed to you: ")
      if not asked or tostring(code):gsub("%s", "") == "" then
        fyde.log.warn("no security code was provided")
        error("MFA_FAILED", 0)
      end
      otp_submitted = true
      local otp_resp = submit_otp(otp_token, code, login_page_url)
      if otp_resp.status >= 400 then
        error("security code verification request failed with HTTP status " .. otp_resp.status)
      end
    end

    -- The idp session cookie is now set (if login succeeded); re-entering the normal entrypoint
    -- should complete the OIDC flow silently instead of showing the login form again.
    home = fyde.http.get(PART_BASE .. "/")
    if not is_logged_in(home.body) then
      fyde.log.warn("login failed: still seeing the login form after authenticating")
      error(otp_submitted and "MFA_FAILED" or "INVALID_CREDENTIALS", 0)
    end
    fyde.log.info("login succeeded")
  end

  fyde.progress.step("listing_documents")
  -- home.url (not PART_BASE) is the real base: the homepage GET actually redirects through
  -- monprofil-webapp/monCompte into the legacy /enp/ app, landing on /enp/accueilensupres.do.
  -- Resolving the page's relative href against the wrong base silently produces a working but
  -- wrong URL (the root-domain, single-year documents.do) instead of /enp/documents.do, which
  -- is the one that actually renders every year's documents server-side in one response.
  local documents_url = find_documents_link(home.body, home.url)
  if not documents_url then
    error("could not find a 'Documents' link on the authenticated homepage")
  end

  local page = fyde.http.get(documents_url)
  if not is_logged_in(page.body) then
    error("session was logged out while opening the Documents section")
  end

  -- Every year tab (2017-2026 on a 2026-11-03 run, 45 documents) is rendered server-side in
  -- this one response; the tabs only toggle visibility.
  local docs = extract_documents(page.body)
  fyde.log.info(string.format("%d document(s) found", #docs))

  if #docs > 0 then
    fyde.progress.step("downloading_documents")
  end
  for i, card in ipairs(docs) do
    fyde.progress.update(i, #docs)

    local doc = describe(card)
    local url = resolve_url(documents_url, card.href)
    if already_saved(url) then
      fyde.log.debug("skipping '" .. doc.name .. "': already saved by a previous run")
    else
      local download = retry_stale(fyde.http.download, url)

      if download.status == 200 and not download.content_type:find("html", 1, true) then
        read_pdf(doc, download.body)
        fyde.save_document(unique_filename(doc.name), download.body, {
          name = doc.name,
          type = doc.type,
          category = "taxes",
          subcategory = doc.subcategory,
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

  fyde.progress.step("done")
end

return M
