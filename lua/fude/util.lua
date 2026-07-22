local M = {}

--- Check if a value is null (nil or vim.NIL).
--- JSON null may decode as nil (Neovim 0.11) or vim.NIL (Neovim 0.12).
--- This helper normalizes both cases for consistent null checking.
--- @param v any
--- @return boolean
function M.is_null(v)
	return v == nil or v == vim.NIL
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
