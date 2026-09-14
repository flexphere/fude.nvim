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

return M
