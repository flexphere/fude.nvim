local stack = require("fude.stack")
local gh = require("fude.gh")
local diff = require("fude.diff")
local config = require("fude.config")
local helpers = require("tests.helpers")

describe("gh.parse_pr_stack", function()
	local function response(stack_value)
		return { data = { repository = { pullRequest = { stack = stack_value } } } }
	end

	it("returns the stack PRs bottom first", function()
		local prs = gh.parse_pr_stack(response({
			entries = {
				nodes = {
					{
						pullRequest = {
							number = 1,
							title = "a",
							state = "OPEN",
							headRefName = "feat-a",
							baseRefName = "main",
						},
					},
					{
						pullRequest = {
							number = 2,
							title = "b",
							state = "MERGED",
							headRefName = "feat-b",
							baseRefName = "feat-a",
						},
					},
				},
			},
		}))
		assert.are.same({
			{ number = 1, title = "a", state = "OPEN", head_ref = "feat-a", base_ref = "main" },
			{ number = 2, title = "b", state = "MERGED", head_ref = "feat-b", base_ref = "feat-a" },
		}, prs)
	end)

	it("returns nil when the PR is in no stack", function()
		assert.is_nil(gh.parse_pr_stack(response(vim.NIL)))
		assert.is_nil(gh.parse_pr_stack({ data = { repository = { pullRequest = vim.NIL } } }))
		assert.is_nil(gh.parse_pr_stack(nil))
	end)

	it("skips malformed nodes and defaults missing strings", function()
		local prs = gh.parse_pr_stack(response({
			entries = {
				nodes = {
					vim.NIL,
					{ pullRequest = vim.NIL },
					{ pullRequest = { number = "3", headRefName = "x" } },
					{ pullRequest = { number = 4, headRefName = "feat-d", title = vim.NIL } },
				},
			},
		}))
		assert.are.same({ { number = 4, title = "", state = "", head_ref = "feat-d", base_ref = "" } }, prs)
	end)
end)

describe("diff.parse_worktree_list", function()
	it("keeps worktrees with a branch, prunable ones included, and skips bare and detached ones", function()
		local output = table.concat({
			"worktree /repo",
			"HEAD aaa",
			"branch refs/heads/main",
			"",
			"worktree /repo.git",
			"bare",
			"",
			"worktree /wt/detached",
			"HEAD bbb",
			"detached",
			"",
			"worktree /wt/gone",
			"HEAD ccc",
			"branch refs/heads/gone",
			"prunable gitdir file points to non-existent location",
			"",
			"worktree /wt/feat",
			"HEAD ddd",
			"branch refs/heads/feat/b",
			"",
		}, "\n")
		assert.are.same({
			{ path = "/repo", branch = "main" },
			{ path = "/wt/gone", branch = "gone" },
			{ path = "/wt/feat", branch = "feat/b" },
		}, diff.parse_worktree_list(output))
	end)

	it("returns an empty list for empty output", function()
		assert.are.same({}, diff.parse_worktree_list(""))
		assert.are.same({}, diff.parse_worktree_list(nil))
	end)
end)

