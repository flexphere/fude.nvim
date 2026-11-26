-- scripts/check_claude_md.lua
--
-- Computational Documentation Size / Layout Sensor.
--
-- Verifies that the agent-facing documentation stays within budget and in step
-- with the module layout:
--   1. `CLAUDE.md` is at most `M.MAX_CHARS` characters (UTF-8 characters, not
--      bytes — the same count as `wc -m` in a UTF-8 locale)
--   2. Every `lua/fude/<path>.lua` has a matching
--      `docs/architecture/<path>.md` (e.g. `lua/fude/local/session.lua` →
--      `docs/architecture/local/session.md`)
--   3. Every `docs/architecture/<path>.md` has a matching `lua/fude/<path>.lua`
--
-- Only existence and correspondence are checked; the contents of the
-- architecture documents are not validated.
--
-- See .claude/HARNESS.md for the conceptual framing.
--
-- Usage:
--   nvim --headless -l scripts/check_claude_md.lua
--
-- Exit codes:
--   0 = no problems
--   1 = problems found
--   2 = setup / IO error

-- Bootstrap package.path for consistency with the other scripts (tests already
-- extend package.path via tests/minimal_init.lua).
package.path = "scripts/?.lua;" .. package.path

local M = {}

--- Upper bound for the number of UTF-8 characters in CLAUDE.md.
M.MAX_CHARS = 40000

M.CLAUDE_MD = "CLAUDE.md"
M.MODULE_ROOT = "lua/fude"
M.DOC_ROOT = "docs/architecture"

----------------------------------------------------------------
-- 1. CLAUDE.md size
----------------------------------------------------------------

--- Count UTF-8 characters: every byte that is not a continuation byte
--- (0x80-0xBF) starts a character. Invalid sequences are counted per lead byte,
--- which is close enough for a budget check.
--- @param text string
--- @return integer
function M.count_utf8_chars(text)
	local _, continuation = text:gsub("[\128-\191]", "")
	return #text - continuation
end

--- @param count integer  number of characters
--- @param limit integer  maximum allowed
--- @return boolean  true when the count is within the limit (inclusive)
function M.is_within_limit(count, limit)
	return count <= limit
end

----------------------------------------------------------------
-- 2. Module ↔ document mapping
----------------------------------------------------------------

--- `local/session.lua` → `local/session.md`; nil for a non-.lua path.
--- @param rel string  path relative to lua/fude/
--- @return string|nil
function M.module_to_doc(rel)
	local base = rel:match("^(.+)%.lua$")
	return base and (base .. ".md") or nil
end

--- `local/session.md` → `local/session.lua`; nil for a non-.md path.
--- @param rel string  path relative to docs/architecture/
--- @return string|nil
function M.doc_to_module(rel)
	local base = rel:match("^(.+)%.md$")
	return base and (base .. ".lua") or nil
end

