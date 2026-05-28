-- scripts/check_purity.lua
--
-- Computational Architecture Fitness Sensor.
--
-- Verifies that modules declared "pure" in CLAUDE.md (no side effects, no
-- vim API, no config.state access) actually contain no forbidden patterns.
-- Target files: lua/fude/**/data.lua, lua/fude/**/format.lua.
--
-- See .claude/HARNESS.md for the conceptual framing.
--
-- Usage:
--   nvim --headless -l scripts/check_purity.lua
--
-- Exit codes:
--   0 = no violations
--   1 = violations found
--
-- Forbidden patterns (mutating / side-effectful):
--   * vim.api.*, vim.fn.*
--   * vim.cmd, vim.notify, vim.schedule, vim.system
--   * vim.o.*, vim.bo.*, vim.wo.*, vim.opt.*, vim.keymap.*
--   * config.state (direct access or `local <id> = config.state` alias)
--
-- Permitted vim.* APIs (pure utilities, not detected):
--   vim.tbl_*, vim.deepcopy, vim.trim, vim.split, vim.list_*, vim.NIL, ...

local M = {}

----------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------

local function blank_nonnewline(s)
	return (s:gsub("[^\n]", " "))
end

----------------------------------------------------------------
-- 1. Strip comments and string literals (preserve line numbers)
-- (Duplicated from scripts/check_state_deps.lua. Refactor into a shared
--  helper once a third script reuses it — YAGNI for now.)
----------------------------------------------------------------

--- Replace Lua comments and string literal contents with spaces (keeping
--- newlines for accurate line numbers).
--- @param text string
--- @return string
function M.strip_comments_strings(text)
	text = text:gsub("(%-%-)(%b[])", function(prefix, body)
		return blank_nonnewline(prefix) .. blank_nonnewline(body)
	end)
	text = text:gsub("%-%-[^\n]*", blank_nonnewline)
	text = text:gsub("%b[]", function(body)
		if body:sub(1, 2) == "[[" and body:sub(-2) == "]]" then
			return blank_nonnewline(body)
		end
		return body
	end)
	text = text:gsub('"[^"\n]*"', blank_nonnewline)
	text = text:gsub("'[^'\n]*'", blank_nonnewline)
	return text
end

----------------------------------------------------------------
-- 2. Forbidden patterns
----------------------------------------------------------------

--- Order matters only for report determinism (kept alphabetical).
M.FORBIDDEN_PATTERNS = {
	{ pattern = "vim%.api%.", desc = "vim.api.*" },
	{ pattern = "vim%.bo[%.%[]", desc = "vim.bo.* (buffer option)" },
	{ pattern = "vim%.cmd[%(%s]", desc = "vim.cmd" },
	{ pattern = "vim%.fn%.", desc = "vim.fn.*" },
	{ pattern = "vim%.keymap[%.%[]", desc = "vim.keymap.*" },
	{ pattern = "vim%.notify[%(%s]", desc = "vim.notify" },
	{ pattern = "vim%.o[%.%[]", desc = "vim.o.* (option)" },
	{ pattern = "vim%.opt[%.%[]", desc = "vim.opt.*" },
	{ pattern = "vim%.schedule[%(%s]", desc = "vim.schedule" },
	{ pattern = "vim%.system[%(%s]", desc = "vim.system" },
	{ pattern = "vim%.wo[%.%[]", desc = "vim.wo.* (window option)" },
	{ pattern = "config%.state[^%w_]", desc = "config.state (state access)" },
}

----------------------------------------------------------------
-- 3. Scan a file's text for violations
----------------------------------------------------------------

