local config = require("fude.config")
local preview = require("fude.preview")
local helpers = require("tests.helpers")

describe("preview integration", function()
	local original_diffopt

	before_each(function()
		config.setup({})
		helpers.mock_diff({ ["source.lua"] = "source.lua", ["other.lua"] = "other.lua" })
		helpers.mock_base_content("base line 1\nbase line 2\nbase line 3\n")
	end)

	after_each(function()
		helpers.cleanup()
		if original_diffopt then
			vim.o.diffopt = original_diffopt
			original_diffopt = nil
		end
	end)

	--- Apply config.opts.diffopt globally the same way init.lua does on start.
	local function apply_default_diffopt()
		original_diffopt = vim.o.diffopt
		for _, opt in ipairs(config.opts.diffopt) do
			vim.opt.diffopt:append(opt)
		end
	end

	--- Create a test buffer that looks like a regular file buffer (buftype "") so that
	--- `should_open_preview` treats it as a review target in `on_buf_enter`.
	local function create_file_buf(lines, name)
		local buf = helpers.create_buf(lines, name)
		vim.bo[buf].buftype = ""
		return buf
	end

	--- Open a preview for a fresh test buffer and return { buf, source_win }.
	local function open_for_buffer(lines, name)
		local buf = create_file_buf(lines, name)
		local source_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(source_win, buf)

		config.state.active = true
		config.state.base_ref = "main"
		config.state.scope = "full_pr"

		preview.open_preview(source_win)
		return buf, source_win
	end

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
			assert.are.equal(3, #lines)
			assert.are.equal("base line 1", lines[1])
			assert.are.equal("base line 2", lines[2])
			assert.are.equal("base line 3", lines[3])
		end)

		it("handles base content without trailing newline", function()
			helpers.mock_base_content("no trailing newline")

			local buf = helpers.create_buf({ "current line 1" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			local lines = vim.api.nvim_buf_get_lines(config.state.preview_buf, 0, -1, false)
			assert.are.equal(1, #lines)
			assert.are.equal("no trailing newline", lines[1])
		end)

		it("preserves trailing blank lines in base content", function()
			helpers.mock_base_content("line 1\n\n")

			local buf = helpers.create_buf({ "current line 1" }, "source.lua")
			local source_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(source_win, buf)

			config.state.active = true
			config.state.base_ref = "main"
			config.state.scope = "full_pr"

			preview.open_preview(source_win)

			local lines = vim.api.nvim_buf_get_lines(config.state.preview_buf, 0, -1, false)
			assert.are.equal(2, #lines)
			assert.are.equal("line 1", lines[1])
			assert.are.equal("", lines[2])
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

		it("records the source buffer the preview was built for", function()
			local buf = open_for_buffer({ "line 1" }, "source.lua")
			assert.are.equal(buf, config.state.preview_source_buf)
		end)

		it("keeps the user's wrap setting when diffopt includes followwrap", function()
			apply_default_diffopt()
			local source_win = vim.api.nvim_get_current_win()
			vim.wo[source_win].wrap = true

			open_for_buffer({ "line 1", "line 2" }, "source.lua")

			assert.is_true(vim.wo[source_win].wrap, "Source window wrap should follow the user's setting")
			assert.is_true(vim.wo[config.state.preview_win].wrap, "Preview window wrap should follow the user's setting")
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

	describe("on_buf_enter", function()
		it("does not rebuild the preview when re-entering the same buffer", function()
			local _, source_win = open_for_buffer({ "line 1", "line 2" }, "source.lua")
			local preview_win = config.state.preview_win
			assert.is_not_nil(preview_win)

			-- Simulate the user opening folds (zR) in diff mode
			vim.wo[source_win].foldlevel = 1

			vim.api.nvim_set_current_win(source_win)
			preview.on_buf_enter()

			assert.are.equal(preview_win, config.state.preview_win, "Preview window should be reused")
			assert.is_true(vim.api.nvim_win_is_valid(preview_win))
			assert.are.equal(1, vim.wo[source_win].foldlevel, "User fold state should be preserved")
		end)

		it("rebuilds the preview when the source window switches to another buffer", function()
			local _, source_win = open_for_buffer({ "line 1", "line 2" }, "source.lua")
			local first_preview_win = config.state.preview_win

			local other_buf = create_file_buf({ "other 1" }, "other.lua")
			vim.api.nvim_win_set_buf(source_win, other_buf)
			vim.api.nvim_set_current_win(source_win)
			preview.on_buf_enter()

			assert.are.equal(other_buf, config.state.preview_source_buf)
			assert.are_not.equal(first_preview_win, config.state.preview_win, "Preview should be rebuilt")
			assert.is_false(vim.api.nvim_win_is_valid(first_preview_win))
			assert.is_true(vim.api.nvim_win_is_valid(config.state.preview_win))
		end)

		it("reopens the preview when the preview window was closed", function()
			local _, source_win = open_for_buffer({ "line 1", "line 2" }, "source.lua")
			local first_preview_win = config.state.preview_win
			vim.api.nvim_win_close(first_preview_win, true)

			vim.api.nvim_set_current_win(source_win)
			preview.on_buf_enter()

			assert.is_not_nil(config.state.preview_win)
			assert.is_true(vim.api.nvim_win_is_valid(config.state.preview_win))
		end)
	end)

	describe("close_preview", function()
		it("clears preview_source_buf", function()
			open_for_buffer({ "line 1" }, "source.lua")
			assert.is_not_nil(config.state.preview_source_buf)

			preview.close_preview()

			assert.is_nil(config.state.preview_source_buf)
		end)

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