--- Strip `root/` from the front of `path`; nil when `path` is not under `root`.
--- @param path string
--- @param root string
--- @return string|nil
function M.relative_to(path, root)
	local prefix = root:gsub("/+$", "") .. "/"
	if path:sub(1, #prefix) == prefix and #path > #prefix then
		return path:sub(#prefix + 1)
	end
	return nil
end

--- Compare module paths with document paths.
--- @param module_rels string[]  .lua paths relative to lua/fude/
--- @param doc_rels string[]  .md paths relative to docs/architecture/
--- @return { missing: string[], extra: string[] }
---   missing: document paths (relative to docs/architecture/) a module lacks
---   extra: document paths with no module, both sorted
function M.find_mismatches(module_rels, doc_rels)
	local docs = {}
	for _, d in ipairs(doc_rels) do
		docs[d] = true
	end
	local modules = {}
	for _, m in ipairs(module_rels) do
		modules[m] = true
	end

	local missing = {}
	for _, m in ipairs(module_rels) do
		local d = M.module_to_doc(m)
		if d and not docs[d] then
			table.insert(missing, d)
		end
	end
	local extra = {}
	for _, d in ipairs(doc_rels) do
		local m = M.doc_to_module(d)
		if m and not modules[m] then
			table.insert(extra, d)
		end
	end
	table.sort(missing)
	table.sort(extra)
	return { missing = missing, extra = extra }
end

----------------------------------------------------------------
-- 3. Report
----------------------------------------------------------------

--- @param input { char_count: integer, limit: integer, missing: string[], extra: string[] }
--- @return string report, integer problem_count
function M.format_report(input)
	local lines = {}
	local total = 0

	if M.is_within_limit(input.char_count, input.limit) then
		table.insert(lines, string.format("OK: %s is %d / %d characters.", M.CLAUDE_MD, input.char_count, input.limit))
	else
		total = total + 1
		table.insert(
			lines,
			string.format(
				"%s: %d characters exceeds the limit of %d (over by %d). Move details to %s/.",
				M.CLAUDE_MD,
				input.char_count,
				input.limit,
				input.char_count - input.limit,
				M.DOC_ROOT
			)
		)
	end

	if #input.missing > 0 then
		total = total + #input.missing
		table.insert(lines, "")
		table.insert(lines, string.format("Modules without an architecture doc (%d):", #input.missing))
		for _, d in ipairs(input.missing) do
			table.insert(
				lines,
				string.format("  %s/%s: missing (for %s/%s)", M.DOC_ROOT, d, M.MODULE_ROOT, M.doc_to_module(d))
			)
		end
	end

	if #input.extra > 0 then
		total = total + #input.extra
		table.insert(lines, "")
		table.insert(lines, string.format("Architecture docs without a module (%d):", #input.extra))
		for _, d in ipairs(input.extra) do
			table.insert(lines, string.format("  %s/%s: no %s/%s", M.DOC_ROOT, d, M.MODULE_ROOT, M.doc_to_module(d)))
		end
	end

	table.insert(lines, "")
	if total == 0 then
		table.insert(lines, string.format("OK: %s/ matches %s/ (0 problems).", M.DOC_ROOT, M.MODULE_ROOT))
	else
		table.insert(lines, string.format("FAIL: %d problems found.", total))
	end
	return table.concat(lines, "\n"), total
end

----------------------------------------------------------------
-- 4. Main entry
----------------------------------------------------------------

local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text, nil
end

--- Files under `root` with extension `ext`, relative to `root`.
local function list_relative(root, ext)
	local rels = {}
	for _, p in ipairs(vim.fn.glob(root .. "/**/*." .. ext, false, true)) do
		local rel = M.relative_to(p, root)
		if rel and vim.fn.filereadable(p) == 1 then
			table.insert(rels, rel)
		end
	end
	table.sort(rels)
	return rels
end

--- @return number  exit code
function M.main()
	local text, err = read_file(M.CLAUDE_MD)
	if not text then
		io.stderr:write("Error: cannot open " .. M.CLAUDE_MD .. ": " .. (err or "") .. "\n")
		return 2
	end
	if vim.fn.isdirectory(M.MODULE_ROOT) ~= 1 then
		io.stderr:write("Error: " .. M.MODULE_ROOT .. "/ not found (run from the repository root)\n")
		return 2
	end

	local module_rels = list_relative(M.MODULE_ROOT, "lua")
	-- A missing docs/architecture/ is not an IO error: every module is reported missing.
	local doc_rels = vim.fn.isdirectory(M.DOC_ROOT) == 1 and list_relative(M.DOC_ROOT, "md") or {}

	local diff = M.find_mismatches(module_rels, doc_rels)
	local report, total = M.format_report({
		char_count = M.count_utf8_chars(text),
		limit = M.MAX_CHARS,
		missing = diff.missing,
		extra = diff.extra,
	})
	print(report)
	return total > 0 and 1 or 0
end

if arg and arg[0] and arg[0]:match("check_claude_md%.lua$") then
	os.exit(M.main())
end

return M
