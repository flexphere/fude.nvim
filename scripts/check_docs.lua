-- scripts/check_docs.lua
--
-- Computational Documentation Fitness Sensor.
--
-- Verifies that user-facing surfaces in code are documented in `doc/fude.txt`:
--   1. Commands registered via `nvim_create_user_command("FudeXxx", ...)` in
--      `plugin/fude.lua` have a matching `*:FudeXxx*` helptag (bidirectional)
--   2. Top-level config keys defined in `M.defaults = { ... }` in
--      `lua/fude/config.lua` appear as `` `<key>` `` backtick references in
--      `doc/fude.txt` (forward only — see "Known limitations" below)
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
--
-- Known limitations (HARNESS.md §4.1 で追跡):
--   * Config option check is forward-only (code → doc). Reverse direction
--     (doc backticks not in code) is too fuzzy: doc references many non-config
--     identifiers (function names, type names, helptags) via backticks.
--   * Nested config keys (`signs.comment` 等) are not validated individually;
--     only top-level keys (`signs`) are checked for existence.
--   * Default value parity (doc-shown values vs code defaults) is out of scope.
--   * Keymap validation is out of scope: most documented keymaps are
--     "suggested" (not plugin-set), and the few plugin-set ones (`]c`/`[c`)
--     are mentioned in prose without structured tags.

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
-- 3. Extract top-level config option keys from lua/fude/config.lua
----------------------------------------------------------------

--- Extract top-level keys defined inside `M.defaults = { ... }`. Walks the
--- balanced `{...}` block tracking nesting depth, capturing `identifier =`
--- patterns only at depth 1 (immediately inside the outer braces).
---
--- Comments and string literals are stripped first so e.g. an example
--- `M.defaults = {...}` appearing inside a docstring is ignored.
---
--- @param config_text string  raw Lua source of lua/fude/config.lua
--- @return table<string, boolean>  set of top-level config option names
function M.extract_config_options(config_text)
	local cleaned = lua_source.strip_comments_strings(config_text)
	local block = cleaned:match("M%.defaults%s*=%s*(%b{})")
	if not block then
		return {}
	end

	local set = {}
	local depth = 0
	local i = 1
	while i <= #block do
		local c = block:sub(i, i)
		if c == "{" then
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
		elseif depth == 1 then
			-- Try to match `identifier =` (table key with `=` value form).
			-- This excludes positional values and keys using `[expr]` form.
			local _, e, id = block:find("^([%w_]+)%s*=", i)
			if id then
				set[id] = true
				i = e
			end
		end
		i = i + 1
	end
	return set
end

----------------------------------------------------------------
-- 4. Extract documented config option references from doc/fude.txt
----------------------------------------------------------------

