-- scripts/lib/lua_source.lua
--
-- Shared Lua source-parsing helpers for sensor scripts.
-- Currently exposes `strip_comments_strings`, used by:
--   * scripts/check_state_deps.lua
--   * scripts/check_purity.lua
--   * scripts/check_docs.lua

local M = {}

local function blank_nonnewline(s)
	return (s:gsub("[^\n]", " "))
end

--- Replace Lua comments and string literal contents with spaces (keeping
--- newlines for accurate line numbers).
--- Handles: -- line, --[[ block ]], [[ long string ]], "...", '...'.
--- Does NOT handle level-N long brackets like [==[...]==] (unused in lua/fude/).
--- @param text string
--- @return string
function M.strip_comments_strings(text)
	-- (1) Block comments: --[[ ... ]] (greedy balanced)
	text = text:gsub("(%-%-)(%b[])", function(prefix, body)
		return blank_nonnewline(prefix) .. blank_nonnewline(body)
	end)
	-- (2) Line comments: --... up to newline
	text = text:gsub("%-%-[^\n]*", blank_nonnewline)
	-- (3) Long strings: [[ ... ]] (after comments stripped)
	text = text:gsub("%b[]", function(body)
		if body:sub(1, 2) == "[[" and body:sub(-2) == "]]" then
			return blank_nonnewline(body)
		end
		return body
	end)
	-- (4) Double-quoted strings (single-line)
	text = text:gsub('"[^"\n]*"', blank_nonnewline)
	-- (5) Single-quoted strings (single-line)
	text = text:gsub("'[^'\n]*'", blank_nonnewline)
	return text
end

return M
