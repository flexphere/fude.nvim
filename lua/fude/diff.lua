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
--- @param filepath string|nil absolute file path
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
	local rel = M.make_relative(filepath, root)
	if not rel or rel == "" then
		return nil
	end
	return rel
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
--- @param ref string|nil branch name or commit SHA
--- @return string|nil merge-base SHA
function M.get_merge_base(ref)
	if not ref then
		return nil
	end
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

	-- Fallback: check common default branch names on the remote
	for _, name in ipairs({ "main", "master" }) do
		local check = vim.system({ "git", "rev-parse", "--verify", "origin/" .. name }, { text = true }):wait()
		if check.code == 0 then
			return name
		end
	end

	-- Fallback: local main/master (remote-less repos, e.g. pre-push agent work)
	for _, name in ipairs({ "main", "master" }) do
		local check = vim.system({ "git", "rev-parse", "--verify", name }, { text = true }):wait()
		if check.code == 0 then
			return name
		end
	end

	return nil
end

--- Parse `git for-each-ref --format=%(refname:strip=3) refs/remotes/origin/` output
--- into branch names, preserving order. Skips blank lines and the symbolic `HEAD`
--- ref (origin/HEAD is a pointer to the default branch, not a branch itself).
--- @param output string|nil for-each-ref output
--- @return string[] branch names (e.g. { "main", "feat/foo" })
function M.parse_remote_branches(output)
	local branches = {}
	if not output or output == "" then
		return branches
	end
	for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
		local name = vim.trim(line)
		if name ~= "" and name ~= "HEAD" then
			table.insert(branches, name)
		end
	end
	return branches
end

--- Get the branch names on the `origin` remote, most recently committed first.
--- Uses the local remote-tracking refs (no network), so the list is as fresh as
--- the last `git fetch`.
--- @return string[] branch names without the `origin/` prefix (empty when there is no remote)
function M.get_remote_branches()
	local result = vim
		.system({
			"git",
			"for-each-ref",
			"--sort=-committerdate",
			"--format=%(refname:strip=3)",
			"refs/remotes/origin/",
		}, { text = true })
		:wait()
	if result.code ~= 0 then
		return {}
	end
	return M.parse_remote_branches(result.stdout)
end

--- Find the parent of `branch` in gh-stack's local metadata (`.git/gh-stack`).
--- Stacks list their branches bottom → top, so the parent is the previous
--- branch, or the stack's trunk for the bottom branch. The file format is
--- gh-stack's internal state, so every field is type-checked and anything
--- unexpected yields nil rather than an error.
--- @param text string|nil contents of `.git/gh-stack`
--- @param branch string|nil current branch name
--- @return string|nil parent branch name
function M.parse_gh_stack_parent(text, branch)
	if not text or text == "" or not branch then
		return nil
	end
	local ok, data = pcall(vim.json.decode, text)
	if not ok or type(data) ~= "table" or type(data.stacks) ~= "table" then
		return nil
	end
	for _, stack in ipairs(data.stacks) do
		if type(stack) == "table" and type(stack.branches) == "table" then
			for i, b in ipairs(stack.branches) do
				if type(b) == "table" and b.branch == branch then
					if i > 1 then
						local prev = stack.branches[i - 1]
						return type(prev) == "table" and type(prev.branch) == "string" and prev.branch or nil
					end
					local trunk = stack.trunk
					return type(trunk) == "table" and type(trunk.branch) == "string" and trunk.branch or nil
				end
			end
		end
	end
	return nil
end

--- Get the parent branch of `branch` recorded by the gh-stack extension.
--- Reads `.git/gh-stack` from the common git dir (shared by worktrees) directly,
--- which avoids `gh stack view` (it refreshes PR state over the network).
--- @param branch string|nil current branch name
--- @return string|nil parent branch name (nil when not in a stack or gh-stack is unused)
function M.get_gh_stack_parent(branch)
	if not branch then
		return nil
	end
	local result = vim
		.system({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true })
		:wait()
	if result.code ~= 0 or not result.stdout then
		return nil
	end
	local path = vim.trim(result.stdout) .. "/gh-stack"
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	return M.parse_gh_stack_parent(table.concat(lines, "\n"), branch)
end

--- Parse `<count> <branch>` lines into entries sorted by distance (nearest first),
--- ties broken by name for a stable order.
--- @param lines string[] lines of "<count> <branch>"
--- @return string[] branch names
function M.sort_branches_by_distance(lines)
	local items = {}
	for _, line in ipairs(lines or {}) do
		local count, name = line:match("^(%d+)%s+(%S+)$")
		if count then
			table.insert(items, { name = name, distance = tonumber(count) })
		end
	end
	table.sort(items, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.name < b.name
	end)
	local names = {}
	for _, item in ipairs(items) do
		table.insert(names, item.name)
	end
	return names
end

