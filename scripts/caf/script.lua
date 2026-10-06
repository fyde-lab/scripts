-- Scraper for the CAF ("Caisse d'Allocations Familiales") "Mon Compte" personal space
-- (caf.fr), the French family-benefits agency portal.
--
-- Step 1 of the create-script loop: confirm the base URL and see what an anonymous visit
-- returns before anything else is built.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.json, fyde.progress, fyde.save_document.

local M = {}

local BASE = "https://www.caf.fr"

function M.run(params)
  fyde.progress.step("Checking for an existing session")

  local home = fyde.http.get(BASE)
  fyde.log.info(string.format("GET %s -> status %d", BASE, home.status))

  fyde.progress.step("Done")
end

return M
