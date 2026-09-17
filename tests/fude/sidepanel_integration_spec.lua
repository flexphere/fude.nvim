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

	it("open places the panel at the far left even when a right window is focused", function()
		-- Simulate the diff layout [preview][source] with the right window focused
		vim.cmd("vsplit")
		vim.cmd("wincmd l")

		sidepanel.open()

		local panel = config.state.sidepanel
		local layout = vim.fn.winlayout()
		assert.are.equal("row", layout[1])
		-- 3 leaves: a 2-window row would also pass the leftmost check even
		-- without the top-level split, hiding a regression
		assert.are.equal(3, #layout[2])
		local leftmost = layout[2][1]
		assert.are.equal("leaf", leftmost[1])
		assert.are.equal(panel.win, leftmost[2])
	end)

	it("open places the panel at the far right when position is right", function()
		config.setup({ sidepanel = { position = "right" } })
		-- Simulate the diff layout [preview][source]; vsplit leaves the new
		-- left window focused (splitright is off by default)
		vim.cmd("vsplit")

		sidepanel.open()

		local panel = config.state.sidepanel
		local layout = vim.fn.winlayout()
		assert.are.equal("row", layout[1])
		assert.are.equal(3, #layout[2])
		local rightmost = layout[2][#layout[2]]
		assert.are.equal("leaf", rightmost[1])
		assert.are.equal(panel.win, rightmost[2])
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

	it("toggle opens when closed and closes when the panel is focused", function()
		assert.is_nil(config.state.sidepanel)

		sidepanel.toggle()
		assert.is_not_nil(config.state.sidepanel)
		local win = config.state.sidepanel.win
		assert.is_true(vim.api.nvim_win_is_valid(win))
		-- open() enters the panel window, so the next toggle closes it
		assert.are.equal(win, vim.api.nvim_get_current_win())

		sidepanel.toggle()
		assert.is_nil(config.state.sidepanel)
		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)

	it("toggle focuses the panel when open but another window is focused", function()
		sidepanel.toggle()
		local panel_win = config.state.sidepanel.win
		vim.cmd("wincmd l")
		assert.are_not.equal(panel_win, vim.api.nvim_get_current_win())

		sidepanel.toggle()

		assert.are.equal(panel_win, vim.api.nvim_get_current_win())
		assert.is_not_nil(config.state.sidepanel)
		assert.is_true(vim.api.nvim_win_is_valid(panel_win))
	end)

	it("closing the focused panel returns focus to the window it was opened from", function()
		local original = vim.api.nvim_get_current_win()
		sidepanel.open()
		assert.are_not.equal(original, vim.api.nvim_get_current_win())

		sidepanel.close()

		assert.are.equal(original, vim.api.nvim_get_current_win())
	end)

	it("toggle-close returns focus to the window that last focused the panel", function()
		sidepanel.open()
		vim.cmd("wincmd l")
		local file_win = vim.api.nvim_get_current_win()

		sidepanel.toggle() -- focus the panel
		sidepanel.toggle() -- close it

		assert.are.equal(file_win, vim.api.nvim_get_current_win())
	end)

	it("close from another window leaves focus untouched", function()
		sidepanel.open()
		vim.cmd("wincmd l")
		local other = vim.api.nvim_get_current_win()

		sidepanel.close()

		assert.are.equal(other, vim.api.nvim_get_current_win())
	end)

	it("toggle reopens the panel in the current tab when it lives in another tab", function()
		sidepanel.open()
		local first_panel_win = config.state.sidepanel.win
		vim.cmd("tabnew")

		sidepanel.toggle()

		local panel = config.state.sidepanel
		assert.is_not_nil(panel)
		assert.are_not.equal(first_panel_win, panel.win)
		assert.are.equal(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(panel.win))
		assert.is_false(vim.api.nvim_win_is_valid(first_panel_win))
		vim.cmd("tabonly")
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

	-- Open the panel, focus it, and stub open_file; returns the panel and a
	-- getter for the captured filename.
	local function setup_open_first_file(file_entries)
		sidepanel.open()
		local panel = config.state.sidepanel
		panel.file_entries = file_entries
		panel.tree_entries = nil
		vim.api.nvim_set_current_win(panel.win)
		local captured = {}
		helpers.mock(sidepanel, "open_file", function(_, filename)
			captured.opened = filename
		end)
		return panel, captured
	end

	it("open_first_file opens the first flat entry", function()
		local _, captured = setup_open_first_file({
			{ path = "a.lua", filename = "/mock/repo/a.lua", status = "modified" },
			{ path = "b.lua", filename = "/mock/repo/b.lua", status = "modified" },
		})

		sidepanel.open_first_file()

		assert.are.equal("/mock/repo/a.lua", captured.opened)
	end)

	it("open_first_file skips a removed file at the top of the list", function()
		local _, captured = setup_open_first_file({
			{ path = "gone.lua", filename = "/mock/repo/gone.lua", status = "removed" },
			{ path = "b.lua", filename = "/mock/repo/b.lua", status = "modified" },
		})

		sidepanel.open_first_file()

		assert.are.equal("/mock/repo/b.lua", captured.opened)
	end)

	it("open_first_file does nothing when there are no file entries", function()
		local _, captured = setup_open_first_file({})

		sidepanel.open_first_file()

		assert.is_nil(captured.opened)
	end)

	it("open_first_file does nothing when focus has left the panel", function()
		local panel, captured = setup_open_first_file({
			{ path = "a.lua", filename = "/mock/repo/a.lua", status = "modified" },
		})
		-- Simulate the user moving away while an async scope switch is in flight
		local other_win = sidepanel.find_target_window(panel.win)
		vim.api.nvim_set_current_win(other_win)

		sidepanel.open_first_file()

		assert.is_nil(captured.opened)
	end)

	it("open_first_file does nothing when the panel is gone", function()
		local captured = {}
		helpers.mock(sidepanel, "open_file", function(_, filename)
			captured.opened = filename
		end)
		config.state.sidepanel = nil

		sidepanel.open_first_file()

		assert.is_nil(captured.opened)
	end)

	it("open_first_file does nothing when the session has ended", function()
		local _, captured = setup_open_first_file({
			{ path = "a.lua", filename = "/mock/repo/a.lua", status = "modified" },
		})
		config.state.active = false

		sidepanel.open_first_file()

		assert.is_nil(captured.opened)
	end)

	it("center_first_hunk moves the cursor to the first hunk line and centers", function()
		local buf = helpers.create_buf()
		local lines = {}
		for i = 1, 50 do
			lines[i] = "line " .. i
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_cursor(win, { 1, 0 })

		sidepanel.center_first_hunk(win, { patch = "@@ -10,3 +20,4 @@\n line\n+new" })

		assert.are.equal(20, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk clamps the hunk line to the buffer length", function()
		local buf = helpers.create_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)

		sidepanel.center_first_hunk(win, { patch = "@@ -1 +100 @@\n+x" })

		assert.are.equal(3, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk leaves the cursor alone when the entry has no patch", function()
		local buf = helpers.create_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_cursor(win, { 2, 0 })

		sidepanel.center_first_hunk(win, { patch = "" })

		assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
	end)

	local function buf_keymap(buf, lhs)
		for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if m.lhs == lhs then
				return m
			end
		end
		return nil
	end

	local function buf_keymap_desc(buf, lhs)
		local m = buf_keymap(buf, lhs)
		return m and m.desc or nil
	end

	it("registers j/k entry-navigation keymaps by default", function()
		sidepanel.open()
		local buf = config.state.sidepanel.buf
		assert.are.equal("Move to next selectable entry", buf_keymap_desc(buf, "j"))
		assert.are.equal("Move to previous selectable entry", buf_keymap_desc(buf, "k"))
	end)

	it("the j/k keymap callbacks move the cursor between entries", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		local sm = panel.section_map
		-- Invoke the registered callbacks (not move_to_adjacent_entry directly)
		-- so a broken keymap wiring fails this test
		local next_cb = buf_keymap(panel.buf, "j").callback
		local prev_cb = buf_keymap(panel.buf, "k").callback
		assert.is_function(next_cb)
		assert.is_function(prev_cb)

		vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
		next_cb()
		assert.are.equal(sm.scope_start + 1, vim.api.nvim_win_get_cursor(panel.win)[1])

		next_cb()
		local after_two = vim.api.nvim_win_get_cursor(panel.win)[1]
		assert.is_true(after_two > sm.scope_start + 1)

		prev_cb()
		assert.are.equal(sm.scope_start + 1, vim.api.nvim_win_get_cursor(panel.win)[1])
	end)

	it("disabling next_entry/prev_entry leaves j/k unmapped", function()
		config.setup({ sidepanel = { keymaps = { next_entry = false, prev_entry = false } } })
		sidepanel.open()
		local buf = config.state.sidepanel.buf
		assert.is_nil(buf_keymap_desc(buf, "j"))
		assert.is_nil(buf_keymap_desc(buf, "k"))
	end)

	it("resolves a key collision in the documented action order", function()
		-- doc/fude.txt lists select before close, so select must win the key
		config.setup({ sidepanel = { keymaps = { select = "q", close = "q" } } })
		sidepanel.open()
		local buf = config.state.sidepanel.buf
		assert.are.equal("Select scope or open file", buf_keymap_desc(buf, "q"))
	end)

	it("an explicitly remapped action keeps its key over a later default", function()
		-- A user who mapped select to "j" before next_entry existed must not
		-- have it silently overwritten by the new default
		config.setup({ sidepanel = { keymaps = { select = "j" } } })
		sidepanel.open()
		local buf = config.state.sidepanel.buf
		assert.are.equal("Select scope or open file", buf_keymap_desc(buf, "j"))
		assert.are.equal("Move to previous selectable entry", buf_keymap_desc(buf, "k"))
	end)

	it("move_to_adjacent_entry skips headers and clamps at the edges", function()
		sidepanel.open()
		local panel = config.state.sidepanel
		local sm = panel.section_map

		-- From the scope header, one step down lands on the first scope entry
		vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
		sidepanel.move_to_adjacent_entry(panel, 1, 1)
		assert.are.equal(sm.scope_start + 1, vim.api.nvim_win_get_cursor(panel.win)[1])

		-- A large count clamps at the last file entry instead of overshooting
		sidepanel.move_to_adjacent_entry(panel, 1, 99)
		assert.are.equal(sm.files_end + 1, vim.api.nvim_win_get_cursor(panel.win)[1])

		-- Down at the bottom edge stays put
		sidepanel.move_to_adjacent_entry(panel, 1, 1)
		assert.are.equal(sm.files_end + 1, vim.api.nvim_win_get_cursor(panel.win)[1])

		-- Up from the first file entry skips the files header/separator/blank
		-- back to the last scope entry
		vim.api.nvim_win_set_cursor(panel.win, { sm.files_start + 1, 0 })
		sidepanel.move_to_adjacent_entry(panel, -1, 1)
		assert.are.equal(sm.scope_end + 1, vim.api.nvim_win_get_cursor(panel.win)[1])
	end)

	it("open_first_file stays silent when no target window is available", function()
		local _, captured = setup_open_first_file({
			{ path = "a.lua", filename = "/mock/repo/a.lua", status = "modified" },
		})
		helpers.mock(sidepanel, "find_target_window", function()
			return nil
		end)
		local notification
		helpers.mock(vim, "notify", function(msg)
			notification = msg
		end)

		sidepanel.open_first_file()

		assert.is_nil(captured.opened)
		assert.is_nil(notification)
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
