local config = require("fude.config")
local preview = require("fude.preview")
local helpers = require("tests.helpers")

describe("preview integration", function()
	before_each(function()
		config.setup({})
		helpers.mock_diff({ ["source.lua"] = "source.lua" })
		helpers.mock_base_content("base line 1\nbase line 2\nbase line 3")
	end)

	after_each(function()
		helpers.cleanup()
	end)

	describe("open_preview", function()
		it("creates a preview window", function()
			local buf = helpers.create_buf({ "current line 1", "current line 2" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			assert.is_not_nil(config.state.preview_win)
			assert.is_true(vim.api.nvim_win_is_valid(config.state.preview_win))
		end)

		it("displays base content in preview buffer", function()
			local buf = helpers.create_buf({ "current line 1", "current line 2" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			assert.is_not_nil(config.state.preview_buf)
			local lines = vim.api.nvim_buf_get_lines(config.state.preview_buf, 0, -1, false)
			assert.are.equal("base line 1", lines[1])
			assert.are.equal("base line 2", lines[2])
			assert.are.equal("base line 3", lines[3])
		end)

		it("enables diff mode on both windows", function()
			local buf = helpers.create_buf({ "line 1", "line 2" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			assert.is_true(vim.wo[config.state.preview_win].diff, "Preview window should be in diff mode")
			assert.is_true(vim.wo[source_win].diff, "Source window should be in diff mode")
		end)

		it("shows placeholder for new file when base content is nil", function()
			helpers.mock_base_content(nil)

			local buf = helpers.create_buf({ "new file content" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			local lines = vim.api.nvim_buf_get_lines(config.state.preview_buf, 0, -1, false)
			-- Should contain placeholder text about new file
			local content = table.concat(lines, "\n")
			assert.is_truthy(content:find("New file", 1, true) or content:find("does not exist", 1, true))
		end)

		it("does nothing when not active", function()
			local buf = helpers.create_buf({ "line 1" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = false

			preview.open_preview(source_win)

			assert.is_nil(config.state.preview_win)
		end)
	end)

	describe("close_preview", function()
		it("closes preview window and clears state", function()
			local buf = helpers.create_buf({ "line 1", "line 2" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)
			local preview_win = config.state.preview_win
			assert.is_not_nil(preview_win)

			preview.close_preview()

			assert.is_nil(config.state.preview_win)
			assert.is_nil(config.state.preview_buf)
			assert.is_false(vim.api.nvim_win_is_valid(preview_win))
		end)

		it("disables diff mode on source window", function()
			local buf = helpers.create_buf({ "line 1", "line 2" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)
			assert.is_true(vim.wo[source_win].diff)

			preview.close_preview()

			assert.is_false(vim.wo[source_win].diff)
		end)
	end)
end)
