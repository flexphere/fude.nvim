-- scripts/check_docs.lua
--
-- Computational Documentation Fitness Sensor.
--
-- Verifies that user commands registered in `plugin/fude.lua` via
-- `nvim_create_user_command("FudeXxx", ...)` have a matching `*:FudeXxx*`
-- helptag entry in `doc/fude.txt`, and vice versa.
--
-- See .claude/HARNESS.md §2 for the conceptual framing.
--
-- Usage:
--   nvim --headless -l scripts/check_docs.lua
--
-- Exit codes:
--   0 = no discrepancies
--   1 = discrepancies found
--   2 = setup / IO error

-- Bootstrap package.path so direct execution can resolve `require("lib.lua_source")`.
package.path = "scripts/?.lua;" .. package.path

local M = {}

local lua_source = require("lib.lua_source")

--- Re-export of `lib.lua_source.strip_comments_only`. Kept on M so tests can
--- access it directly.
M.strip_comments_only = lua_source.strip_comments_only

----------------------------------------------------------------
-- 1. Extract registered commands from plugin/fude.lua
----------------------------------------------------------------

--- Extract command names registered via `nvim_create_user_command("Name", ...)`.
--- Strips Lua **comments** first (line + block) so commented-out registrations
--- are excluded. String literals are kept intact because the command name lives
--- inside one — `nvim_create_user_command("FudeXxx", ...)`.
--- @param plugin_text string  raw Lua source of plugin/fude.lua
--- @return table<string, boolean>  set of command names
function M.extract_registered_commands(plugin_text)
	local cleaned = lua_source.strip_comments_only(plugin_text)
	local set = {}
	-- Note: stripping converts "FudeFoo" inside a string literal to spaces, so
	-- the matched name comes only from real source code.
	-- Both double- and single-quoted forms are supported.
	for name in cleaned:gmatch('nvim_create_user_command%(%s*"([%w_]+)"') do
		set[name] = true
	end
	for name in cleaned:gmatch("nvim_create_user_command%(%s*'([%w_]+)'") do
		set[name] = true
	end
	return set
end

----------------------------------------------------------------
-- 2. Extract documented commands from doc/fude.txt
----------------------------------------------------------------

--- Extract command names documented as `*:Name*` vim helptags.
--- The colon prefix distinguishes command tags (`*:FudeFoo*`) from option/
--- variable tags (`*g:fude_foo*` or `*fude-section*`).
--- @param doc_text string  raw vim help text
--- @return table<string, boolean>  set of command names
function M.extract_documented_commands(doc_text)
	local set = {}
	for name in doc_text:gmatch("%*:(Fude[%w_]+)%*") do
		set[name] = true
	end
	return set
end

----------------------------------------------------------------
-- 3. Compare and report
----------------------------------------------------------------

--- Compute set differences between registered and documented commands.
--- @param registered table<string, boolean>
--- @param documented table<string, boolean>
--- @return { undocumented: string[], stale: string[] }
function M.compare(registered, documented)
	local undocumented = {}
	local stale = {}
	for cmd in pairs(registered) do
		if not documented[cmd] then
			table.insert(undocumented, cmd)
		end
	end
	for cmd in pairs(documented) do
		if not registered[cmd] then
			table.insert(stale, cmd)
		end
	end
	table.sort(undocumented)
	table.sort(stale)
	return { undocumented = undocumented, stale = stale }
end

--- Format a human-readable report.
--- @param diff { undocumented: string[], stale: string[] }
--- @return string report, number total
function M.format_report(diff)
	local lines = {}
	local total = 0

	if #diff.undocumented > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("## Undocumented commands (%d)", #diff.undocumented))
		table.insert(lines, "  -- registered in plugin/fude.lua but missing from doc/fude.txt")
		for _, cmd in ipairs(diff.undocumented) do
			table.insert(lines, "  - :" .. cmd)
		end
		total = total + #diff.undocumented
	end

	if #diff.stale > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("## Stale documentation (%d)", #diff.stale))
		table.insert(lines, "  -- documented in doc/fude.txt but not registered in plugin/fude.lua")
		for _, cmd in ipairs(diff.stale) do
			table.insert(lines, "  - :" .. cmd)
		end
		total = total + #diff.stale
	end

	if total == 0 then
		table.insert(lines, "OK: plugin/fude.lua commands match doc/fude.txt (0 discrepancies).")
	else
		table.insert(lines, "")
		table.insert(lines, string.format("FAIL: %d documentation discrepancies found.", total))
	end

	return table.concat(lines, "\n"), total
end

----------------------------------------------------------------
-- 4. Main entry
----------------------------------------------------------------

local function read_file(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text, nil
end

--- @return number  exit code
function M.main()
	local plugin_text, perr = read_file("plugin/fude.lua")
	if not plugin_text then
		io.stderr:write("Error: cannot open plugin/fude.lua: " .. (perr or "") .. "\n")
		return 2
	end
	local doc_text, derr = read_file("doc/fude.txt")
	if not doc_text then
		io.stderr:write("Error: cannot open doc/fude.txt: " .. (derr or "") .. "\n")
		return 2
	end

	local registered = M.extract_registered_commands(plugin_text)
	local documented = M.extract_documented_commands(doc_text)
	local diff = M.compare(registered, documented)
	local report, total = M.format_report(diff)
	print(report)
	return total > 0 and 1 or 0
end

if arg and arg[0] and arg[0]:match("check_docs%.lua$") then
	os.exit(M.main())
end

return M