--- Extract backtick-quoted identifiers from doc/fude.txt. Used to verify
--- config keys are *mentioned somewhere* in the doc (in either the example
--- code block or the prose Options: section).
---
--- Returns a superset of "config options" because backticks also wrap
--- function names, helptags, etc. — fine for the forward check ("is X
--- mentioned?") but unsuitable for a reverse check.
---
--- Both `` `foo` `` and `` `foo.bar` `` forms are included; only the
--- top-level identifier is captured (e.g. `signs.comment` is also indexed
--- under `signs`).
---
--- @param doc_text string  raw vim help text
--- @return table<string, boolean>  set of mentioned identifiers
function M.extract_documented_options(doc_text)
	local set = {}
	-- Standalone backtick-quoted identifier: `id`
	for id in doc_text:gmatch("`([%w_]+)`") do
		set[id] = true
	end
	-- Dotted forms like `signs.comment` — also index the top-level identifier
	for id in doc_text:gmatch("`([%w_]+)%.[%w_.]+`") do
		set[id] = true
	end
	return set
end

----------------------------------------------------------------
-- 5. Compare and report
----------------------------------------------------------------

--- Compute set differences between `code_set` and `doc_set`.
--- @param code_set table<string, boolean>
--- @param doc_set table<string, boolean>
--- @return { undocumented: string[], stale: string[] }
function M.compare(code_set, doc_set)
	local undocumented = {}
	local stale = {}
	for item in pairs(code_set) do
		if not doc_set[item] then
			table.insert(undocumented, item)
		end
	end
	for item in pairs(doc_set) do
		if not code_set[item] then
			table.insert(stale, item)
		end
	end
	table.sort(undocumented)
	table.sort(stale)
	return { undocumented = undocumented, stale = stale }
end

-- Section labels keyed by category name.
local SECTION_LABELS = {
	commands = {
		undoc_label = "Undocumented commands",
		undoc_hint = "registered in plugin/fude.lua but missing from doc/fude.txt",
		stale_label = "Stale documentation",
		stale_hint = "documented in doc/fude.txt but not registered in plugin/fude.lua",
		item_prefix = ":",
	},
	options = {
		undoc_label = "Undocumented config options",
		undoc_hint = "defined in lua/fude/config.lua M.defaults but missing from doc/fude.txt",
		stale_label = "Stale config option documentation",
		stale_hint = "referenced in doc/fude.txt but not in lua/fude/config.lua M.defaults",
		item_prefix = "",
	},
}

-- Stable section ordering for deterministic output.
local SECTION_ORDER = { "commands", "options" }

-- Internal: format a single category's lines (no global trailer).
local function format_section(diff, labels)
	local lines = {}
	local count = 0
	if #diff.undocumented > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("## %s (%d)", labels.undoc_label, #diff.undocumented))
		table.insert(lines, "  -- " .. labels.undoc_hint)
		for _, item in ipairs(diff.undocumented) do
			table.insert(lines, "  - " .. labels.item_prefix .. item)
		end
		count = count + #diff.undocumented
	end
	if #diff.stale > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("## %s (%d)", labels.stale_label, #diff.stale))
		table.insert(lines, "  -- " .. labels.stale_hint)
		for _, item in ipairs(diff.stale) do
			table.insert(lines, "  - " .. labels.item_prefix .. item)
		end
		count = count + #diff.stale
	end
	return lines, count
end

--- Format a human-readable report.
---
--- Accepts either:
---   * single-category diff (backward-compat): `{ undocumented = [], stale = [] }`
---     — treated as the `commands` category
---   * multi-category map: `{ commands = diff, options = diff }`
---
--- @param input table
--- @return string report, number total
function M.format_report(input)
	local sections
	if input.undocumented or input.stale then
		sections = { commands = input }
	else
		sections = input
	end

	local lines = {}
	local total = 0
	for _, name in ipairs(SECTION_ORDER) do
		local diff = sections[name]
		if diff then
			local sec_lines, sec_count = format_section(diff, SECTION_LABELS[name])
			for _, line in ipairs(sec_lines) do
				table.insert(lines, line)
			end
			total = total + sec_count
		end
	end

	if total == 0 then
		table.insert(lines, "OK: doc/fude.txt matches plugin/fude.lua and lua/fude/config.lua (0 discrepancies).")
	else
		table.insert(lines, "")
		table.insert(lines, string.format("FAIL: %d documentation discrepancies found.", total))
	end

	return table.concat(lines, "\n"), total
end

----------------------------------------------------------------
-- 6. Main entry
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
	local config_text, cerr = read_file("lua/fude/config.lua")
	if not config_text then
		io.stderr:write("Error: cannot open lua/fude/config.lua: " .. (cerr or "") .. "\n")
		return 2
	end

	local registered_commands = M.extract_registered_commands(plugin_text)
	local documented_commands = M.extract_documented_commands(doc_text)
	local config_options = M.extract_config_options(config_text)
	local documented_options = M.extract_documented_options(doc_text)

	-- Commands: bidirectional (undocumented + stale).
	local commands_diff = M.compare(registered_commands, documented_commands)
	-- Options: forward only (code → doc). Discard `stale` because doc backticks
	-- include many non-config identifiers (function names, helptags) and would
	-- yield massive noise. The reverse check is documented as out of scope.
	local options_diff = M.compare(config_options, documented_options)
	options_diff.stale = {}

	local report, total = M.format_report({
		commands = commands_diff,
		options = options_diff,
	})
	print(report)
	return total > 0 and 1 or 0
end

if arg and arg[0] and arg[0]:match("check_docs%.lua$") then
	os.exit(M.main())
end

return M
