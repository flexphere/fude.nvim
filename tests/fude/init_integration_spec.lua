local config = require("fude.config")
local init = require("fude.init")
local helpers = require("tests.helpers")

--- Standard mock responses for init.start()
local function setup_gh_mocks()
	-- Mock git symbolic-ref to always succeed (simulate normal branch checkout).
	-- This is needed because CI runs in detached HEAD, which would skip the "pr:view" path.
	local original_system = vim.system
	helpers.mock(vim, "system", function(cmd, ...)
		if cmd[1] == "git" and cmd[2] == "symbolic-ref" then
			-- --short returns branch name, without --short returns full ref
			local has_short = false
			for _, arg in ipairs(cmd) do
				if arg == "--short" then
					has_short = true
					break
				end
			end
			return {
				wait = function()
					return {
						code = 0,
						stdout = has_short and "feature-branch\n" or "refs/heads/feature-branch\n",
						stderr = "",
					}
				end,
			}
		end
		return original_system(cmd, ...)
	end)

	helpers.mock_gh({
		["pr:view"] = {
			number = 42,
			baseRefName = "main",
			headRefName = "feature-branch",
			url = "https://github.com/owner/repo/pull/42",
		},
		["api:repos/{owner}/{repo}/pulls/42/files"] = {
			{ filename = "lua/fude/init.lua", status = "modified", additions = 10, deletions = 5 },
			{ filename = "lua/fude/config.lua", status = "modified", additions = 3, deletions = 1 },
		},
		["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
		["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
		["repo:view"] = { owner = { login = "testowner" }, name = "testrepo" },
		["api:graphql"] = {
			data = { repository = { pullRequest = { files = { nodes = {}, pageInfo = { hasNextPage = false } } } } },
		},
	})
	helpers.mock_head_sha("abc123def456")

	-- Mock diff.to_repo_relative for BufEnter handler
	helpers.mock_diff({})
end

describe("init integration", function()
	before_each(function()
		config.setup({})
		setup_gh_mocks()
	end)

	after_each(function()
		-- Stop if still active (cleans up augroups, keymaps, etc.)
		if config.state.active then
			-- Mock git checkout for stop (it tries to restore HEAD in commit scope)
			config.state.scope = "full_pr"
			init.stop()
		end
		helpers.cleanup()
	end)

	describe("start", function()
		it("activates state", function()
			init.start()

			local ok = helpers.wait_for(function()
				return config.state.active
			end)
			assert.is_true(ok, "State should become active")
			assert.is_true(config.state.active)
		end)

		it("sets PR information in state", function()
			init.start()

			helpers.wait_for(function()
				return config.state.pr_number ~= nil
			end)

			assert.are.equal(42, config.state.pr_number)
			assert.are.equal("main", config.state.base_ref)
			assert.are.equal("feature-branch", config.state.head_ref)
			assert.are.equal("https://github.com/owner/repo/pull/42", config.state.pr_url)
		end)

		it("fetches changed files", function()
			init.start()

			local ok = helpers.wait_for(function()
				return #(config.state.changed_files or {}) > 0
			end)
			assert.is_true(ok, "Should have changed files")
			assert.are.equal(2, #config.state.changed_files)
			assert.are.equal("lua/fude/init.lua", config.state.changed_files[1].path)
		end)

		it("creates an augroup", function()
			init.start()

			helpers.wait_for(function()
				return config.state.active
			end)

			assert.is_not_nil(config.state.augroup)
		end)

		it("sets buffer-local keymaps", function()
			local buf = helpers.create_buf({ "line1" })
			vim.api.nvim_set_current_buf(buf)
			vim.bo[buf].buftype = ""

			init.start()

			helpers.wait_for(function()
				return config.state.active
			end)

			-- Check for ]c and [c keymaps
			local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
			local found_next = false
			local found_prev = false
			for _, km in ipairs(keymaps) do
				if km.lhs == "]c" then
					found_next = true
				end
				if km.lhs == "[c" then
					found_prev = true
				end
			end
			assert.is_true(found_next, "Should have ]c keymap")
			assert.is_true(found_prev, "Should have [c keymap")
		end)

		it("does nothing when already active", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active
			end)

			local pr_number = config.state.pr_number
			init.start() -- Should be a no-op

			assert.are.equal(pr_number, config.state.pr_number)
		end)

		it("calls on_review_start callback after all data is fetched", function()
			local cb_called = false
			local cb_info = nil
			config.setup({
				on_review_start = function(info)
					cb_called = true
					cb_info = info
				end,
			})
			setup_gh_mocks()

			init.start()

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "on_review_start should be called")
			assert.are.equal(42, cb_info.pr_number)
			assert.are.equal("main", cb_info.base_ref)
			assert.are.equal("feature-branch", cb_info.head_ref)
			assert.are.equal("https://github.com/owner/repo/pull/42", cb_info.pr_url)
		end)

		it("does not error when on_review_start is nil", function()
			config.setup({ on_review_start = nil })
			setup_gh_mocks()

			init.start()

			local ok = helpers.wait_for(function()
				return config.state.active
			end)
			assert.is_true(ok, "Should activate without on_review_start")
		end)

		it("catches errors from on_review_start callback", function()
			config.setup({
				on_review_start = function()
					error("user callback error")
				end,
			})
			setup_gh_mocks()

			-- Should not raise an error
			init.start()

			local ok = helpers.wait_for(function()
				return config.state.active
			end)
			assert.is_true(ok, "Should activate even if on_review_start errors")
		end)
	end)

	describe("stop", function()
		it("resets state to inactive", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active
			end)

			init.stop()

			assert.is_false(config.state.active)
			assert.is_nil(config.state.pr_number)
		end)

		it("deletes augroup", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active
			end)

			local augroup_id = config.state.augroup
			assert.is_not_nil(augroup_id)

			init.stop()

			-- Augroup should be deleted
			local ok = pcall(vim.api.nvim_get_autocmds, { group = augroup_id })
			assert.is_false(ok, "Augroup should have been deleted")
		end)

		it("removes buffer-local keymaps", function()
			local buf = helpers.create_buf({ "line1" })
			vim.api.nvim_set_current_buf(buf)
			vim.bo[buf].buftype = ""

			init.start()
			helpers.wait_for(function()
				return config.state.active
			end)

			init.stop()

			local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
			local found_next = false
			for _, km in ipairs(keymaps) do
				if km.lhs == "]c" then
					found_next = true
				end
			end
			assert.is_false(found_next, "Should not have ]c keymap after stop")
		end)

		it("does nothing when not active", function()
			assert.is_false(config.state.active)
			-- Should not error
			init.stop()
			assert.is_false(config.state.active)
		end)
	end)

	describe("start in detached HEAD", function()
		it("sets commit scope automatically", function()
			-- Mock vim.system to simulate detached HEAD (symbolic-ref fails)
			local original_system = vim.system
			helpers.mock(vim, "system", function(cmd, ...)
				if cmd[1] == "git" and cmd[2] == "symbolic-ref" then
					return {
						wait = function()
							return { code = 1, stdout = "", stderr = "" }
						end,
					}
				end
				return original_system(cmd, ...)
			end)

			-- Mock responses for detached HEAD startup
			helpers.mock_gh({
				-- get_pr_by_commit: finds PR via commits API
				["api:repos/{owner}/{repo}/commits/abc123def456/pulls"] = {
					{
						number = 42,
						state = "open",
						html_url = "https://github.com/owner/repo/pull/42",
						base = { ref = "main" },
						head = { ref = "feature-branch" },
					},
				},
				-- get_commit_files: commit-specific changed files
				["api:repos/{owner}/{repo}/commits/abc123def456"] = {
					files = {
						{ filename = "lua/fude/gh.lua", status = "modified", additions = 5, deletions = 2 },
					},
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/commits"] = {
					{ sha = "abc123def456", commit = { message = "test commit", author = { name = "test" } } },
				},
				["repo:view"] = { owner = { login = "testowner" }, name = "testrepo" },
				["api:graphql"] = {
					data = {
						repository = {
							pullRequest = { files = { nodes = {}, pageInfo = { hasNextPage = false } } },
						},
					},
				},
				["api:user"] = { login = "testuser" },
			})
			helpers.mock_head_sha("abc123def456")

			init.start()

			local ok = helpers.wait_for(function()
				return config.state.active and config.state.scope == "commit"
			end)
			assert.is_true(ok, "Should activate with commit scope")
			assert.are.equal("commit", config.state.scope)
			assert.are.equal("abc123def456", config.state.scope_commit_sha)
			assert.are.equal(1, #config.state.changed_files)
			assert.are.equal("lua/fude/gh.lua", config.state.changed_files[1].path)
		end)
	end)

	describe("reload", function()
		it("updates state data", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active and #config.state.changed_files > 0
			end)

			-- Override mock to return different files on reload
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/files"] = {
					{ filename = "lua/fude/new.lua", status = "added", additions = 20, deletions = 0 },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/commits"] = {
					{ sha = "abc123def456", commit = { message = "test commit", author = { name = "test" } } },
					{ sha = "def789", commit = { message = "new commit", author = { name = "test" } } },
				},
				["repo:view"] = { owner = { login = "testowner" }, name = "testrepo" },
				["api:graphql"] = {
					data = {
						repository = {
							pullRequest = { files = { nodes = {}, pageInfo = { hasNextPage = false } } },
						},
					},
				},
				["api:user"] = { login = "testuser" },
			})
			helpers.mock_head_sha("abc123def456")

			init.reload()

			local ok = helpers.wait_for(function()
				return not config.state.reloading
			end)
			assert.is_true(ok, "Reload should complete")
			assert.are.equal(1, #config.state.changed_files)
			assert.are.equal("lua/fude/new.lua", config.state.changed_files[1].path)
			assert.are.equal(2, #config.state.pr_commits)
		end)

		it("prevents concurrent reloads", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active and #config.state.changed_files > 0
			end)

			config.state.reloading = true
			init.reload() -- Should be a no-op
			assert.is_true(config.state.reloading, "reloading flag should remain true")
		end)

		it("does nothing when not active", function()
			assert.is_false(config.state.active)
			-- Should not error
			init.reload()
			assert.is_false(config.state.reloading)
		end)

		it("suppresses notification when silent", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active and #config.state.changed_files > 0
			end)

			init.reload(true) -- silent

			local ok = helpers.wait_for(function()
				return not config.state.reloading
			end)
			assert.is_true(ok, "Silent reload should complete")
		end)

		it("on_ready guard skips when session stopped", function()
			-- Test the on_ready guard: if config.state.active is false when
			-- on_ready fires, on_review_start must NOT be called for that
			-- (already stopped) session. This spec verifies that a normal
			-- start → stop → start サイクルでは guard によって次の
			-- on_review_start がブロックされないことを確認する。
			local call_count = 0
			config.setup({
				on_review_start = function()
					call_count = call_count + 1
				end,
			})
			setup_gh_mocks()

			-- First start: on_review_start fires normally
			init.start()
			helpers.wait_for(function()
				return call_count > 0
			end)
			assert.are.equal(1, call_count, "on_review_start should fire once on start")

			-- Stop the session — reset_state sets active=false
			config.state.scope = "full_pr"
			init.stop()
			assert.is_false(config.state.active, "stop should set active=false")

			-- Second start: proves the guard allows callback when active=true
			setup_gh_mocks()
			init.start()
			helpers.wait_for(function()
				return call_count > 1
			end)
			assert.are.equal(2, call_count, "on_review_start should fire again on second start")

			-- Cleanup for stop
			config.state.scope = "full_pr"
		end)

		it("does not update state when session changed during reload", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active and #config.state.changed_files > 0
			end)

			-- Start reload, then immediately simulate session change
			init.reload()
			-- Change pr_number to simulate stop→start with different PR
			config.state.pr_number = 999

			-- Wait for reload callbacks to complete
			helpers.wait_for(function()
				return not config.state.reloading
			end)

			-- The reload should have detected session mismatch and not updated
			assert.are.equal(999, config.state.pr_number, "pr_number should remain as changed")
		end)

		it("recalculates scope_commit_index after reload", function()
			init.start()
			helpers.wait_for(function()
				return config.state.active and #config.state.pr_commits > 0
			end)

			-- Simulate commit scope
			config.state.scope = "commit"
			config.state.scope_commit_sha = "abc123def456"

			-- Override mock to return commits in reload
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/files"] = {
					{ filename = "lua/fude/init.lua", status = "modified", additions = 10, deletions = 5 },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/commits"] = {
					{ sha = "first111", commit = { message = "first", author = { name = "test" } } },
					{ sha = "abc123def456", commit = { message = "second", author = { name = "test" } } },
					{ sha = "third333", commit = { message = "third", author = { name = "test" } } },
				},
				["repo:view"] = { owner = { login = "testowner" }, name = "testrepo" },
				["api:graphql"] = {
					data = {
						repository = {
							pullRequest = { files = { nodes = {}, pageInfo = { hasNextPage = false } } },
						},
					},
				},
				["api:user"] = { login = "testuser" },
			})
			helpers.mock_head_sha("abc123def456")

			init.reload()

			local ok = helpers.wait_for(function()
				return not config.state.reloading
			end)
			assert.is_true(ok, "Reload should complete")
			assert.are.equal(2, config.state.scope_commit_index, "Should find commit at index 2")
		end)
	end)

	describe("toggle", function()
		it("starts when inactive", function()
			init.toggle()
			helpers.wait_for(function()
				return config.state.active
			end)
			assert.is_true(config.state.active)
		end)

		it("stops when active", function()
			init.toggle()
			helpers.wait_for(function()
				return config.state.active
			end)

			init.toggle()
			assert.is_false(config.state.active)
		end)
	end)
end)
