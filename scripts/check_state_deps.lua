-- scripts/check_state_deps.lua
--
-- Computational Architecture Fitness Sensor.
--
-- Verifies that the "State Dependencies" table in CLAUDE.md matches the actual
-- writes (W) and reads (R) of `config.state.<field>` performed by modules under
-- lua/fude/. See .claude/HARNESS.md for the conceptual framing.
--
-- Usage:
--   nvim --headless -l scripts/check_state_deps.lua            -- check
--   nvim --headless -l scripts/check_state_deps.lua --verbose  -- with details
--
-- Exit codes:
--   0 = no discrepancies
--   1 = discrepancies found
--   2 = setup / IO error
--
-- Limitations (documented in HARNESS.md §4):
--   * Multi-LHS assignment `state.a, state.b = 1, 2` only detects the last LHS as W
--   * Dynamic field access `state[key]` is not detected
--   * Greedy file-wide alias scope (per-function shadowing of `state` may cause
--     false positives — currently no such pattern exists in lua/fude/)

-- Bootstrap package.path so direct execution (`nvim --headless -l ...`) can
-- resolve `require("lib.lua_source")`. Tests already extend package.path via
-- tests/minimal_init.lua, so this is a no-op there.
package.path = "scripts/?.lua;" .. package.path

local M = {}

local lua_source = require("lib.lua_source")

----------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------

local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

local function escape_pattern(s)
	return (s:gsub("([().%%+%-*?[%]^$])", "%%%1"))
end

----------------------------------------------------------------
-- 1. Strip comments and string literals (delegated to lib.lua_source)
----------------------------------------------------------------

--- Re-export of `lib.lua_source.strip_comments_strings`. Kept on M so existing
--- tests (`check_state_deps.strip_comments_strings`) continue to work.
M.strip_comments_strings = lua_source.strip_comments_strings

----------------------------------------------------------------
-- 2. Parse the State Dependencies markdown table
----------------------------------------------------------------

--- Parse a comma-separated module list cell. Strips parenthesized suffixes
--- like "init(reload)" -> "init" so sub-categories collapse to parent module.
--- @param text string
--- @return table<string, boolean>
local function parse_module_list(text)
	local set = {}
	for raw in text:gmatch("([^,]+)") do
		local mod = raw:gsub("%(.-%)", "")
		mod = trim(mod)
		if mod ~= "" then
			set[mod] = true
		end
	end
	return set
end

--- Parse a markdown table row into cells.
--- For `| a | b | c |`, returns { "a", "b", "c" }.
--- @param line string
--- @return string[]
local function parse_row(line)
	local cells = {}
	for cell in line:gmatch("|([^|]*)") do
		table.insert(cells, cell)
	end
	-- Trailing | produces an empty trailing cell; drop it
	if #cells > 0 and trim(cells[#cells]) == "" then
		table.remove(cells)
	end
	return cells
end

