-- scripts/check_claude_md.lua
--
-- Computational Documentation Fitness Sensor.
--
-- Verifies that CLAUDE.md stays under a character limit. CLAUDE.md is loaded
-- into every agent session, and Claude Code warns once it grows past 150k
-- characters, so it holds only a map of the modules; the module details live
-- in docs/architecture/.
--
-- See .claude/HARNESS.md §2 for the conceptual framing.
--
-- Usage:
--   nvim --headless -l scripts/check_claude_md.lua
--
-- Exit codes:
--   0 = within the limit
--   1 = over the limit
--   2 = setup / IO error
--
-- The count is in characters (UTF-8 code points, as `wc -m`), not bytes.

local M = {}

--- Maximum number of characters allowed in CLAUDE.md.
M.LIMIT = 50000

--- Count the characters (UTF-8 code points) of a string, like `wc -m`.
--- @param text string
--- @return integer
function M.count_chars(text)
	-- Every code point has exactly one byte that is not a continuation byte.
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

--- Build the report for a CLAUDE.md of `count` characters.
--- @param count integer
--- @param limit integer
--- @return string report
--- @return boolean ok
function M.format_report(count, limit)
	if count <= limit then
		return string.format("OK: CLAUDE.md is %d characters (limit %d).", count, limit), true
	end
	return table.concat({
		string.format("FAIL: CLAUDE.md is %d characters, %d over the limit of %d.", count, count - limit, limit),
		"  CLAUDE.md holds only a one or two line summary per module.",
		"  Write module details in the module's file under docs/architecture/ and keep the summary here.",
	}, "\n"),
		false
end

local function read_file(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text, nil
end

function M.main()
	local text, err = read_file("CLAUDE.md")
	if not text then
		io.stderr:write("Error: cannot open CLAUDE.md: " .. (err or "") .. "\n")
		return 2
	end
	local report, ok = M.format_report(M.count_chars(text), M.LIMIT)
	print(report)
	return ok and 0 or 1
end

if arg and arg[0] and arg[0]:match("check_claude_md%.lua$") then
	os.exit(M.main())
end

return M