--- Scan source text and return a list of { file, line, pattern } violations.
--- Strips comments/strings first so violations inside literals are not flagged.
--- @param text string  raw Lua source
--- @param file_path string  used only for the violation record's `file` field
--- @return table[]  list of { file: string, line: number, pattern: string }
function M.scan_file_text(text, file_path)
	local cleaned = M.strip_comments_strings(text)
	local violations = {}
	local line_num = 0
	for line in (cleaned .. "\n"):gmatch("([^\n]*)\n") do
		line_num = line_num + 1
		-- Append a sentinel space so trailing-char patterns work at end of line
		local padded = line .. " "
		for _, rule in ipairs(M.FORBIDDEN_PATTERNS) do
			if padded:find(rule.pattern) then
				table.insert(violations, {
					file = file_path,
					line = line_num,
					pattern = rule.desc,
				})
			end
		end
	end
	return violations
end

----------------------------------------------------------------
-- 4. File discovery
----------------------------------------------------------------

--- List target pure files (lua/fude/**/data.lua, lua/fude/**/format.lua).
--- Uses vim.fn.glob when available, falls back to `find`.
--- @return string[]  sorted file paths
function M.list_pure_files()
	if vim and vim.fn and vim.fn.glob then
		local files = {}
		for _, p in ipairs(vim.fn.glob("lua/fude/**/data.lua", false, true)) do
			table.insert(files, p)
		end
		for _, p in ipairs(vim.fn.glob("lua/fude/**/format.lua", false, true)) do
			table.insert(files, p)
		end
		table.sort(files)
		return files
	end
	local handle = io.popen('find lua/fude -type f \\( -name "data.lua" -o -name "format.lua" \\)')
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

--- Read a file and scan it; returns (violations, err).
--- @param file_path string
--- @return table[]|nil violations, string|nil err
function M.scan_file(file_path)
	local f, err = io.open(file_path, "r")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return M.scan_file_text(text, file_path), nil
end

----------------------------------------------------------------
-- 5. Report formatting
----------------------------------------------------------------

--- Group violations by file and format a human-readable report.
--- @param violations table[]  flat list of violation records
--- @return string report, number total
function M.format_report(violations)
	local by_file = {}
	for _, v in ipairs(violations) do
		by_file[v.file] = by_file[v.file] or {}
		table.insert(by_file[v.file], v)
	end
	local files = {}
	for f in pairs(by_file) do
		table.insert(files, f)
	end
	table.sort(files)

	local lines = {}
	local total = 0
	for _, file in ipairs(files) do
		local vs = by_file[file]
		-- Ensure stable ordering within a file: by line then by description
		table.sort(vs, function(a, b)
			if a.line ~= b.line then
				return a.line < b.line
			end
			return a.pattern < b.pattern
		end)
		table.insert(lines, "")
		table.insert(lines, string.format("## %s (%d)", file, #vs))
		for _, v in ipairs(vs) do
			table.insert(lines, string.format("  %s:%d: %s", v.file, v.line, v.pattern))
		end
		total = total + #vs
	end

	if total == 0 then
		table.insert(lines, "OK: all purity-declared modules are pure (0 violations).")
	else
		table.insert(lines, "")
		table.insert(lines, string.format("FAIL: %d purity violations found.", total))
	end

	return table.concat(lines, "\n"), total
end

----------------------------------------------------------------
-- 6. Main entry
----------------------------------------------------------------

--- @return number  exit code
function M.main()
	local files = M.list_pure_files()
	local all_violations = {}
	for _, file in ipairs(files) do
		local violations, err = M.scan_file(file)
		if err then
			io.stderr:write("Warning: cannot read " .. file .. ": " .. err .. "\n")
		else
			for _, v in ipairs(violations) do
				table.insert(all_violations, v)
			end
		end
	end
	local report, total = M.format_report(all_violations)
	print(report)
	return total > 0 and 1 or 0
end

----------------------------------------------------------------
-- Direct-execution entry: `nvim --headless -l scripts/check_purity.lua`
----------------------------------------------------------------

if arg and arg[0] and arg[0]:match("check_purity%.lua$") then
	os.exit(M.main())
end

return M
