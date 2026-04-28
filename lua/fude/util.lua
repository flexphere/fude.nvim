local M = {}

--- Check if a value is null (nil or vim.NIL).
--- JSON null may decode as nil (Neovim 0.11) or vim.NIL (Neovim 0.12).
--- This helper normalizes both cases for consistent null checking.
--- @param v any
--- @return boolean
function M.is_null(v)
    return v == nil or v == vim.NIL
end

--- Check if a string is empty or nil.
--- @param s string|nil
--- @return boolean
function M.is_empty(s)
    return s == nil or s == ""
end

return M
