local helpers = require("tests.helpers")
local config = require("fude.config")
local sidepanel = require("fude.ui.sidepanel")

describe("sidepanel integration", function()
	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.pr_number = 1
		config.state.base_ref = "main"
		config.state.head_ref = "feat/test"
		config.state.changed_files = {
			{ path = "a.lua", status = "modified", additions = 5, deletions = 2 },
		}
		config.state.pr_commits = {}
		config.state.viewed_files = {}
		config.state.reviewed_commits = {}
		config.state.comments = {}
		config.state.pending_comments = {}

		local diff = require("fude.diff")
		helpers.mock(diff, "get_repo_root", function()
			return "/mock/repo"
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("open creates window and sets state.sidepanel", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		assert.is_not_nil(panel)
		assert.is_not_nil(panel.win)
		assert.is_not_nil(panel.buf)
		assert.is_true(vim.api.nvim_win_is_valid(panel.win))
		assert.is_true(vim.api.nvim_buf_is_valid(panel.buf))
	end)

	it("open sets window options", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		assert.is_false(vim.wo[panel.win].number)
		assert.is_true(vim.wo[panel.win].winfixwidth)
		assert.is_true(vim.wo[panel.win].cursorline)
		assert.is_false(vim.wo[panel.win].wrap)
	end)

	it("open uses the default sidepanel keymaps", function()
		sidepanel.open()
		local mappings = vim.api.nvim_buf_get_keymap(config.state.sidepanel.buf, "n")
		local lhs_by_desc = {}
		for _, mapping in ipairs(mappings) do
			lhs_by_desc[mapping.desc] = mapping.lhs
		end

		assert.are.equal("<CR>", lhs_by_desc["Select scope or open file"])
		assert.are.equal("<Tab>", lhs_by_desc["Toggle reviewed/viewed"])
		assert.are.equal("t", lhs_by_desc["Toggle tree/flat file list"])
		assert.are.equal("R", lhs_by_desc["Reload review data"])
		assert.are.equal("q", lhs_by_desc["Close side panel"])
	end)

	it("open uses customized sidepanel keymaps and allows disabling mappings", function()
		config.setup({
			sidepanel = {
				keymaps = {
					toggle_reviewed = "v",
					reload = false,
				},
			},
		})
		config.state.active = true
		sidepanel.open()
		local mappings = vim.api.nvim_buf_get_keymap(config.state.sidepanel.buf, "n")
		local lhs_by_desc = {}
		for _, mapping in ipairs(mappings) do
			lhs_by_desc[mapping.desc] = mapping.lhs
		end

		assert.are.equal("v", lhs_by_desc["Toggle reviewed/viewed"])
		assert.is_nil(lhs_by_desc["Reload review data"])
	end)

	it("open ignores non-table sidepanel keymaps", function()
		for _, keymaps in ipairs({ false, "invalid", 42 }) do
			config.setup({ sidepanel = { keymaps = keymaps } })
			config.state.active = true

			assert.has_no.errors(sidepanel.open)
			local mappings = vim.api.nvim_buf_get_keymap(config.state.sidepanel.buf, "n")
			assert.are.equal(0, #mappings)
			sidepanel.close()
		end
	end)

	it("open renders scope and files sections", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
		-- Should have scope header, separator, at least full PR entry, blank, files header, separator, file entry
		assert.is_true(#lines >= 7)
		assert.truthy(lines[1]:find("Review Scope"))
		-- Find files section
		local found_files = false
		for _, line in ipairs(lines) do
			if line:find("Files") then
				found_files = true
				break
			end
		end
		assert.is_true(found_files)
	end)

	it("close removes window and clears state.sidepanel", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		local win = panel.win
		assert.is_true(vim.api.nvim_win_is_valid(win))

		sidepanel.close()
		assert.is_nil(config.state.sidepanel)
		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)

	it("close is safe to call when no panel is open", function()
		assert.is_nil(config.state.sidepanel)
		sidepanel.close() -- should not error
		assert.is_nil(config.state.sidepanel)
	end)

	it("toggle opens when closed and closes when open", function()
		assert.is_nil(config.state.sidepanel)

		sidepanel.toggle()
		assert.is_not_nil(config.state.sidepanel)
		local win = config.state.sidepanel.win
		assert.is_true(vim.api.nvim_win_is_valid(win))

		sidepanel.toggle()
		assert.is_nil(config.state.sidepanel)
		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)

	it("open does nothing when not active", function()
		config.state.active = false
		sidepanel.open()
		assert.is_nil(config.state.sidepanel)
	end)

	it("refresh updates buffer content", function()
		sidepanel.open()
		local panel = config.state.sidepanel

		-- Add a file to changed_files
		table.insert(config.state.changed_files, {
			path = "b.lua",
			status = "added",
			additions = 10,
			deletions = 0,
		})

		sidepanel.refresh()

		local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
		local found_b = false
		for _, line in ipairs(lines) do
			if line:find("b.lua") then
				found_b = true
				break
			end
		end
		assert.is_true(found_b)
	end)

	it("refresh preserves cursor position", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		vim.api.nvim_set_current_win(panel.win)
		pcall(vim.api.nvim_win_set_cursor, panel.win, { 3, 0 })

		sidepanel.refresh()

		local cursor = vim.api.nvim_win_get_cursor(panel.win)
		assert.are.equal(3, cursor[1])
	end)

	it("refresh clamps cursor when content shrinks", function()
		-- Start with multiple files
		config.state.changed_files = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
			{ path = "b.lua", status = "modified", additions = 1, deletions = 0 },
			{ path = "c.lua", status = "modified", additions = 1, deletions = 0 },
		}
		sidepanel.open()
		local panel = config.state.sidepanel
		vim.api.nvim_set_current_win(panel.win)
		local line_count = vim.api.nvim_buf_line_count(panel.buf)
		pcall(vim.api.nvim_win_set_cursor, panel.win, { line_count, 0 })

		-- Remove files
		config.state.changed_files = {}
		sidepanel.refresh()

		local new_count = vim.api.nvim_buf_line_count(panel.buf)
		local cursor = vim.api.nvim_win_get_cursor(panel.win)
		assert.is_true(cursor[1] <= new_count)
	end)

	it("open closes existing panel before creating new one", function()
		sidepanel.open()
		local first_win = config.state.sidepanel.win

		sidepanel.open()
		local second_win = config.state.sidepanel.win

		assert.is_false(vim.api.nvim_win_is_valid(first_win))
		assert.is_true(vim.api.nvim_win_is_valid(second_win))
	end)

	it("section_map is populated after open", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		assert.is_not_nil(panel.section_map)
		assert.is_not_nil(panel.section_map.scope_start)
		assert.is_not_nil(panel.section_map.files_start)
	end)

	it("scope_entries and file_entries are populated after open", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		-- At minimum, full PR scope entry
		assert.is_true(#panel.scope_entries >= 1)
		-- One changed file
		assert.are.equal(1, #panel.file_entries)
	end)

	it("find_target_window prefers the source window over the preview", function()
		local source_win = vim.api.nvim_get_current_win()
		local preview_buf = helpers.create_buf()
		vim.cmd("vsplit")
		local preview_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(preview_win, preview_buf)
		config.state.source_win = source_win
		config.state.preview_win = preview_win
		sidepanel.open()

		assert.are.equal(source_win, sidepanel.find_target_window(config.state.sidepanel.win))
	end)

	it("find_target_window never falls back to the preview window", function()
		local source_win = vim.api.nvim_get_current_win()
		local preview_buf = helpers.create_buf()
		vim.cmd("vsplit")
		local preview_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(preview_win, preview_buf)
		config.state.source_win = source_win
		config.state.preview_win = preview_win
		sidepanel.open()
		local panel_win = config.state.sidepanel.win
		config.state.source_win = 999999
		helpers.mock(vim.api, "nvim_tabpage_list_wins", function()
			return { panel_win, preview_win }
		end)

		assert.is_nil(sidepanel.find_target_window(panel_win))
	end)

	it("find_target_window ignores a valid source window outside the current tab", function()
		local source_win = vim.api.nvim_get_current_win()
		local preview_buf = helpers.create_buf()
		vim.cmd("vsplit")
		local preview_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(preview_win, preview_buf)
		config.state.source_win = source_win
		config.state.preview_win = preview_win
		sidepanel.open()
		local panel_win = config.state.sidepanel.win
		helpers.mock(vim.api, "nvim_tabpage_list_wins", function()
			return { panel_win, preview_win }
		end)

		assert.is_nil(sidepanel.find_target_window(panel_win))
	end)

	it("open_file keeps the panel when no target window is available", function()
		local panel = { win = 10 }
		helpers.mock(sidepanel, "find_target_window", function()
			return nil
		end)
		local command
		helpers.mock(vim, "cmd", function(cmd)
			command = cmd
		end)
		local notification
		helpers.mock(vim, "notify", function(msg)
			notification = msg
		end)

		sidepanel.open_file(panel, "/repo/a.lua")

		assert.is_nil(command)
		assert.are.equal("fude.nvim: No source window available", notification)
	end)

	it("uses flat files by default", function()
		config.state.changed_files = {
			{ path = "a/b.lua", status = "modified", additions = 1, deletions = 0 },
		}
		sidepanel.open()
		local panel = config.state.sidepanel
		local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)

		assert.is_nil(panel.tree_entries)
		assert.are.equal("flat", panel.file_tree_mode)
		assert.is_false(vim.tbl_contains(lines, "a"))
	end)

	it("uses tree files when configured", function()
		config.setup({ sidepanel = { file_tree = "tree" } })
		config.state.active = true
		config.state.pr_number = 1
		config.state.base_ref = "main"
		config.state.head_ref = "feat/test"
		config.state.changed_files = {
			{ path = "a/b.lua", status = "modified", additions = 1, deletions = 0 },
		}
		config.state.pr_commits = {}
		config.state.viewed_files = {}
		config.state.reviewed_commits = {}
		config.state.comments = {}
		config.state.pending_comments = {}

		sidepanel.open()
		local panel = config.state.sidepanel
		local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)

		assert.is_not_nil(panel.tree_entries)
		assert.are.equal("tree", panel.file_tree_mode)
		assert.is_true(vim.tbl_contains(lines, "a"))
	end)
end)
