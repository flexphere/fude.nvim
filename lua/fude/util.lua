local M = {}

--- Check if a value is null (nil or vim.NIL).
--- JSON null may decode as nil (Neovim 0.11) or vim.NIL (Neovim 0.12).
--- This helper normalizes both cases for consistent null checking.
--- @param v any
--- @return boolean
function M.is_null(v)
	return v == nil or v == vim.NIL
end

--- Replace a JSON null (nil or vim.NIL) with `default`, otherwise return the
--- value as-is. Use this instead of the `and-or` idiom: `is_null(x) and d or x`
--- returns x (possibly vim.NIL) whenever d is nil/false, so it cannot express
--- "null becomes nil".
--- @param v any
--- @param default any
--- @return any
function M.null_to(v, default)
	if M.is_null(v) then
		return default
	end
	return v
end

--- Compare two paths byte by byte, the order git and the GitHub PR file list
--- use (uppercase before lowercase, `ui.lua` before `ui/`). Lua's `<` is not
--- used because PUC Lua compares strings with strcoll, which depends on the
--- locale.
--- @param a string
--- @param b string
--- @return boolean true when `a` sorts before `b`
function M.path_less(a, b)
	for i = 1, math.min(#a, #b) do
		local x, y = a:byte(i), b:byte(i)
		if x ~= y then
			return x < y
		end
	end
	return #a < #b
end

--- Check whether every comment in the list is resolved.
--- Shared by the comment browser entries, the comment viewer title, and the
--- virtualText indicator so the "all resolved" rule stays consistent.
--- @param comments table[] list of comment objects
--- @return boolean false for an empty list
function M.all_comments_resolved(comments)
	if #comments == 0 then
		return false
	end
	for _, c in ipairs(comments) do
		if not c.is_resolved then
			return false
		end
	end
	return true
end

--- Copy text to the unnamed register and, when a clipboard provider exists,
--- to the `+` register. `+` is never read back to check the copy: with the
--- OSC 52 provider that read is a terminal query that may block or fail
--- spuriously.
--- @param text string
--- @return boolean true when `+` was set too, false when only the unnamed register was
function M.copy_to_clipboard(text)
	vim.fn.setreg('"', text)
	return vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", text) or false
end

--- Open a URL in the browser through `vim.ui.open`. With no URL, `reason`
--- (why there is nothing to open) is shown as an INFO instead, so callers can
--- pass a `url, reason` pair from a `find_*_url` helper straight through.
--- @param url string|nil
--- @param reason string|nil message shown when url is nil
--- @return boolean opened whether vim.ui.open was started
function M.open_url(url, reason)
	if type(url) ~= "string" or url == "" then
		vim.notify("fude.nvim: " .. (reason or "Nothing to open in the browser"), vim.log.levels.INFO)
		return false
	end
	local ok, cmd_or_err, err = pcall(vim.ui.open, url)
	if not ok or not cmd_or_err then
		local msg = not ok and cmd_or_err or err
		vim.notify("fude.nvim: Failed to open " .. url .. ": " .. tostring(msg), vim.log.levels.ERROR)
		return false
	end
	return true
end

return M