--- Parse the State Dependencies table inside CLAUDE.md.
--- @param md_text string
--- @return table<string, { W: table<string, boolean>, R: table<string, boolean> }>
function M.parse_state_table(md_text)
	local result = {}
	local in_table = false
	local seen_separator = false

	for line in (md_text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^%s*|%s*Field%s*|") then
			in_table = true
			seen_separator = false
		elseif in_table and not seen_separator and line:match("^%s*|%s*%-") then
			seen_separator = true
		elseif in_table and seen_separator then
			if line:match("^%s*|") then
				local cells = parse_row(line)
				if #cells >= 3 then
					local field = cells[1]:match("`([^`]+)`")
					if field then
						result[field] = {
							W = parse_module_list(cells[2]),
							R = parse_module_list(cells[3]),
						}
					end
				end
			else
				-- Blank line or non-row content ends the table
				in_table = false
				seen_separator = false
			end
		end
	end

	return result
end

----------------------------------------------------------------
-- 3. Extract aliases bound to config.state
----------------------------------------------------------------

--- Collect names bound to `config.state` in the source (`local <id> = config.state`).
--- Always includes `config.state` itself. Does NOT include single-field copies
--- like `local x = config.state.foo` (those are tracked separately as R).
--- @param cleaned_src string source with comments/strings stripped
--- @return table<string, boolean>
function M.extract_aliases(cleaned_src)
	local aliases = { ["config.state"] = true }
	-- Sentinel so end-of-file matches behave consistently
	local src = cleaned_src .. "\n"
	for id in src:gmatch("local%s+([%w_]+)%s*=%s*config%.state[^%w_.]") do
		aliases[id] = true
	end
	return aliases
end

----------------------------------------------------------------
-- 4. Extract field accesses via aliases (W/R)
----------------------------------------------------------------

--- For a single alias name like "state" or "config.state", find every
--- `<alias>.<field>` occurrence in `src` and classify as W or R. Updates
--- `result` in place.
---
--- Classification rules:
---   * `state.foo = ...`                  → W on foo (rebinding)
---   * `state.foo.bar = ...` / `state.foo[k] = ...` (chained assignment)
---                                        → W on foo (mutating foo's contents)
---   * `state.foo:method(...)`            → R on foo (method call cannot statically
---                                          guarantee mutation)
---   * everything else                    → R on foo
---
--- @param result table<string, { W: boolean, R: boolean }>
--- @param src string  cleaned source (with trailing sentinel)
--- @param alias string  the alias name to scan for
local function scan_alias(result, src, alias)
	local ap = escape_pattern(alias)
	local pos = 1
	while true do
		local s, e, field = src:find(ap .. "%.([%w_]+)", pos)
		if not s then
			break
		end
		-- Ensure alias isn't a suffix of a longer identifier (e.g., other_state.foo)
		local prev_char = s > 1 and src:sub(s - 1, s - 1) or " "
		if not prev_char:match("[%w_.]") then
			result[field] = result[field] or { W = false, R = false }
			-- Walk forward over chained `.id` and `[expr]` access — these still
			-- target `field` (rebinding sub-keys is a write to field's contents).
			-- A `:method()` call breaks out as R since we cannot prove mutation.
			local chain_end = e
			local saw_method = false
			while true do
				local rest = src:sub(chain_end + 1)
				local ws = rest:match("^%s*") or ""
				local c = rest:sub(#ws + 1, #ws + 1)
				if c == "." then
					local id = rest:match("^%s*%.([%w_]+)")
					if not id then
						break
					end
					chain_end = chain_end + #ws + 1 + #id
				elseif c == "[" then
					local bracketed = rest:match("^%s*(%b[])")
					if not bracketed then
						break
					end
					chain_end = chain_end + #ws + #bracketed
				elseif c == ":" then
					saw_method = true
					break
				else
					break
				end
			end
			if saw_method then
				result[field].R = true
			else
				local after = src:sub(chain_end + 1):match("^%s*(.?.?)") or ""
				if after:sub(1, 1) == "=" and after:sub(2, 2) ~= "=" then
					result[field].W = true
				else
					result[field].R = true
				end
			end
		end
		pos = e + 1
	end
end

--- Walk `cleaned_src` and return per-field { W, R } accesses for the given alias set.
--- @param cleaned_src string
--- @param aliases table<string, boolean>
--- @return table<string, { W: boolean, R: boolean }>
function M.extract_field_accesses(cleaned_src, aliases)
	local result = {}
	local src = cleaned_src .. " " -- trailing sentinel for look-ahead
	-- Process longer alias paths first so e.g. "config.state" matches before "state"
	local names = {}
	for k in pairs(aliases) do
		table.insert(names, k)
	end
	table.sort(names, function(a, b)
		return #a > #b
	end)
	for _, name in ipairs(names) do
		scan_alias(result, src, name)
	end
	return result
end

----------------------------------------------------------------
-- 5. Scan one module (text -> accesses)
----------------------------------------------------------------

--- @param text string  raw Lua source
--- @param module_name string|nil  module name (used to enable file-specific quirks)
--- @return table<string, { W: boolean, R: boolean }>
function M.scan_module_text(text, module_name)
	local cleaned = M.strip_comments_strings(text)
	local aliases = M.extract_aliases(cleaned)
	-- config.lua exposes state directly as M.state — treat M.state as config.state
	if module_name == "config" then
		aliases["M.state"] = true
	end
	return M.extract_field_accesses(cleaned, aliases)
end

--- Convert a file path under lua/fude/ to its module name.
--- "lua/fude/comments/sync.lua" -> "comments/sync"
--- @param file_path string
--- @return string|nil
function M.path_to_module(file_path)
	return file_path:match("lua/fude/(.+)%.lua$")
end

--- Read a Lua source file and return its access map.
--- @param file_path string
--- @param module_name string|nil
--- @return table<string, { W: boolean, R: boolean }>|nil, string|nil  accesses, error
function M.scan_module_file(file_path, module_name)
	local f, err = io.open(file_path, "r")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return M.scan_module_text(text, module_name), nil
end

----------------------------------------------------------------
-- 6. Compare table data vs code data
----------------------------------------------------------------

--- Compute discrepancies between the declared table and observed code accesses.
--- @param table_data table<string, { W: table<string,boolean>, R: table<string,boolean> }>
--- @param code_data table<string, table<string, { W: boolean, R: boolean }>>  per-module accesses
--- @return table  discrepancies: { missing_w, missing_r, false_w, false_r, unknown_fields, dead_fields }
function M.compare(table_data, code_data)
	local d = {
		missing_w = {},
		missing_r = {},
		false_w = {},
		false_r = {},
		unknown_fields = {},
		dead_fields = {},
	}

	-- Code -> table coverage
	for module, fields in pairs(code_data) do
		for field, access in pairs(fields) do
			if not table_data[field] then
				table.insert(d.unknown_fields, { field = field, module = module })
			else
				if access.W and not table_data[field].W[module] then
					table.insert(d.missing_w, { module = module, field = field })
				end
				if access.R and not table_data[field].R[module] then
					table.insert(d.missing_r, { module = module, field = field })
				end
			end
		end
	end

	-- Table -> code coverage
	for field, entry in pairs(table_data) do
		for module in pairs(entry.W) do
			if not (code_data[module] and code_data[module][field] and code_data[module][field].W) then
				table.insert(d.false_w, { module = module, field = field })
			end
		end
		for module in pairs(entry.R) do
			if not (code_data[module] and code_data[module][field] and code_data[module][field].R) then
				table.insert(d.false_r, { module = module, field = field })
			end
		end
		-- Dead field: row exists, no module accesses the field at all
		local used = false
		for _, fields in pairs(code_data) do
			if fields[field] then
				used = true
				break
			end
		end
		if not used then
			table.insert(d.dead_fields, field)
		end
	end

	-- Deterministic ordering
	local function sort_mf(t)
		table.sort(t, function(a, b)
			if a.field ~= b.field then
				return a.field < b.field
			end
			return a.module < b.module
		end)
	end
	sort_mf(d.missing_w)
	sort_mf(d.missing_r)
	sort_mf(d.false_w)
	sort_mf(d.false_r)
	sort_mf(d.unknown_fields)
	table.sort(d.dead_fields)

	return d
end

----------------------------------------------------------------
-- 7. Format report
----------------------------------------------------------------

--- @param d table  discrepancies from M.compare
--- @return string report, number total
function M.format_report(d)
	local lines = {}
	local total = 0
	local function header(title, items)
		if #items > 0 then
			table.insert(lines, "")
			table.insert(lines, string.format("## %s (%d)", title, #items))
		end
	end
	local function emit_mf(items)
		for _, e in ipairs(items) do
			table.insert(lines, string.format("  - %s : %s", e.field, e.module))
		end
		total = total + #items
	end

	header("Missing W (code writes but table does not list module)", d.missing_w)
	emit_mf(d.missing_w)
	header("Missing R (code reads but table does not list module)", d.missing_r)
	emit_mf(d.missing_r)
	header("False W (table lists module as W, code does not write)", d.false_w)
	emit_mf(d.false_w)
	header("False R (table lists module as R, code does not read)", d.false_r)
	emit_mf(d.false_r)
	header("Unknown fields (code accesses field, no table row)", d.unknown_fields)
	emit_mf(d.unknown_fields)
	if #d.dead_fields > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("## Dead fields (table row, no code access) (%d)", #d.dead_fields))
		for _, f in ipairs(d.dead_fields) do
			table.insert(lines, "  - " .. f)
		end
		total = total + #d.dead_fields
	end

	if total == 0 then
		table.insert(lines, "OK: State Dependencies table matches code (0 discrepancies).")
	else
		table.insert(lines, "")
		table.insert(lines, string.format("FAIL: %d discrepancies found.", total))
	end

	return table.concat(lines, "\n"), total
end

----------------------------------------------------------------
-- 8. File listing
----------------------------------------------------------------

--- List Lua files under `root` (recursive, sorted).
--- Uses vim.fn.glob when available, falls back to `find` for non-nvim execution.
--- @param root string
--- @return string[]
function M.list_lua_files(root)
	if vim and vim.fn and vim.fn.glob then
		local out = vim.fn.glob(root .. "/**/*.lua", false, true)
		table.sort(out)
		return out
	end
	local handle = io.popen('find "' .. root .. '" -name "*.lua" -type f')
	if not handle then
		return {}
	end
	local out = handle:read("*a")
	handle:close()
	local files = {}
	for line in out:gmatch("[^\n]+") do
		table.insert(files, line)
	end
	table.sort(files)
	return files
end

----------------------------------------------------------------
-- 9. Main entry
----------------------------------------------------------------

--- @return number  exit code
function M.main()
	local claude_md_path = "CLAUDE.md"
	local lua_root = "lua/fude"

	-- Read CLAUDE.md
	local f, err = io.open(claude_md_path, "r")
	if not f then
		io.stderr:write("Error: cannot open " .. claude_md_path .. ": " .. (err or "") .. "\n")
		return 2
	end
	local md_text = f:read("*a")
	f:close()

	local table_data = M.parse_state_table(md_text)
	if next(table_data) == nil then
		io.stderr:write("Error: no State Dependencies table found in " .. claude_md_path .. "\n")
		return 2
	end

	local code_data = {}
	for _, file_path in ipairs(M.list_lua_files(lua_root)) do
		local module = M.path_to_module(file_path)
		if module then
			local accesses, scan_err = M.scan_module_file(file_path, module)
			if scan_err then
				io.stderr:write("Warning: cannot scan " .. file_path .. ": " .. scan_err .. "\n")
			elseif accesses and next(accesses) then
				code_data[module] = accesses
			end
		end
	end

	local discrepancies = M.compare(table_data, code_data)
	local report, total = M.format_report(discrepancies)
	print(report)

	return total > 0 and 1 or 0
end

----------------------------------------------------------------
-- Direct-execution entry: `nvim --headless -l scripts/check_state_deps.lua`
----------------------------------------------------------------

if arg and arg[0] and arg[0]:match("check_state_deps%.lua$") then
	os.exit(M.main())
end

return M