--- Get the `origin` branches that HEAD was built on top of: their tips are
--- ancestors of HEAD but not of the default branch, i.e. the branches between
--- the default branch and HEAD in `git log` (e.g. the lower layers of a stack).
--- Sorted nearest first (fewest commits from the branch tip to HEAD).
--- Returns an empty list when the default branch ref cannot be resolved: without
--- `--no-merged <default>` every branch ever merged into it would match.
--- @param default_branch string|nil repository default branch
--- @return string[] branch names without the `origin/` prefix
function M.get_ancestor_branches(default_branch)
	if not default_branch or default_branch == "" then
		return {}
	end
	local default_ref
	for _, ref in ipairs({ "origin/" .. default_branch, default_branch }) do
		if vim.system({ "git", "rev-parse", "--verify", "--quiet", ref }, { text = true }):wait().code == 0 then
			default_ref = ref
			break
		end
	end
	if not default_ref then
		return {}
	end
	local result = vim
		.system({
			"git",
			"for-each-ref",
			"--merged=HEAD",
			"--no-merged=" .. default_ref,
			"--format=%(refname:strip=3)",
			"refs/remotes/origin/",
		}, { text = true })
		:wait()
	if result.code ~= 0 then
		return {}
	end
	local lines = {}
	for _, name in ipairs(M.parse_remote_branches(result.stdout)) do
		local count = vim.system({ "git", "rev-list", "--count", "origin/" .. name .. "..HEAD" }, { text = true }):wait()
		if count.code == 0 then
			table.insert(lines, vim.trim(count.stdout) .. " " .. name)
		end
	end
	return M.sort_branches_by_distance(lines)
end

--- Get the current branch name (nil when detached HEAD).
--- @return string|nil branch name
function M.get_current_branch()
	local result = vim.system({ "git", "symbolic-ref", "--quiet", "--short", "HEAD" }, { text = true }):wait()
	if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the HEAD commit SHA (synchronous, local git operation).
--- @return string|nil sha
function M.get_head_sha()
	local result = vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the repository's empty-tree object hash. Used as a diff base for
--- zero-commit repos (no HEAD), where diffing against the empty tree shows
--- every tracked/staged file as added. Computed via `git hash-object` so it
--- is correct for both SHA-1 and SHA-256 repositories.
--- @return string|nil hash
function M.get_empty_tree()
	local result = vim.system({ "git", "hash-object", "-t", "tree", "/dev/null" }, { text = true }):wait()
	if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the upstream tracking ref of the current branch (e.g. "origin/feat/a"),
--- used as the diff base for the "unpushed" local review scope. Returns nil
--- when the branch has no upstream (never pushed / no tracking configured).
--- @param cwd string|nil repo root
--- @return string|nil upstream ref
function M.get_upstream_ref(cwd)
	local result = vim
		.system({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, { text = true, cwd = cwd })
		:wait()
	if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the configured git user name (fallback: $USER).
--- @return string user name
function M.get_git_user()
	local result = vim.system({ "git", "config", "user.name" }, { text = true }):wait()
	if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
		return vim.trim(result.stdout)
	end
	return os.getenv("USER") or "local"
end

--- Get name-status diff output between a ref and the working tree.
--- @param ref string base commit SHA or ref
--- @param cwd string|nil repo root (so output is correct when nvim's cwd is a subdir)
--- @return string|nil output
function M.get_name_status(ref, cwd)
	local result = vim.system({ "git", "diff", "--name-status", "-M", ref }, { text = true, cwd = cwd }):wait()
	if result.code == 0 then
		return result.stdout
	end
	return nil
end

--- Get numstat diff output between a ref and the working tree.
--- @param ref string base commit SHA or ref
--- @param cwd string|nil repo root
--- @return string|nil output
function M.get_numstat(ref, cwd)
	local result = vim.system({ "git", "diff", "--numstat", "-M", ref }, { text = true, cwd = cwd }):wait()
	if result.code == 0 then
		return result.stdout
	end
	return nil
end

--- Get untracked (non-ignored) files in the working tree.
--- Runs in `cwd` (repo root) so it lists every untracked file with repo-relative
--- paths — `git ls-files --others` is cwd-relative and limited to the cwd
--- subtree otherwise.
--- @param cwd string|nil repo root
--- @return string|nil output newline-separated paths
function M.get_untracked(cwd)
	local result = vim.system({ "git", "ls-files", "--others", "--exclude-standard" }, { text = true, cwd = cwd }):wait()
	if result.code == 0 then
		return result.stdout
	end
	return nil
end

--- Get the working-tree diff for a single file against a base SHA, used for the
--- local review file-list preview. Tries `git diff <base> -- <path>` (tracked
--- changes) first, then falls back to `git diff --no-index` (untracked/new
--- files, which don't appear in a normal diff). Returns nil when there is no
--- diff to show. Runs in `cwd` (repo root) so the repo-relative pathspec
--- resolves even when nvim's cwd is a subdirectory.
--- @param base_sha string base commit SHA
--- @param path string repo-relative file path
--- @param cwd string|nil repo root
--- @return string|nil patch text
function M.get_review_patch(base_sha, path, cwd)
	local result = vim.system({ "git", "diff", base_sha, "--", path }, { text = true, cwd = cwd }):wait()
	if result.code == 0 and result.stdout and result.stdout ~= "" then
		return result.stdout
	end
	-- Untracked/new file: diff against /dev/null (exits 1 when they differ).
	local untracked = vim
		.system({ "git", "diff", "--no-index", "--", "/dev/null", path }, { text = true, cwd = cwd })
		:wait()
	if untracked.stdout and untracked.stdout ~= "" then
		return untracked.stdout
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
