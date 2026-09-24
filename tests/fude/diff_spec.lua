local diff = require("fude.diff")

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

describe("sort_branches_by_distance", function()
	it("sorts nearest first and breaks ties by name", function()
		assert.are.same(
			{ "near", "a-mid", "b-mid", "far" },
			diff.sort_branches_by_distance({ "9 far", "3 b-mid", "1 near", "3 a-mid" })
		)
	end)

	it("skips malformed lines", function()
		assert.are.same({ "ok" }, diff.sort_branches_by_distance({ "x y", "", "2 ok" }))
		assert.are.same({}, diff.sort_branches_by_distance(nil))
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
		git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "root")
		git("update-ref", "refs/remotes/origin/main", "HEAD")
		git("update-ref", "refs/remotes/origin/old-merged", "HEAD")
		-- stack: main -> a -> b -> (HEAD) feature
		git("checkout", "-q", "-b", "feature")
		git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a1")
		git("update-ref", "refs/remotes/origin/a", "HEAD")
		git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "b1")
		git("update-ref", "refs/remotes/origin/b", "HEAD")
		git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "f1")
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
		assert.are.same({ "b", "a" }, diff.get_ancestor_branches("main"))
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
