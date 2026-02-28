local M = {}

--- Get the git repository root directory.
--- @return string|nil
function M.get_repo_root()
	local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Strip a root prefix from a normalized absolute path.
--- @param filepath string absolute file path (already normalized)
--- @param root string repository root directory (no trailing slash)
--- @return string|nil relative path, or nil if filepath is not under root
function M.make_relative(filepath, root)
	if filepath:sub(1, #root) == root then
		return filepath:sub(#root + 2)
	end
	return nil
end

--- Convert an absolute file path to a repo-relative path.
--- @param filepath string absolute file path
--- @return string|nil relative path
function M.to_repo_relative(filepath)
	local root = M.get_repo_root()
	if not root then
		return nil
	end
	filepath = vim.fn.fnamemodify(filepath, ":p")
	return M.make_relative(filepath, root)
end

--- Get file content from a specific git ref.
--- @param ref string branch name or commit SHA
--- @param file_path string repo-relative file path
--- @return string|nil content, string|nil err
function M.get_base_content(ref, file_path)
	-- Try the ref directly first, then origin/<ref> as fallback
	local result = vim.system({ "git", "show", ref .. ":" .. file_path }, { text = true }):wait()
	if result.code == 0 then
		return result.stdout, nil
	end

	local result2 = vim.system({ "git", "show", "origin/" .. ref .. ":" .. file_path }, { text = true }):wait()
	if result2.code == 0 then
		return result2.stdout, nil
	end

	return nil, result.stderr or "File not found in " .. ref
end

--- Get the unified diff for a specific file between base and HEAD.
--- @param base_ref string base branch name
--- @param file_path string repo-relative file path
--- @return string|nil diff text
function M.get_file_diff(base_ref, file_path)
	local result = vim.system({ "git", "diff", base_ref .. "...HEAD", "--", file_path }, { text = true }):wait()
	if result.code == 0 then
		return result.stdout
	end

	local result2 = vim
		.system({ "git", "diff", "origin/" .. base_ref .. "...HEAD", "--", file_path }, { text = true })
		:wait()
	if result2.code == 0 then
		return result2.stdout
	end

	return nil
end

return M
