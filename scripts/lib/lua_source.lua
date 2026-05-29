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

--- Replace Lua comments (both `--` line and `--[[ ]]` block) with spaces,
--- keeping newlines for accurate line numbers. Strings are NOT touched.
--- Use this when string literal contents are part of the source-of-truth being
--- checked (e.g. command names inside `nvim_create_user_command("Foo", ...)`).
--- @param text string
--- @return string
function M.strip_comments_only(text)
	text = text:gsub("(%-%-)(%b[])", function(prefix, body)
		return blank_nonnewline(prefix) .. blank_nonnewline(body)
	end)
	text = text:gsub("%-%-[^\n]*", blank_nonnewline)
	return text
end

--- Replace Lua comments AND string literal contents with spaces (keeping
--- newlines for accurate line numbers).
--- Handles: -- line, --[[ block ]], [[ long string ]], "...", '...'.
--- Does NOT handle level-N long brackets like [==[...]==] (unused in lua/fude/).
--- Use this when string contents could contain false-positive patterns (e.g.
--- `config.state.foo` inside an error message).
--- @param text string
--- @return string
function M.strip_comments_strings(text)
	text = M.strip_comments_only(text)
	-- Long strings: [[ ... ]] (after comments stripped)
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

return M