describe("stack.build_stack_entries", function()
	local prs = {
		{ number = 1, title = "base", state = "MERGED", head_ref = "a", base_ref = "main" },
		{ number = 2, title = "mid", state = "OPEN", head_ref = "b", base_ref = "a" },
		{ number = 3, title = "top", state = "OPEN", head_ref = "c", base_ref = "b" },
	}

	it("lists open PRs with their stack position and marks the current one", function()
		assert.are.same({
			{ number = 2, head_ref = "b", is_current = true, display_text = "[2/3] #2 mid (a ← b)" },
			{ number = 3, head_ref = "c", is_current = false, display_text = "[3/3] #3 top (b ← c)" },
		}, stack.build_stack_entries(prs, 2))
	end)

	it("keeps the current PR even when it is not open", function()
		local entries = stack.build_stack_entries(prs, 1)
		assert.are.equal(3, #entries)
		assert.is_true(entries[1].is_current)
		assert.are.equal("[1/3] #1 base (main ← a)", entries[1].display_text)
	end)
end)

describe("stack.resolve_switch_target", function()
	local worktrees = { { path = "/repo", branch = "a" }, { path = "/wt/b", branch = "b" } }

	it("returns current when the branch is checked out here", function()
		assert.are.same({ kind = "current" }, stack.resolve_switch_target(worktrees, "/repo", "a"))
	end)

	it("returns cd when another worktree has the branch", function()
		assert.are.same({ kind = "cd", path = "/wt/b" }, stack.resolve_switch_target(worktrees, "/repo", "b"))
	end)

	it("returns switch when no worktree has the branch", function()
		assert.are.same({ kind = "switch" }, stack.resolve_switch_target(worktrees, "/repo", "c"))
	end)
end)

describe("stack.is_path_under", function()
	it("matches the root itself and paths inside it", function()
		assert.is_true(stack.is_path_under("/repo", "/repo"))
		assert.is_true(stack.is_path_under("/repo/lua/x.lua", "/repo"))
		assert.is_true(stack.is_path_under("/repo/x.lua", "/repo/"))
	end)

	it("does not match a sibling sharing the prefix", function()
		assert.is_false(stack.is_path_under("/repo-other/x.lua", "/repo"))
		assert.is_false(stack.is_path_under("/other/x.lua", "/repo"))
	end)
end)

describe("stack.find_owning_root", function()
	it("returns the deepest root containing the path", function()
		local roots = { "/repo", "/repo/.claude/worktrees/x", "/other" }
		assert.are.equal("/repo", stack.find_owning_root("/repo/lua/a.lua", roots))
		assert.are.equal("/repo/.claude/worktrees/x", stack.find_owning_root("/repo/.claude/worktrees/x/a.lua", roots))
		assert.is_nil(stack.find_owning_root("/elsewhere/a.lua", roots))
	end)
end)

describe("review start during a PR switch", function()
	local notifications

	before_each(function()
		notifications = {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(stack, "is_switching", function()
			return true
		end)
		helpers.mock(diff, "get_repo_root", function()
			error("start must refuse before touching git")
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	for _, case in ipairs({
		{
			"github review",
			function()
				require("fude").start()
			end,
		},
		{
			"local review",
			function()
				require("fude.local.session").start()
			end,
		},
	}) do
		it("refuses to start a " .. case[1], function()
			case[2]()
			assert.is_false(config.state.active)
			assert.are.equal(1, #notifications)
			assert.truthy(notifications[1].msg:find("PR switch is checking out"))
			assert.are.equal(vim.log.levels.WARN, notifications[1].level)
		end)
	end
end)

describe("stack switching", function()
	local init = require("fude")
	local root, other_wt
	local calls, notifications, cmds, file_bufs

	local function add_file_buf(path)
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		table.insert(file_bufs, buf)
		return buf
	end

	local function mock_git_status(stdout, checkout_code)
		local original = vim.system
		helpers.mock(vim, "system", function(cmd, opts, cb)
			if cmd[1] == "git" and cmd[2] == "checkout" then
				table.insert(calls.git_checkout, cmd[3])
				return {
					wait = function()
						return { code = checkout_code or 0, stdout = "", stderr = "conflict" }
					end,
				}
			end
			if cmd[1] == "git" and cmd[2] == "status" then
				return {
					wait = function()
						return { code = 0, stdout = stdout, stderr = "" }
					end,
				}
			end
			return original(cmd, opts, cb)
		end)
	end

	before_each(function()
		root = vim.fn.resolve(vim.fn.tempname() .. "-repo")
		other_wt = vim.fn.resolve(vim.fn.tempname() .. "-wt")
		vim.fn.mkdir(root, "p")
		vim.fn.mkdir(other_wt, "p")
		root = vim.fn.resolve(root)
		other_wt = vim.fn.resolve(other_wt)

		calls = { stop = 0, start = 0, checkout = {}, git_checkout = {} }
		notifications = {}
		cmds = {}
		file_bufs = {}

		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 2
		config.state.original_head_ref = "b"

		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(init, "stop", function()
			calls.stop = calls.stop + 1
			config.reset_state()
		end)
		helpers.mock(init, "start", function()
			calls.start = calls.start + 1
		end)
		helpers.mock(diff, "get_repo_root", function()
			return root
		end)
		helpers.mock(diff, "get_worktrees", function()
			return { { path = root, branch = "b" }, { path = other_wt, branch = "c" } }
		end)
		helpers.mock(gh, "checkout_pr", function(number, cb)
			table.insert(calls.checkout, number)
			vim.schedule(function()
				cb(nil)
			end)
		end)
		local original_cmd = vim.cmd
		helpers.mock(vim, "cmd", function(c)
			if type(c) == "string" and (c:match("^cd ") or c == "checktime") then
				table.insert(cmds, c)
				return
			end
			return original_cmd(c)
		end)
	end)

	after_each(function()
		helpers.cleanup()
		for _, buf in ipairs(file_bufs) do
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		vim.fn.delete(root, "rf")
		vim.fn.delete(other_wt, "rf")
	end)

	local function has_notification(pattern, level)
		for _, n in ipairs(notifications) do
			if n.msg:find(pattern) and (level == nil or n.level == level) then
				return true
			end
		end
		return false
	end

	it("does nothing for the current PR", function()
		stack.switch_to({ number = 2, head_ref = "b", is_current = true })
		assert.are.equal(0, calls.stop)
	end)

	it("checks out a branch checked out nowhere and restarts the review", function()
		mock_git_status("")
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.is_true(helpers.wait_for(function()
			return calls.start == 1
		end))
		assert.are.equal(1, calls.stop)
		assert.are.same({ 4 }, calls.checkout)
		assert.are.same({}, calls.git_checkout)
		assert.are.same({ "checktime" }, cmds)
	end)

	it("checks the original branch out again and restarts when checkout fails", function()
		mock_git_status("")
		helpers.mock(gh, "checkout_pr", function(_, cb)
			vim.schedule(function()
				cb("could not checkout\n")
			end)
		end)
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.is_true(helpers.wait_for(function()
			return calls.start == 1
		end))
		assert.is_true(has_notification("Failed to check out PR #4: could not checkout", vim.log.levels.ERROR))
		assert.are.same({ "b" }, calls.git_checkout)
		assert.are.same({ "checktime" }, cmds)
	end)

	it("reports switching only while the checkout runs", function()
		mock_git_status("")
		local checkout_cb
		helpers.mock(gh, "checkout_pr", function(_, cb)
			checkout_cb = cb
		end)
		assert.is_false(stack.is_switching())
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.is_true(stack.is_switching())
		checkout_cb(nil)
		assert.is_false(stack.is_switching())
		assert.are.equal(1, calls.start)
	end)

	it("keeps the review stopped when the original branch cannot be restored", function()
		mock_git_status("", 1)
		helpers.mock(gh, "checkout_pr", function(_, cb)
			cb("ff failed")
		end)
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.are.same({ "b" }, calls.git_checkout)
		assert.are.same({ "checktime" }, cmds)
		assert.are.equal(0, calls.start)
		assert.is_true(has_notification("Failed to restore b: conflict", vim.log.levels.ERROR))
	end)

	it("refuses to switch with uncommitted changes", function()
		mock_git_status(" M lua/x.lua\n")
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.are.equal(0, calls.stop)
		assert.is_true(has_notification("Uncommitted changes", vim.log.levels.WARN))
	end)

	it("refuses to switch with a modified buffer under the worktree", function()
		local buf = add_file_buf(root .. "/x.lua")
		vim.bo[buf].modified = true
		stack.switch_to({ number = 3, head_ref = "c", is_current = false })
		assert.are.equal(0, calls.stop)
		assert.is_true(has_notification("Unsaved buffers", vim.log.levels.WARN))
	end)

	it("aborts when stop keeps the session active", function()
		mock_git_status("")
		helpers.mock(init, "stop", function()
			calls.stop = calls.stop + 1
		end)
		stack.switch_to({ number = 4, head_ref = "d", is_current = false })
		assert.are.equal(1, calls.stop)
		assert.are.same({}, calls.checkout)
		assert.are.equal(0, calls.start)
	end)

	it("cds to the worktree holding the branch and wipes only old-worktree buffers", function()
		local old_buf = add_file_buf(root .. "/x.lua")
		local other_buf = add_file_buf(root .. "-other/y.lua")
		stack.switch_to({ number = 3, head_ref = "c", is_current = false })
		assert.are.same({ "cd " .. vim.fn.fnameescape(other_wt) }, cmds)
		assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
		assert.is_true(vim.api.nvim_buf_is_valid(other_buf))
		assert.are.equal(1, calls.stop)
		assert.are.equal(1, calls.start)
	end)

	it("keeps windows showing old buffers, now on the same file in the new worktree", function()
		vim.fn.writefile({ "x" }, other_wt .. "/x.lua")
		local old_buf = add_file_buf(root .. "/x.lua")
		vim.api.nvim_win_set_buf(0, old_buf)
		local win = vim.api.nvim_get_current_win()
		local win_count = #vim.api.nvim_list_wins()
		stack.switch_to({ number = 3, head_ref = "c", is_current = false })
		table.insert(file_bufs, vim.api.nvim_win_get_buf(win))
		assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
		assert.are.equal(win_count, #vim.api.nvim_list_wins())
		assert.are.equal(other_wt .. "/x.lua", vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))))
	end)

	it("leaves buffers of a worktree nested in the current one alone", function()
		local nested = root .. "/.claude/worktrees/c"
		vim.fn.mkdir(nested, "p")
		helpers.mock(diff, "get_worktrees", function()
			return { { path = root, branch = "b" }, { path = nested, branch = "c" } }
		end)
		local nested_buf = add_file_buf(nested .. "/y.lua")
		vim.bo[nested_buf].modified = true
		stack.switch_to({ number = 3, head_ref = "c", is_current = false })
		assert.are.equal(1, calls.stop)
		assert.is_true(vim.api.nvim_buf_is_valid(nested_buf))
	end)

	it("refuses when the target worktree directory is gone", function()
		vim.fn.delete(other_wt, "rf")
		stack.switch_to({ number = 3, head_ref = "c", is_current = false })
		assert.are.equal(0, calls.stop)
		assert.is_true(has_notification("Worktree not found", vim.log.levels.WARN))
	end)

	it("select_stack switches to the picked PR", function()
		mock_git_status("")
		helpers.mock_gh({
			["api:graphql"] = {
				data = {
					repository = {
						pullRequest = {
							stack = {
								entries = {
									nodes = {
										{ pullRequest = { number = 2, state = "OPEN", headRefName = "b" } },
										{ pullRequest = { number = 4, state = "OPEN", headRefName = "d" } },
									},
								},
							},
						},
					},
				},
			},
		})
		helpers.mock(gh, "checkout_pr", function(number, cb)
			table.insert(calls.checkout, number)
			cb(nil)
		end)
		helpers.mock(vim.ui, "select", function(items, _, on_choice)
			on_choice(items[2])
		end)
		stack.select_stack()
		assert.is_true(helpers.wait_for(function()
			return calls.start == 1
		end))
		assert.are.same({ 4 }, calls.checkout)
	end)

	it("select_stack reports a PR in no stack", function()
		helpers.mock_gh({ ["api:graphql"] = { data = { repository = { pullRequest = { stack = vim.NIL } } } } })
		stack.select_stack()
		assert.is_true(helpers.wait_for(function()
			return has_notification("PR #2 is not in a stack", vim.log.levels.INFO)
		end))
	end)

	it("select_stack ignores a selection after the review was stopped", function()
		helpers.mock_gh({
			["api:graphql"] = {
				data = {
					repository = {
						pullRequest = {
							stack = { entries = { nodes = { { pullRequest = { number = 4, state = "OPEN", headRefName = "d" } } } } },
						},
					},
				},
			},
		})
		local pending
		helpers.mock(vim.ui, "select", function(items, _, on_choice)
			pending = function()
				on_choice(items[1])
			end
		end)
		stack.select_stack()
		assert.is_true(helpers.wait_for(function()
			return pending ~= nil
		end))
		config.reset_state()
		pending()
		assert.are.equal(0, calls.stop)
	end)

	it(":FudeReviewStackSwitch is wired to select_stack", function()
		vim.cmd("runtime plugin/fude.lua")
		config.state.active = false
		vim.cmd("FudeReviewStackSwitch")
		assert.is_true(has_notification("Not active", vim.log.levels.WARN))
	end)
end)
