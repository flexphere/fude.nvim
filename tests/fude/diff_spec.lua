local diff = require("fude.diff")
-- Loaded up front: some specs below `:cd` into a temp repo, where the
-- relative package.path cannot find modules that were not required yet.
local config = require("fude.config")

describe("parse_log_first_subject", function()
	it("returns first line from single-line output", function()
		assert.are.equal("Add feature X", diff.parse_log_first_subject("Add feature X\n"))
	end)

	it("returns first line from multi-line output", function()
		assert.are.equal("First commit", diff.parse_log_first_subject("First commit\nSecond commit\n"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(diff.parse_log_first_subject(""))
	end)

	it("returns nil for nil input", function()
		assert.is_nil(diff.parse_log_first_subject(nil))
	end)

	it("returns nil for empty first line", function()
		assert.is_nil(diff.parse_log_first_subject("\nSecond line"))
	end)

	it("returns nil for whitespace-only first line", function()
		assert.is_nil(diff.parse_log_first_subject("   \nSecond line"))
	end)

	it("trims whitespace from subject", function()
		assert.are.equal("Trimmed subject", diff.parse_log_first_subject("  Trimmed subject  \n"))
	end)

	it("truncates subject exceeding 100 characters", function()
		local long_subject = string.rep("a", 150)
		local result = diff.parse_log_first_subject(long_subject)
		assert.are.equal(100, #result)
		assert.are.equal(string.rep("a", 100), result)
	end)

	it("does not truncate subject at exactly 100 characters", function()
		local exact_subject = string.rep("b", 100)
		assert.are.equal(exact_subject, diff.parse_log_first_subject(exact_subject))
	end)

	it("handles CRLF line endings", function()
		assert.are.equal("Windows commit", diff.parse_log_first_subject("Windows commit\r\nNext line"))
	end)

	it("handles output without trailing newline", function()
		assert.are.equal("No newline", diff.parse_log_first_subject("No newline"))
	end)
end)

describe("parse_remote_branches", function()
	it("returns branch names in order, skipping HEAD and blank lines", function()
		local out = "HEAD\nmain\n\nfeat/foo\nrelease/1.2\n"
		assert.are.same({ "main", "feat/foo", "release/1.2" }, diff.parse_remote_branches(out))
	end)

	it("returns an empty list for nil or empty output", function()
		assert.are.same({}, diff.parse_remote_branches(nil))
		assert.are.same({}, diff.parse_remote_branches(""))
	end)

	it("trims surrounding whitespace and CRLF", function()
		assert.are.same({ "main", "dev" }, diff.parse_remote_branches("  main \r\ndev\r\n"))
	end)
end)

describe("parse_gh_stack_parent", function()
	local stack_json = vim.json.encode({
		schemaVersion = 1,
		stacks = {
			{
				trunk = { branch = "main", head = "aaa" },
				branches = { { branch = "a", base = "aaa" }, { branch = "b", base = "bbb" } },
			},
		},
	})

	it("returns the previous branch in the stack", function()
		assert.are.equal("a", diff.parse_gh_stack_parent(stack_json, "b"))
	end)

	it("returns the trunk for the bottom branch", function()
		assert.are.equal("main", diff.parse_gh_stack_parent(stack_json, "a"))
	end)

	it("returns nil for a branch outside every stack", function()
		assert.is_nil(diff.parse_gh_stack_parent(stack_json, "other"))
	end)

	it("returns nil for missing, corrupt, or unexpected input", function()
		assert.is_nil(diff.parse_gh_stack_parent(nil, "b"))
		assert.is_nil(diff.parse_gh_stack_parent("", "b"))
		assert.is_nil(diff.parse_gh_stack_parent("{not json", "b"))
		assert.is_nil(diff.parse_gh_stack_parent('{"stacks": 1}', "b"))
		assert.is_nil(diff.parse_gh_stack_parent(stack_json, nil))
		assert.is_nil(diff.parse_gh_stack_parent('{"stacks":[{"branches":[{"branch":"a"}]}]}', "a"))
	end)
end)

describe("parse_ancestor_log", function()
	--- Build one `%H%x00%P%x00%D` line.
	local function line(sha, parents, refs)
		return sha .. "\0" .. parents .. "\0" .. (refs or "")
	end

	it("returns branches nearest to HEAD first on a linear history", function()
		-- h -> f -> b -> a (-> outside the range)
		local out = table.concat({
			line("h", "f", "origin/feature"),
			line("f", "b"),
			line("b", "a", "origin/b"),
			line("a", "root", "origin/a"),
		}, "\n") .. "\n"
		assert.are.same({ "feature", "b", "a" }, diff.parse_ancestor_log(out))
	end)

	it("orders by distance, not log order, across a merge", function()
		-- m merges the side chain s2 -> s1 into the first-parent chain m -> c3 -> c2 -> x.
		-- far (x) is listed first but cannot reach 5 commits (m c3 c2 s2 s1),
		-- while near (s2) cannot reach only 4 (m c3 c2 x)
		local out = table.concat({
			line("m", "c3 s2", ""),
			line("c3", "c2"),
			line("c2", "x"),
			line("x", "root", "origin/far"),
			line("s2", "s1", "origin/near"),
			line("s1", "root"),
		}, "\n")
		assert.are.same({ "near", "far" }, diff.parse_ancestor_log(out))
	end)

	it("sorts refs at the same distance by name and skips symbolic refs and duplicates", function()
		local out = table.concat({
			line("h", "p", "origin/z, origin/m"),
			line("p", "root", "origin/HEAD -> origin/main, origin/m"),
		}, "\n")
		assert.are.same({ "m", "z" }, diff.parse_ancestor_log(out))
	end)

	it("returns an empty list for nil or empty output", function()
		assert.are.same({}, diff.parse_ancestor_log(nil))
		assert.are.same({}, diff.parse_ancestor_log(""))
	end)
end)

describe("get_ancestor_branches / get_gh_stack_parent (real git repo)", function()
	local original_cwd
	local repo

	local function git(...)
		local res = vim.system({ "git", ... }, { cwd = repo, text = true }):wait()
		assert(res.code == 0, "git failed: " .. table.concat({ ... }, " ") .. " " .. (res.stderr or ""))
		return vim.trim(res.stdout or "")
	end

	before_each(function()
		original_cwd = vim.fn.getcwd()
		repo = vim.fn.tempname()
		vim.fn.mkdir(repo, "p")
		git("init", "-q", "-b", "main")
		-- repo-local identity: CI runners have no global git identity, and
		-- commit-tree (unlike commit) takes no -c shortcut in this helper
		git("config", "user.name", "t")
		git("config", "user.email", "t@t")
		git("commit", "-q", "--allow-empty", "-m", "root")
		git("update-ref", "refs/remotes/origin/main", "HEAD")
		git("update-ref", "refs/remotes/origin/old-merged", "HEAD")
		-- stack: main -> a -> b -> (HEAD) feature
		git("checkout", "-q", "-b", "feature")
		git("commit", "-q", "--allow-empty", "-m", "a1")
		-- nested name: `--decorate-refs=refs/remotes/origin/` must match it as a prefix
		git("update-ref", "refs/remotes/origin/feat/a", "HEAD")
		git("commit", "-q", "--allow-empty", "-m", "b1")
		git("update-ref", "refs/remotes/origin/b", "HEAD")
		git("commit", "-q", "--allow-empty", "-m", "f1")
		-- unrelated branch forked from main
		git(
			"update-ref",
			"refs/remotes/origin/unrelated",
			git("commit-tree", "-p", "main", "-m", "u", git("rev-parse", "HEAD^{tree}"))
		)
		vim.cmd.cd(repo)
	end)

	after_each(function()
		vim.cmd.cd(original_cwd)
		vim.fn.delete(repo, "rf")
	end)

	it("lists branches between the default branch and HEAD, nearest first", function()
		assert.are.same({ "b", "feat/a" }, diff.get_ancestor_branches("main"))
	end)

	it("lists the commits of base..tip oldest first", function()
		local commits = diff.get_commit_log("main", "feature", repo)
		assert.equals(3, #commits)
		assert.equals("a1", commits[1].subject)
		assert.equals("b1", commits[2].subject)
		assert.equals("f1", commits[3].subject)
		assert.equals(git("rev-parse", "feature"), commits[3].sha)
	end)

	it("falls back to origin/<base> when the base exists only on the remote", function()
		-- The usual clone: origin/main is there, a local main is not
		git("branch", "-D", "main")
		local commits = diff.get_commit_log("main", "feature", repo)
		assert.equals(3, #commits)
		assert.equals("a1", commits[1].subject)
	end)

	it("lists every commit of the tip when there is no base", function()
		local commits = diff.get_commit_log(nil, "feature", repo)
		assert.equals(4, #commits)
		assert.equals("root", commits[1].subject)
		assert.equals("f1", commits[4].subject)
	end)

	it("returns an empty list when the base resolves nowhere", function()
		assert.same({}, diff.get_commit_log("no-such-branch", "feature", repo))
	end)

	it("keeps only the newest commits when a limit is given, still oldest first", function()
		local commits = diff.get_commit_log(nil, "feature", repo, 2)
		assert.equals(2, #commits)
		assert.equals("b1", commits[1].subject)
		assert.equals("f1", commits[2].subject)
	end)

	it("get_parent returns the parent sha for an ordinary commit and root for the first", function()
		local parent, status = diff.get_parent(git("rev-parse", "feature"), repo)
		assert.equals("parent", status)
		assert.equals(git("rev-parse", "feature^"), parent)

		local root_parent, root_status = diff.get_parent(git("rev-parse", "main"), repo)
		assert.is_nil(root_parent)
		assert.equals("root", root_status)
	end)

	it("get_parent tells a shallow clone's boundary apart from a root commit", function()
		local shallow = vim.fn.tempname()
		local res = vim.system({ "git", "clone", "-q", "--depth", "1", "file://" .. repo, shallow }, { text = true }):wait()
		assert(res.code == 0, res.stderr)
		local head = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { cwd = shallow, text = true }):wait().stdout)

		-- `rev-parse HEAD^` fails here just like on a root commit, but the
		-- object header still names the parent — the object is just not there.
		local parent, status = diff.get_parent(head, shallow)
		assert.is_nil(parent)
		assert.equals("missing", status)
		vim.fn.delete(shallow, "rf")
	end)

	it("get_worktree_roots lists detached worktrees too and takes the repo root as cwd", function()
		local detached = vim.fn.tempname()
		git("worktree", "add", "-q", "--detach", detached, "main")
		-- Asked from an unrelated cwd: the explicit root decides the repository
		local roots = diff.get_worktree_roots(repo)
		assert.is_not_nil(roots)
		local resolved = vim.tbl_map(vim.fn.resolve, roots)
		assert.truthy(vim.tbl_contains(resolved, vim.fn.resolve(repo)))
		assert.truthy(vim.tbl_contains(resolved, vim.fn.resolve(detached)))
		-- get_worktrees (branch worktrees only) leaves the detached one out
		local branch_paths = vim.tbl_map(function(wt)
			return vim.fn.resolve(wt.path)
		end, diff.get_worktrees())
		assert.is_false(vim.tbl_contains(branch_paths, vim.fn.resolve(detached)))
		git("worktree", "remove", "--force", detached)
	end)

	it("get_merge_base runs in the given worktree regardless of the cwd", function()
		vim.cmd.cd(original_cwd) -- fude.nvim's own repo: a different history
		assert.equals(git("rev-parse", "main"), diff.get_merge_base("main", repo))
		vim.cmd.cd(repo)
	end)

	it("get_empty_tree runs in the given worktree", function()
		local sha1_empty = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
		assert.equals(sha1_empty, diff.get_empty_tree(repo))
	end)

	it("checkout counts a completed checkout whose post-checkout hook failed as done", function()
		local hook = repo .. "/.git/hooks/post-checkout"
		vim.fn.writefile({ "#!/bin/sh", "echo hook says no >&2", "exit 1" }, hook)
		vim.uv.fs_chmod(hook, 493) -- 0755
		local target = git("rev-parse", "main")

		local ok, err = diff.checkout(target, repo)
		assert.is_true(ok)
		assert.truthy(err and err:find("hook failed", 1, true))
		assert.truthy(err and err:find("hook says no", 1, true))
		assert.equals(target, git("rev-parse", "HEAD"))

		-- Back onto the branch by name: symbolic HEAD must match, not just the sha
		local ok2, err2 = diff.checkout("feature", repo)
		assert.is_true(ok2)
		assert.truthy(err2 and err2:find("hook failed", 1, true))
		assert.equals("feature", git("symbolic-ref", "--short", "HEAD"))

		-- A checkout that truly did nothing stays a failure
		vim.fn.delete(hook)
		local ok3, err3 = diff.checkout("no-such-ref", repo)
		assert.is_false(ok3)
		assert.truthy(err3 and #err3 > 0)
	end)

	it("checkout with branch=true refuses to call a detached checkout onto a same-named tag a restore", function()
		-- The branch is gone, a tag of the same name points at its old tip
		local tip = git("rev-parse", "feature")
		git("checkout", "-q", "--detach")
		git("branch", "-D", "feature")
		git("tag", "feature", tip)

		-- git itself is happy: exit 0, HEAD detached on the tag
		local ok, err = diff.checkout("feature", repo, { branch = true })
		assert.is_false(ok)
		assert.truthy(err and err:find("left HEAD detached at", 1, true))
		assert.truthy(err and err:find("tag or remote ref", 1, true))
		assert.is_nil(diff.head_branch(repo))

		-- Without the branch requirement the same checkout is a legitimate
		-- detached checkout of that commit
		assert.is_true(diff.checkout("feature", repo))
		assert.equals(tip, git("rev-parse", "HEAD"))

		-- A real branch lands symbolically
		assert.is_true(diff.checkout("main", repo, { branch = true }))
		assert.equals("main", diff.head_branch(repo))
	end)

	it("checkout with detach=true lands detached even when the target is the branch tip", function()
		local tip = git("rev-parse", "feature") -- HEAD is on feature, at this very commit
		assert.equals("feature", diff.head_branch(repo))
		assert.is_true(diff.checkout(tip, repo, { detach = true }))
		assert.is_nil(diff.head_branch(repo))
		assert.equals(tip, git("rev-parse", "HEAD"))
	end)

	it("get_repo_root answers the local session's worktree root regardless of the cwd", function()
		config.state.review_mode = "local"
		config.state.local_session = { worktree_root = "/wt/elsewhere" }
		assert.equals("/wt/elsewhere", diff.get_repo_root())
		config.state.review_mode = nil
		config.state.local_session = nil
		assert.equals(vim.fn.resolve(repo), vim.fn.resolve(diff.get_repo_root()))
	end)

	it("get_untracked_conflicts lists what a checkout would overwrite, ignored files included", function()
		-- feature tracks shared.txt and .env; main tracks neither
		vim.fn.writefile({ "x" }, repo .. "/shared.txt")
		vim.fn.writefile({ "SECRET=1" }, repo .. "/.env")
		git("add", "shared.txt", ".env")
		git("commit", "-q", "-m", "track shared and .env")
		git("checkout", "-q", "--detach", "main")
		-- Now untracked: one the target tracks, one nothing tracks, one ignored
		-- that the target tracks (git would overwrite it silently by default)
		vim.fn.writefile({ "y" }, repo .. "/shared.txt")
		vim.fn.writefile({ "z" }, repo .. "/scratch.txt")
		vim.fn.writefile({ ".env", "scratch-ignored.txt" }, repo .. "/.gitignore")
		vim.fn.writefile({ "SECRET=local" }, repo .. "/.env")
		vim.fn.writefile({ "w" }, repo .. "/scratch-ignored.txt")

		assert.same({ ".env", "shared.txt" }, diff.get_untracked_conflicts("feature", repo))
		assert.same({}, diff.get_untracked_conflicts("main", repo))
		local nothing, err = diff.get_untracked_conflicts("no-such-ref", repo)
		assert.is_nil(nothing)
		assert.truthy(err and #err > 0)

		-- and git itself refuses to overwrite the ignored file through our checkout
		local ok, cerr = diff.checkout("feature", repo, { branch = true })
		assert.is_false(ok)
		assert.truthy(cerr and cerr:find("would be overwritten", 1, true))
		assert.same({ "SECRET=local" }, vim.fn.readfile(repo .. "/.env"))
	end)

	it("head_is distinguishes a branch from a detached HEAD on its commit", function()
		assert.is_true(diff.head_is("feature", repo))
		assert.is_true(diff.head_is(git("rev-parse", "feature"), repo))
		assert.is_false(diff.head_is("main", repo))
		git("checkout", "-q", "--detach")
		-- same commit, but no longer "on the branch"
		assert.is_false(diff.head_is("feature", repo))
		assert.is_true(diff.head_is(git("rev-parse", "HEAD"), repo))
	end)

	it("is_reachable_from_branch tells a saved commit from an orphan on a detached HEAD", function()
		assert.is_true(diff.is_reachable_from_branch(git("rev-parse", "feature"), repo))
		git("checkout", "-q", "--detach")
		git("commit", "-q", "--allow-empty", "-m", "made while detached")
		local orphan = git("rev-parse", "HEAD")
		assert.is_false(diff.is_reachable_from_branch(orphan, repo))
		-- `git branch <name>` keeps HEAD detached but saves the commit
		git("branch", "saved", orphan)
		assert.is_true(diff.is_reachable_from_branch(orphan, repo))
	end)

	it("get_parent reports an error for an unknown object", function()
		local parent, status = diff.get_parent("0000000000000000000000000000000000000000", repo)
		assert.is_nil(parent)
		assert.equals("error", status)
	end)

	it("resolves another branch's upstream while HEAD is detached", function()
		-- feature tracks main through a local "remote" so @{upstream} resolves
		git("config", "branch.feature.remote", ".")
		git("config", "branch.feature.merge", "refs/heads/main")
		assert.equals("main", diff.get_upstream_ref(repo))

		git("checkout", "-q", "--detach")
		assert.is_nil(diff.get_upstream_ref(repo))
		assert.equals("main", diff.get_upstream_ref(repo, "feature"))
	end)

	it("bases the first commit subject on origin/<base> over a stale local branch", function()
		-- local main stays at root while origin/main moves up to a1
		git("update-ref", "refs/remotes/origin/main", "refs/remotes/origin/feat/a")
		assert.are.equal("b1", diff.get_first_commit_subject("main"))
	end)

	it("falls back to the local branch when there is no origin/<base>", function()
		git("branch", "local-only", "refs/remotes/origin/feat/a")
		assert.are.equal("b1", diff.get_first_commit_subject("local-only"))
	end)

	it("returns an empty list when the default branch cannot be resolved", function()
		assert.are.same({}, diff.get_ancestor_branches("nope"))
		assert.are.same({}, diff.get_ancestor_branches(nil))
	end)

	it("reads the stack parent from .git/gh-stack", function()
		local stack =
			{ stacks = { { trunk = { branch = "main" }, branches = { { branch = "a" }, { branch = "feature" } } } } }
		vim.fn.writefile({ vim.json.encode(stack) }, repo .. "/.git/gh-stack")
		assert.are.equal("a", diff.get_gh_stack_parent("feature"))
	end)

	it("returns nil when gh-stack metadata does not exist", function()
		assert.is_nil(diff.get_gh_stack_parent("feature"))
	end)
end)

describe("make_relative", function()
	it("strips root prefix", function()
		assert.are.equal("lua/foo.lua", diff.make_relative("/home/user/project/lua/foo.lua", "/home/user/project"))
	end)

	it("returns nil when filepath is not under root", function()
		assert.is_nil(diff.make_relative("/other/path/file.lua", "/home/user/project"))
	end)

	it("handles root at filesystem root", function()
		assert.are.equal("file.lua", diff.make_relative("//file.lua", "/"))
	end)

	it("returns nil for empty filepath", function()
		assert.is_nil(diff.make_relative("", "/root"))
	end)

	it("handles deeply nested paths", function()
		assert.are.equal("a/b/c/d.lua", diff.make_relative("/repo/a/b/c/d.lua", "/repo"))
	end)

	it("returns single filename for file directly under root", function()
		assert.are.equal("init.lua", diff.make_relative("/repo/init.lua", "/repo"))
	end)
end)

describe("to_repo_relative", function()
	local original_system

	before_each(function()
		original_system = vim.system
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 0, stdout = "/repo\n" }
				end,
			}
		end
	end)

	after_each(function()
		vim.system = original_system
	end)

	it("returns nil for empty string filepath", function()
		assert.is_nil(diff.to_repo_relative(""))
	end)

	it("returns nil for nil filepath", function()
		assert.is_nil(diff.to_repo_relative(nil))
	end)

	it("returns nil when make_relative yields empty string (repo root path)", function()
		-- fnamemodify("/repo/", ":p") = "/repo/" → make_relative("/repo/", "/repo") = ""
		assert.is_nil(diff.to_repo_relative("/repo/"))
	end)
end)

describe("get_merge_base", function()
	local original_system

	before_each(function()
		original_system = vim.system
	end)

	after_each(function()
		vim.system = original_system
	end)

	it("returns merge-base SHA when ref succeeds", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					if cmd[3] == "main" then
						return { code = 0, stdout = "abc123def456\n" }
					end
					return { code = 1 }
				end,
			}
		end
		assert.are.equal("abc123def456", diff.get_merge_base("main"))
	end)

	it("falls back to origin/<ref> when ref fails", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					if cmd[3] == "main" then
						return { code = 1 }
					elseif cmd[3] == "origin/main" then
						return { code = 0, stdout = "fallback789\n" }
					end
					return { code = 1 }
				end,
			}
		end
		assert.are.equal("fallback789", diff.get_merge_base("main"))
	end)

	it("returns nil for a nil ref without invoking git", function()
		local called = false
		vim.system = function(_cmd, _opts)
			called = true
			return {
				wait = function()
					return { code = 0, stdout = "x" }
				end,
			}
		end
		assert.is_nil(diff.get_merge_base(nil))
		assert.is_false(called)
	end)

	it("returns nil when both ref and origin/<ref> fail", function()
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 1 }
				end,
			}
		end
		assert.is_nil(diff.get_merge_base("nonexistent"))
	end)

	it("trims whitespace from output", function()
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 0, stdout = "  sha_with_spaces  \n" }
				end,
			}
		end
		assert.are.equal("sha_with_spaces", diff.get_merge_base("main"))
	end)
