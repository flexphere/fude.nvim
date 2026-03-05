local config = require("fude.config")
local init = require("fude.init")
local helpers = require("tests.helpers")

--- Standard mock responses for init.start()
local function setup_gh_mocks()
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
		["api:graphql"] = {
			data = { repository = { pullRequest = { files = { nodes = {}, pageInfo = { hasNextPage = false } } } } },
		},
		["repo:view"] = {
			owner = { login = "owner" },
			name = "repo",
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
