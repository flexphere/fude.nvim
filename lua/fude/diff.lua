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
	if not filepath or filepath == "" then
		return nil
	end
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

--- Maximum length for PR title default value.
local MAX_TITLE_LENGTH = 100

--- Parse the first line (subject) from git log output.
--- @param output string|nil git log output
--- @return string|nil subject first commit subject, or nil if empty
function M.parse_log_first_subject(output)
	if not output or output == "" then
		return nil
	end
	local first_line = output:match("^([^\r\n]*)")
	if not first_line then
		return nil
	end
	local subject = vim.trim(first_line)
	if subject == "" then
		return nil
	end
	-- Truncate if exceeds max length
	if #subject > MAX_TITLE_LENGTH then
		return subject:sub(1, MAX_TITLE_LENGTH)
	end
	return subject
end

--- Get the merge-base between a ref and HEAD.
--- @param ref string branch name or commit SHA
--- @return string|nil merge-base SHA
function M.get_merge_base(ref)
	local result = vim.system({ "git", "merge-base", ref, "HEAD" }, { text = true }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout)
	end
	-- Fallback to origin/<ref>
	local result2 = vim.system({ "git", "merge-base", "origin/" .. ref, "HEAD" }, { text = true }):wait()
	if result2.code == 0 then
		return vim.trim(result2.stdout)
	end
	return nil
end

--- Get the repository's default branch name.
--- @return string|nil branch name (e.g., "main", "master")
function M.get_default_branch()
	-- Try to get default branch from remote HEAD
	local result = vim.system({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { text = true }):wait()
	if result.code == 0 and result.stdout then
		local branch = vim.trim(result.stdout)
		if branch == "" then
			return nil
		end
		-- Strip "origin/" prefix if present
		return (branch:gsub("^origin/", ""))
	end

	-- Fallback: check common default branch names
	for _, name in ipairs({ "main", "master" }) do
		local check = vim.system({ "git", "rev-parse", "--verify", "origin/" .. name }, { text = true }):wait()
		if check.code == 0 then
			return name
		end
	end

	return nil
end

--- Get the subject of the first commit since base branch.
--- @param base_ref string base branch name (e.g., "main")
--- @return string|nil subject first commit message subject
function M.get_first_commit_subject(base_ref)
	-- Get first commit (oldest) since diverging from base
	-- Note: --reverse without -1, then parse_log_first_subject takes the first line
	local result = vim
		.system({
			"git",
			"log",
			base_ref .. "..HEAD",
			"--reverse",
			"--format=%s",
		}, { text = true })
		:wait()

	if result.code == 0 and result.stdout then
		return M.parse_log_first_subject(result.stdout)
	end

	-- Try with origin/ prefix
	local result2 = vim
		.system({
			"git",
			"log",
			"origin/" .. base_ref .. "..HEAD",
			"--reverse",
			"--format=%s",
		}, { text = true })
		:wait()

	if result2.code == 0 and result2.stdout then
		return M.parse_log_first_subject(result2.stdout)
	end

	return nil
end

return M
