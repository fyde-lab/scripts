-- Scraper for OVHcloud (ovh.com, also So you Start/Kimsufi/OVH CA/US endpoints): downloads the
-- bills through the OVH API.
--
-- The original implementation used the `ovh` npm client: there
-- is no login form, the account is accessed with API credentials (appKey, appSecret,
-- consumerKey, and an optional `provider` endpoint, default ovh-eu). Every call is signed:
-- `X-Ovh-Signature: $1$` + SHA-1 of "appSecret+consumerKey+METHOD+url+body+timestamp", with the
-- server time from `/auth/time`. `GET /me/bill` lists bill ids - a 403 "This application key is
-- invalid" / "This credential does not exist" / "This credential is not valid" / "This call has
-- not been granted" or a 400 "Invalid signature" were LOGIN_FAILED, reported here as
-- INVALID_CREDENTIALS - then `GET /me/bill/<id>` gives the date, price and `pdfUrl`.
-- Unverified (see README.md).

local M = {}

local ENDPOINTS = {
  ["ovh-eu"] = "https://eu.api.ovh.com/1.0",
  ["ovh-ca"] = "https://ca.api.ovh.com/1.0",
  ["ovh-us"] = "https://api.us.ovhcloud.com/1.0",
  ["kimsufi-eu"] = "https://eu.api.kimsufi.com/1.0",
  ["kimsufi-ca"] = "https://ca.api.kimsufi.com/1.0",
  ["soyoustart-eu"] = "https://eu.api.soyoustart.com/1.0",
  ["soyoustart-ca"] = "https://ca.api.soyoustart.com/1.0",
}
local BAD_CREDENTIALS = {
  "This application key is invalid", "This credential does not exist", "This call has not been granted",
  "This credential is not valid", "Invalid signature",
}

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function sha1(message)
  local function rol(x, n)
    return ((x << n) | (x >> (32 - n))) & 0xffffffff
  end
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #message * 8
  message = message .. "\128" .. string.rep("\0", (55 - #message) % 64) .. string.pack(">I8", ml)
  for chunk = 1, #message, 64 do
    local w = {}
    for i = 0, 15 do
      w[i] = string.unpack(">I4", message, chunk + i * 4)
    end
    for i = 16, 79 do
      w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = (b & c) | ((~b) & d), 0x5A827999
      elseif i < 40 then
        f, k = b ~ c ~ d, 0x6ED9EBA1
      elseif i < 60 then
        f, k = (b & c) | (b & d) | (c & d), 0x8F1BBCDC
      else
        f, k = b ~ c ~ d, 0xCA62C1D6
      end
      local temp = (rol(a, 5) + (f & 0xffffffff) + e + k + w[i]) & 0xffffffff
      a, b, c, d, e = temp, a, rol(b, 30), c, d
    end
    h0, h1, h2, h3, h4 = (h0 + a) & 0xffffffff, (h1 + b) & 0xffffffff, (h2 + c) & 0xffffffff, (h3 + d) & 0xffffffff, (h4 + e) & 0xffffffff
  end
  return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

local function client(params)
  local base = ENDPOINTS[params.provider or "ovh-eu"] or ENDPOINTS["ovh-eu"]
  local time = trim(fyde.http.get(base .. "/auth/time").body)
  if not time:match("^%d+$") then
    error("OVH API not found: /auth/time answered " .. time:sub(1, 80))
  end
  -- There is no login page: the API answering /auth/time is the equivalent marker.
  fyde.log.info("LOGIN_PAGE_FOUND")
  return function(path)
    local url = base .. path
    local signature = "$1$" .. sha1(params.appSecret .. "+" .. params.consumerKey .. "+GET+" .. url .. "++" .. time)
    local resp = fyde.http.get(url, {
      ["X-Ovh-Application"] = params.appKey,
      ["X-Ovh-Consumer"] = params.consumerKey,
      ["X-Ovh-Timestamp"] = time,
      ["X-Ovh-Signature"] = signature,
      Accept = "application/json",
    })
    local body = json_or_nil(resp.body)
    if resp.status == 403 or resp.status == 400 then
      if contains_any(body and body.message or resp.body, BAD_CREDENTIALS) then
        fail(INVALID_CREDENTIALS, body and body.message)
      end
    end
    if resp.status >= 400 then
      error("OVH API answered HTTP " .. resp.status .. " for " .. path)
    end
    return body
  end
end

function M.run(params)
  for _, field in ipairs({ "appKey", "appSecret", "consumerKey" }) do
    if not params[field] or params[field] == "" then
      fail(INVALID_CREDENTIALS, "missing " .. field)
    end
  end
  fyde.progress.step("Checking the API credentials")
  local api = client(params)
  local bills = api("/me/bill")
  -- There is no session here: valid API credentials are the "already logged in" state.
  fyde.log.info("ALREADY_LOGGED_IN")

  fyde.progress.step("Downloading bills")
  for _, id in ipairs(type(bills) == "table" and bills or {}) do
    local bill = api("/me/bill/" .. id)
    if bill and bill.pdfUrl then
      local date = tostring(bill.date):sub(1, 10)
      local price = bill.priceWithTax and bill.priceWithTax.text or ""
      save_pdf(bill.pdfUrl, date .. "_" .. price:gsub("%s", "") .. "_" .. tostring(bill.billId) .. ".pdf", {
        name = "Facture OVH " .. tostring(bill.billId),
        type = "invoice",
        category = "subscriptions",
        subcategory = "cloud_software",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
