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

--- Whether a Telescope refresh for `prompt` should move the selection back to
--- the first row: when the prompt changed since the last refresh (the user typed
--- or deleted), not when the picker refreshed itself with the same prompt.
--- @param prompt string|nil
--- @param last_prompt string|nil
--- @return boolean
function M.should_reset_selection(prompt, last_prompt)
	return prompt ~= last_prompt
end

--- Make a Telescope picker select its first row whenever the prompt changes,
--- whatever `selection_strategy` the picker or the user's config uses; a
--- refresh with the same prompt (e.g. after a `<Tab>` toggle) keeps the
--- picker's own strategy. Wraps the picker's `_do_selection`, which Telescope
--- calls with the prompt once a refresh completed; a picker without one is
--- returned unchanged.
--- @param picker table
--- @return table picker
function M.reset_selection_on_prompt_change(picker)
	local do_selection = type(picker) == "table" and picker._do_selection or nil
	if type(do_selection) ~= "function" then
		return picker
	end
	local last_prompt
	local seen = false
	picker._do_selection = function(self, prompt, ...)
		local reset = seen and M.should_reset_selection(prompt, last_prompt)
		seen, last_prompt = true, prompt
		if reset and type(self.get_reset_row) == "function" then
			return self:set_selection(self:get_reset_row())
		end
		return do_selection(self, prompt, ...)
	end
	return picker
end

return M
