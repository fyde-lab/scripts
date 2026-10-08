-- Luacheck config for `scrapers/<name>/script.lua` (see CLAUDE.md). Matches
-- the restricted Lua 5.4 VM the real `scrapers::Service` runs these under
-- (../sdk/src/domains/scrapers/service.rs's `sandboxed_lua`): `fyde` is the
-- only extra global available, everything else comes from the stdlib.
std = "lua54"
read_globals = { "fyde" }

-- These scripts aren't wrapped to any particular column width; rustfmt
-- governs the Rust side (see CLAUDE.md), not these Lua files.
max_line_length = false
