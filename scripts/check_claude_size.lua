-- scripts/check_claude_size.lua
--
-- Computational Context-Size Sensor.
--
-- Fails when CLAUDE.md grows beyond LIMIT characters. Claude Code warns when
-- CLAUDE.md exceeds its character limit, and every character is loaded into
-- each session's context, so module details belong in
-- docs/architecture/<module>.md rather than in CLAUDE.md itself.
--
-- Usage:
--   nvim --headless -l scripts/check_claude_size.lua
--
-- Exit codes:
--   0 = CLAUDE.md is within the limit
--   1 = CLAUDE.md exceeds the limit, or cannot be read

local M = {}

--- Maximum number of characters allowed in CLAUDE.md.
M.LIMIT = 40000

--- Count characters (UTF-8 code points), not bytes: "あ" counts as 1.
--- Every byte that is not a UTF-8 continuation byte (0x80-0xBF) starts a
--- character.
--- @param text string
--- @return number
function M.count_chars(text)
	local _, count = text:gsub("[^\128-\191]", "")
	return count
end

--- @param text string
--- @param limit number|nil  defaults to M.LIMIT
--- @return boolean ok, number count
function M.check(text, limit)
	local count = M.count_chars(text)
	return count <= (limit or M.LIMIT), count
end

--- @return number  exit code
function M.main()
	local path = "CLAUDE.md"
	local f, err = io.open(path, "r")
	if not f then
		io.stderr:write("Error: cannot open " .. path .. ": " .. (err or "") .. "\n")
		return 1
	end
	local text = f:read("*a")
	f:close()

	local ok, count = M.check(text, M.LIMIT)
	io.stdout:write(string.format("%s: %d / %d chars\n", path, count, M.LIMIT))
	if not ok then
		io.stdout:write(
			string.format(
				"CLAUDE.md exceeds the limit by %d chars. Move module details into "
					.. "docs/architecture/<module>.md and keep only a short summary and a link in CLAUDE.md.\n",
				count - M.LIMIT
			)
		)
		return 1
	end
	return 0
end

----------------------------------------------------------------
-- Direct-execution entry: `nvim --headless -l scripts/check_claude_size.lua`
----------------------------------------------------------------

if arg and arg[0] and arg[0]:match("check_claude_size%.lua$") then
	os.exit(M.main())
end

return M