end)

describe("get_review_patch", function()
	local original_system

	before_each(function()
		original_system = vim.system
	end)

	after_each(function()
		vim.system = original_system
	end)

	it("returns the tracked diff from git diff <base>", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					-- git diff <base> -- <path>
					if cmd[3] ~= "--no-index" then
						return { code = 0, stdout = "@@ tracked diff @@\n" }
					end
					return { code = 1, stdout = "" }
				end,
			}
		end
		assert.equals("@@ tracked diff @@\n", diff.get_review_patch("basesha", "f.lua"))
	end)

	it("passes the repo root as cwd so pathspecs resolve from a subdir", function()
		local seen_cwd
		vim.system = function(_cmd, opts)
			seen_cwd = opts.cwd
			return {
				wait = function()
					return { code = 0, stdout = "@@ diff @@\n" }
				end,
			}
		end
		diff.get_review_patch("basesha", "sub/f.lua", "/repo/root")
		assert.equals("/repo/root", seen_cwd)
	end)

	it("falls back to --no-index for an untracked file", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					if cmd[3] == "--no-index" then
						-- git diff --no-index exits 1 with the diff when files differ
						return { code = 1, stdout = "@@ untracked diff @@\n" }
					end
					-- git diff <base> -- <path> is empty for an untracked file
					return { code = 0, stdout = "" }
				end,
			}
		end
		assert.equals("@@ untracked diff @@\n", diff.get_review_patch("basesha", "new.py"))
	end)

	it("returns nil when neither produces a diff", function()
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 0, stdout = "" }
				end,
			}
		end
		assert.is_nil(diff.get_review_patch("basesha", "unchanged.lua"))
	end)
