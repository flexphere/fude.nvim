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
	-- Boundary-aware: `/repo-other/x.lua` is not inside `/repo`, so a plain
	-- prefix test would hand a sibling repository's file back as `other/x.lua`.
	root = root:gsub("/+$", "")
	if root == "" then
		-- Filesystem root: everything absolute is inside it
		return (filepath:gsub("^/+", ""))
	end
	if filepath == root then
		return ""
	end
	if filepath:sub(1, #root + 1) == root .. "/" then
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

--- Field separator used by `get_commit_log` (git's %x1f). A control character
--- keeps the parser safe against commit subjects containing tabs or pipes.
local COMMIT_LOG_SEP = "\31"

--- Parse `git log --format=%H%x1f%h%x1f%s` output.
--- @param output string|nil git log output
--- @return table[] commits { sha, short_sha, subject }
function M.parse_commit_log(output)
	local commits = {}
	if not output or output == "" then
		return commits
	end
	for line in output:gmatch("[^\r\n]+") do
		local sha, short_sha, subject = line:match(
			"^([^"
				.. COMMIT_LOG_SEP
				.. "]+)"
				.. COMMIT_LOG_SEP
				.. "([^"
				.. COMMIT_LOG_SEP
				.. "]+)"
				.. COMMIT_LOG_SEP
				.. "(.*)$"
		)
		if sha then
			table.insert(commits, { sha = sha, short_sha = short_sha, subject = subject })
		end
	end
	return commits
end

--- List the commits reachable from `tip` but not from `base_ref`, oldest first.
--- `tip` is taken explicitly (rather than HEAD) so the list stays stable while
--- the local review's commit scope has a commit checked out. A `base_ref` that
--- only exists on the remote (the usual clone: `origin/main` without a local
--- `main`) is retried as `origin/<base_ref>`, like `get_merge_base`. With no
--- `base_ref` every commit reachable from `tip` is listed (root commit first);
--- `limit` then keeps only the newest N (git applies `-n` before `--reverse`).
--- @param base_ref string|nil base commit SHA or ref
--- @param tip string|nil tip ref (default: "HEAD")
--- @param cwd string|nil repo root
--- @param limit number|nil keep only the newest `limit` commits of the range
--- @return table[] commits { sha, short_sha, subject }
function M.get_commit_log(base_ref, tip, cwd, limit)
	tip = tip or "HEAD"
	local function run(range)
		local cmd = { "git", "log", range, "--reverse", "--format=%H%x1f%h%x1f%s" }
		if limit then
			table.insert(cmd, "-n")
			table.insert(cmd, tostring(limit))
		end
		return vim.system(cmd, { text = true, cwd = cwd }):wait()
	end
	local result = run(base_ref and (base_ref .. ".." .. tip) or tip)
	if result.code ~= 0 and base_ref then
		result = run("origin/" .. base_ref .. ".." .. tip)
	end
	if result.code ~= 0 then
		return {}
	end
	return M.parse_commit_log(result.stdout)
end

--- Whether the working tree has staged or unstaged changes.
--- Untracked files do not count: `git checkout` carries them across, so they
--- never block a commit checkout.
--- @param cwd string|nil repo root
--- @return boolean dirty
function M.is_worktree_dirty(cwd)
	local result = vim.system({ "git", "status", "--porcelain", "-uno" }, { text = true, cwd = cwd }):wait()
	if result.code ~= 0 then
		-- Unknown state: treat as dirty so we never checkout over real work.
		return true
	end
	return vim.trim(result.stdout or "") ~= ""
end

--- Checkout a ref in the working tree (synchronous).
--- @param ref string branch name or commit SHA
--- @param cwd string|nil repo root
--- @return boolean ok, string|nil err
function M.checkout(ref, cwd)
	local result = vim.system({ "git", "checkout", ref }, { text = true, cwd = cwd }):wait()
	if result.code ~= 0 then
		return false, vim.trim(result.stderr or "")
	end
	return true, nil
end

--- Parse the parent SHAs out of a raw commit object (`git cat-file -p`).
--- @param object string|nil raw commit object text
--- @return string[] parents in header order
function M.parse_commit_parents(object)
	local parents = {}
	if type(object) ~= "string" then
		return parents
	end
	-- Headers end at the first blank line; only `parent` lines there count.
	local header = object:match("^(.-)\n\n") or object
	for sha in header:gmatch("\nparent (%x+)") do
		table.insert(parents, sha)
	end
	for sha in header:gmatch("^parent (%x+)") do
		table.insert(parents, 1, sha)
	end
	return parents
end

--- The first parent of a commit, distinguishing a true root commit from a
--- parent that is recorded but unreachable. `rev-parse <sha>^` fails in both
--- cases — a shallow clone's boundary commit still names its parent in the
--- object header, the object just is not there — so read the header itself
--- and then check the object exists.
--- @param sha string commit SHA
--- @param cwd string|nil repo root
--- @return string|nil parent first parent SHA, nil for root/missing/error
--- @return "parent"|"root"|"missing"|"error" status
function M.get_parent(sha, cwd)
	local object = vim.system({ "git", "cat-file", "-p", sha }, { text = true, cwd = cwd }):wait()
	if object.code ~= 0 then
		return nil, "error"
	end
	local parents = M.parse_commit_parents(object.stdout)
	if #parents == 0 then
		return nil, "root"
	end
	local exists = vim.system({ "git", "cat-file", "-e", parents[1] .. "^{commit}" }, { text = true, cwd = cwd }):wait()
	if exists.code ~= 0 then
		return nil, "missing"
	end
	return parents[1], "parent"
end

--- Get the merge-base between a ref and HEAD.
--- @param ref string|nil branch name or commit SHA
--- @param cwd string|nil repo root (default: Neovim's cwd; the local review
--- passes its worktree root so a `:cd` elsewhere does not break scope switches)
--- @return string|nil merge-base SHA
function M.get_merge_base(ref, cwd)
	if not ref then
		return nil
	end
	local result = vim.system({ "git", "merge-base", ref, "HEAD" }, { text = true, cwd = cwd }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout)
	end
	-- Fallback to origin/<ref>
	local result2 = vim.system({ "git", "merge-base", "origin/" .. ref, "HEAD" }, { text = true, cwd = cwd }):wait()
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

--- Parse `git log --format=%H%x00%P%x00%D --decorate-refs=refs/remotes/origin/ <default>..HEAD`
--- output into branch names, nearest to HEAD first.
--- The distance of a branch is the number of commits in the range that its tip
--- cannot reach, i.e. `git rev-list --count <tip>..HEAD` limited to the range.
--- It is computed from the parent links in the output, since log order alone
--- (even `--topo-order`) does not follow the distance once a merge is involved.
--- Branches at the same distance are sorted by name for a stable order.
--- Symbolic entries (`origin/HEAD -> origin/main`) and duplicates are skipped.
--- @param output string|nil git log output (one commit per line: hash NUL parents NUL decorations)
--- @return string[] branch names without the `origin/` prefix
function M.parse_ancestor_log(output)
	local names = {}
	if not output or output == "" then
		return names
	end
	local total = 0
	local parents = {}
	local tips = {} -- { sha, name }
	for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
		local fields = vim.split(line, "\0", { plain = true })
		local sha = vim.trim(fields[1] or "")
		if sha ~= "" then
			total = total + 1
			parents[sha] = vim.split(vim.trim(fields[2] or ""), " ", { trimempty = true })
			for _, ref in ipairs(vim.split(fields[3] or "", ",", { plain = true })) do
				ref = vim.trim(ref)
				local name = ref:match("^origin/(.+)$")
				if name and not ref:find("->", 1, true) and name ~= "HEAD" then
					table.insert(tips, { sha = sha, name = name })
				end
			end
		end
	end

	-- commits in the range reachable from `sha` (itself included); parents
	-- outside the range are absent from `parents` and not followed
	local function count_reachable(sha)
		local seen = { [sha] = true }
		local stack = { sha }
		local count = 0
		while #stack > 0 do
			local current = table.remove(stack)
			count = count + 1
			for _, parent in ipairs(parents[current]) do
				if parents[parent] and not seen[parent] then
					seen[parent] = true
					table.insert(stack, parent)
				end
			end
		end
		return count
	end

	local distance = {}
	local by_sha = {}
	local ordered = {}
	for _, tip in ipairs(tips) do
		if not distance[tip.name] then
			by_sha[tip.sha] = by_sha[tip.sha] or (total - count_reachable(tip.sha))
			distance[tip.name] = by_sha[tip.sha]
			table.insert(ordered, tip.name)
		end
	end
	table.sort(ordered, function(a, b)
		if distance[a] ~= distance[b] then
			return distance[a] < distance[b]
		end
		return a < b
	end)
	return ordered
end

--- Get the `origin` branches that HEAD was built on top of: branch tips in
--- `<default>..HEAD`, i.e. between the default branch and HEAD in `git log`
--- (e.g. the lower layers of a stack), nearest first.
--- One `git log` walk yields both membership and the commit graph the distances
--- are computed from, so the number of git processes does not grow with the
--- number of candidate branches. The range excludes
--- branches already merged into the default branch.
--- Returns an empty list when the default branch ref cannot be resolved: without
--- the range bound every branch in HEAD's history would match.
--- May include the current branch's own remote ref; callers filter it out.
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
			"log",
			"--format=%H%x00%P%x00%D",
			"--decorate-refs=refs/remotes/origin/",
			"--decorate-refs-exclude=refs/remotes/origin/HEAD",
			default_ref .. "..HEAD",
		}, { text = true })
		:wait()
	if result.code ~= 0 then
		return {}
	end
	return M.parse_ancestor_log(result.stdout)
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
--- @param cwd string|nil repo root (default: Neovim's cwd)
--- @return string|nil sha
function M.get_head_sha(cwd)
	local result = vim.system({ "git", "rev-parse", "HEAD" }, { text = true, cwd = cwd }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the repository's empty-tree object hash. Used as a diff base for
--- zero-commit repos (no HEAD), where diffing against the empty tree shows
--- every tracked/staged file as added. Computed via `git hash-object` so it
--- is correct for both SHA-1 and SHA-256 repositories.
--- @param cwd string|nil repo root (default: Neovim's cwd)
--- @return string|nil hash
function M.get_empty_tree(cwd)
	-- `cwd` matters: the hash depends on the repository's object format
	-- (SHA-1 vs SHA-256), so it must be computed inside the reviewed worktree,
	-- not wherever Neovim's cwd happens to be.
	local result = vim.system({ "git", "hash-object", "-t", "tree", "/dev/null" }, { text = true, cwd = cwd }):wait()
	if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= "" then
		return vim.trim(result.stdout)
	end
	return nil
end

--- Get the upstream tracking ref of the current branch (e.g. "origin/feat/a"),
--- used as the diff base for the "unpushed" local review scope. Returns nil
--- when the branch has no upstream (never pushed / no tracking configured).
--- `branch` names another branch instead of HEAD — needed while the local
--- commit scope holds HEAD detached, where a bare `@{upstream}` resolves to
--- nothing.
--- @param cwd string|nil repo root
--- @param branch string|nil branch whose upstream to resolve (default: HEAD)
--- @return string|nil upstream ref
function M.get_upstream_ref(cwd, branch)
	local result = vim
		.system(
			{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", (branch or "") .. "@{upstream}" },
			{ text = true, cwd = cwd }
		)
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
--- `origin/<base>` is tried before the local ref: the PR targets the branch on
--- GitHub, and a stale local branch of the same name would give a title based
--- on a different commit range. The local ref is the fallback for repos
--- without a remote.
--- @param base_ref string base branch name (e.g., "main")
--- @return string|nil subject first commit message subject
function M.get_first_commit_subject(base_ref)
	for _, ref in ipairs({ "origin/" .. base_ref, base_ref }) do
		-- --reverse without -1, then parse_log_first_subject takes the first line
		local result = vim.system({ "git", "log", ref .. "..HEAD", "--reverse", "--format=%s" }, { text = true }):wait()
		if result.code == 0 and result.stdout then
			return M.parse_log_first_subject(result.stdout)
		end
	end
	return nil
end

--- Parse `git worktree list --porcelain` output.
--- Bare and detached worktrees are skipped: neither holds a branch. Prunable
--- ones (directory gone) are kept, since git still reserves their branch
--- until `git worktree prune`.
--- @param output string|nil
--- @return table[] { path: string, branch: string }[] (branch without `refs/heads/`)
function M.parse_worktree_list(output)
	local worktrees = {}
	local current
	local function flush()
		if current and current.branch and not current.skip then
			table.insert(worktrees, { path = current.path, branch = current.branch })
		end
		current = nil
	end
	for line in ((output or "") .. "\n"):gmatch("(.-)\n") do
		local path = line:match("^worktree (.+)$")
		if path then
			flush()
			current = { path = path }
		elseif current then
			local branch = line:match("^branch refs/heads/(.+)$")
			if branch then
				current.branch = branch
			elseif line == "bare" or line == "detached" then
				current.skip = true
			end
		end
	end
	flush()
	return worktrees
end

--- List the worktrees of the current repository that have a branch checked out.
--- @return table[]|nil worktrees see `parse_worktree_list`, nil when git fails
--- @return string|nil err
function M.get_worktrees()
	local result = vim.system({ "git", "worktree", "list", "--porcelain" }, { text = true }):wait()
	if result.code ~= 0 then
		return nil, result.stderr or "git worktree list failed"
	end
	return M.parse_worktree_list(result.stdout), nil
end

--- Parse `git worktree list --porcelain` output into every checkout directory,
--- detached ones included; only bare entries (no working tree) are skipped.
--- For file *ownership* a detached worktree is as real as a branch one, which
--- is why this does not reuse `parse_worktree_list`.
--- @param output string|nil
--- @return string[] paths
function M.parse_worktree_roots(output)
	local roots = {}
	local current
	local function flush()
		if current and not current.bare then
			table.insert(roots, current.path)
		end
		current = nil
	end
	for line in ((output or "") .. "\n"):gmatch("(.-)\n") do
		local path = line:match("^worktree (.+)$")
		if path then
			flush()
			current = { path = path }
		elseif current and line == "bare" then
			current.bare = true
		end
	end
	flush()
	return roots
end

--- Every worktree directory of the repository that contains `cwd`, detached
--- ones included (see `parse_worktree_roots`). Takes the repo root explicitly
--- so the answer does not change when the user `:cd`s elsewhere mid-session.
--- @param cwd string|nil repo root
--- @return string[]|nil roots nil when git fails
--- @return string|nil err
function M.get_worktree_roots(cwd)
	local result = vim.system({ "git", "worktree", "list", "--porcelain" }, { text = true, cwd = cwd }):wait()
	if result.code ~= 0 then
		return nil, result.stderr or "git worktree list failed"
	end
	return M.parse_worktree_roots(result.stdout), nil
end

return M