end)

describe("parse_commit_log", function()
	local SEP = "\31"

	it("parses sha, short sha and subject per line", function()
		local out = table.concat({
			"aaa111" .. SEP .. "aaa1" .. SEP .. "feat: add scope",
			"bbb222" .. SEP .. "bbb2" .. SEP .. "fix: handle nil",
		}, "\n") .. "\n"
		local commits = diff.parse_commit_log(out)
		assert.equals(2, #commits)
		assert.same({ sha = "aaa111", short_sha = "aaa1", subject = "feat: add scope" }, commits[1])
		assert.equals("fix: handle nil", commits[2].subject)
	end)

	it("keeps a subject containing tabs and pipes", function()
		local commits = diff.parse_commit_log("aaa111" .. SEP .. "aaa1" .. SEP .. "fix: a\tb | c\n")
		assert.equals("fix: a\tb | c", commits[1].subject)
	end)

	it("keeps an empty subject rather than dropping the commit", function()
		local commits = diff.parse_commit_log("aaa111" .. SEP .. "aaa1" .. SEP .. "\n")
		assert.equals(1, #commits)
		assert.equals("", commits[1].subject)
	end)

	it("returns an empty list for empty or nil output", function()
		assert.same({}, diff.parse_commit_log(""))
		assert.same({}, diff.parse_commit_log(nil))
	end)

	it("skips malformed lines", function()
		local commits = diff.parse_commit_log("garbage without separators\n")
		assert.same({}, commits)
	end)
end)

describe("make_relative", function()
	it("strips the root with a path boundary", function()
		assert.equals("lua/a.lua", diff.make_relative("/repo/lua/a.lua", "/repo"))
		assert.equals("lua/a.lua", diff.make_relative("/repo/lua/a.lua", "/repo/"))
		assert.equals("", diff.make_relative("/repo", "/repo"))
	end)

	it("does not treat a sibling directory sharing the prefix as inside the root", function()
		assert.is_nil(diff.make_relative("/repo-other/x.lua", "/repo"))
		assert.is_nil(diff.make_relative("/repository/x.lua", "/repo"))
		assert.is_nil(diff.make_relative("/elsewhere/x.lua", "/repo"))
	end)
end)

describe("find_checkout_collisions", function()
	local function kinds(map)
		return function(path)
			return map[path]
		end
	end

	it("reports target paths that exist here untracked, ignored or not", function()
		local target = { "a.lua", "b/c.lua", "d.lua", ".env" }
		local here = { ["d.lua"] = true }
		local on_disk = kinds({ ["a.lua"] = "file", ["b/c.lua"] = "file", ["d.lua"] = "file", [".env"] = "file" })
		assert.same({ ".env", "a.lua", "b/c.lua" }, diff.find_checkout_collisions(target, here, on_disk))
	end)

	it("ignores target paths that are absent here", function()
		assert.same({}, diff.find_checkout_collisions({ "a.lua" }, {}, kinds({})))
		assert.same({}, diff.find_checkout_collisions({}, {}, kinds({ ["x"] = "file" })))
	end)

	it("catches file/directory collisions in both directions", function()
		-- target wants a file where an untracked directory sits
		assert.same({ "foo" }, diff.find_checkout_collisions({ "foo" }, {}, kinds({ ["foo"] = "directory" })))
		-- target wants a directory where an untracked file sits
		assert.same({ "foo" }, diff.find_checkout_collisions({ "foo/bar" }, {}, kinds({ ["foo"] = "file" })))
		assert.same({ "a" }, diff.find_checkout_collisions({ "a/b/c" }, {}, kinds({ ["a"] = "file" })))
		-- a tracked directory on the way is fine
		assert.same({}, diff.find_checkout_collisions({ "foo/bar" }, { ["foo"] = true }, kinds({ ["foo"] = "directory" })))
	end)
end)

describe("parse_worktree_roots", function()
	it("keeps branch and detached worktrees, skips bare ones", function()
		local out = table.concat({
			"worktree /repo",
			"HEAD aaaa",
			"branch refs/heads/main",
			"",
			"worktree /repo/.claude/worktrees/x",
			"HEAD bbbb",
			"detached",
			"",
			"worktree /srv/repo.git",
			"bare",
			"",
		}, "\n")
		assert.same({ "/repo", "/repo/.claude/worktrees/x" }, diff.parse_worktree_roots(out))
	end)

	it("returns nothing for empty or nil output", function()
		assert.same({}, diff.parse_worktree_roots(""))
		assert.same({}, diff.parse_worktree_roots(nil))
	end)
end)

describe("parse_commit_parents", function()
	it("reads parent headers in order and ignores the message", function()
		local object = table.concat({
			"tree 1111111111111111111111111111111111111111",
			"parent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"parent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			"author t <t@t> 0 +0000",
			"committer t <t@t> 0 +0000",
			"",
			"merge: parent cccccccccccccccccccccccccccccccccccccccc in the message must not count",
		}, "\n")
		assert.same({
			"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		}, diff.parse_commit_parents(object))
	end)

	it("returns no parents for a root commit object or bad input", function()
		assert.same({}, diff.parse_commit_parents("tree 1111\nauthor t\n\nroot"))
		assert.same({}, diff.parse_commit_parents(nil))
		assert.same({}, diff.parse_commit_parents(""))
	end)
end)

describe("is_worktree_dirty", function()
	local original_system = vim.system

	after_each(function()
		vim.system = original_system
	end)

	it("is false for clean porcelain output", function()
		vim.system = function()
			return {
				wait = function()
					return { code = 0, stdout = "" }
				end,
			}
		end
		assert.is_false(diff.is_worktree_dirty("/repo"))
	end)

	it("is true when porcelain reports changes", function()
		vim.system = function()
			return {
				wait = function()
					return { code = 0, stdout = " M lua/fude/init.lua\n" }
				end,
			}
		end
		assert.is_true(diff.is_worktree_dirty("/repo"))
	end)

	it("is true when git itself fails, so no checkout runs over unknown state", function()
		vim.system = function()
			return {
				wait = function()
					return { code = 128, stdout = "" }
				end,
			}
		end
		assert.is_true(diff.is_worktree_dirty("/repo"))
	end)
end)
