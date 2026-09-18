local config = require("fude.config")
local diff = require("fude.diff")
local files = require("fude.files")
local sidepanel = require("fude.ui.sidepanel")
local preview = require("fude.preview")
local helpers = require("tests.helpers")

describe("review file opening", function()
	local root, source_win, target, lines, old_options, original_buffers, center_count
	local original_cmd

	local function drain()
		local done = false
		vim.schedule(function()
			done = true
		end)
		assert.is_true(helpers.wait_for(function()
			return done
		end))
		vim.cmd("redraw")
	end

	local function press_enter(buf)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if mapping.lhs == "<CR>" then
				mapping.callback()
				return
			end
		end
		error("Missing Enter mapping")
	end

	local function current_view()
		return vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
	end

	before_each(function()
		old_options = { hidden = vim.o.hidden, scrolloff = vim.o.scrolloff }
		vim.o.hidden = true
		vim.o.scrolloff = 0
		original_buffers = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			original_buffers[buf] = true
		end
		root = vim.fn.tempname()
		vim.fn.mkdir(root .. "/nested", "p")
		root = vim.uv.fs_realpath(root)
		lines = {}
		for i = 1, 180 do
			lines[i] = "line " .. i
		end
		vim.fn.writefile(lines, root .. "/start.lua")
		local target_lines = vim.list_slice(lines)
		target_lines[103] = "changed line"
		vim.fn.writefile(target_lines, root .. "/nested/target.lua")
		vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
		source_win = vim.api.nvim_get_current_win()
		vim.wo[source_win].wrap = false
		vim.wo[source_win].foldenable = false

		config.setup({})
		config.state.active = true
		config.state.base_ref = "main"
		config.state.pr_number = 1
		config.state.head_ref = "feature"
		target = {
			path = "nested/target.lua",
			filename = root .. "/nested/target.lua",
			status = "modified",
			patch = "@@ -100,7 +100,7 @@\n line 100\n line 101\n line 102\n-old\n+new\n line 104\n line 105\n line 106",
		}
		config.state.changed_files = { target }
		helpers.mock(diff, "get_repo_root", function()
			return root
		end)
		helpers.mock(diff, "to_repo_relative", function(filename)
			return diff.make_relative(filename, root)
		end)
		helpers.mock_base_content(table.concat(lines, "\n"))
		require("fude.init").setup_review_autocmds(config.state)
		center_count = 0
		original_cmd = vim.cmd
		helpers.mock(vim, "cmd", function(cmd)
			if cmd == "normal! zz" then
				center_count = center_count + 1
			end
			return original_cmd(cmd)
		end)
	end)

	after_each(function()
		config.state.active = false
		pcall(vim.api.nvim_del_augroup_by_name, "Fude")
		require("fude.ui").teardown_inline_hint_autocmd()
		preview.close_preview()
		drain()
		helpers.cleanup()
		vim.fn.setqflist({}, "f")
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if not original_buffers[buf] or vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
		vim.fn.delete(root, "rf")
		vim.o.hidden = old_options.hidden
		vim.o.scrolloff = old_options.scrolloff
	end)

	local function set_mode(mode, patch)
		config.state.review_mode = mode
		if mode == "local" then
			config.state.pr_number = nil
			config.state.local_session = {
				base_sha = "local-base",
				base_ref = "main",
				content_ref = "local-base",
				worktree_root = root,
				scope = "base",
			}
			target.patch = nil
			helpers.mock(diff, "get_review_patch", function(base, path, cwd)
				assert.are.equal("local-base", base)
				assert.are.equal(target.path, path)
				assert.are.equal(root, cwd)
				return patch
			end)
		else
			target.patch = patch
		end
	end

	local function panel_select(mode)
		config.opts.sidepanel.file_tree = mode
		sidepanel.open()
		local panel = config.state.sidepanel
		local entries = panel.tree_entries or panel.file_entries
		for i, entry in ipairs(entries) do
			if entry.path == target.path then
				vim.api.nvim_win_set_cursor(panel.win, { panel.section_map.files_entry_offset + i, 0 })
				press_enter(panel.buf)
				return
			end
		end
		error("Missing file entry")
	end

	local routes = {
		{
			"direct",
			function()
				files.open_file(target.filename, target)
			end,
		},
		{ "next", files.next_file },
		{ "previous", files.prev_file },
		{
			"flat panel",
			function()
				panel_select("flat")
			end,
		},
		{
			"tree panel",
			function()
				panel_select("tree")
			end,
		},
		{
			"scope auto-open",
			function()
				sidepanel.open()
				sidepanel.open_first_file()
			end,
		},
		{
			"Telescope",
			function()
				local options, selected, confirm
				helpers.mock(package.loaded, "telescope.pickers", {
					new = function(_, opts)
						options = opts
						return {
							find = function()
								selected = opts.finder.results[1]
								opts.attach_mappings(0, function() end)
							end,
						}
					end,
				})
				helpers.mock(package.loaded, "telescope.finders", {
					new_table = function(opts)
						return opts
					end,
				})
				helpers.mock(package.loaded, "telescope.config", { values = { generic_sorter = function() end } })
				helpers.mock(package.loaded, "telescope.previewers", {
					new_buffer_previewer = function(opts)
						return opts
					end,
				})
				helpers.mock(package.loaded, "telescope.pickers.entry_display", {
					create = function()
						return function() end
					end,
				})
				helpers.mock(package.loaded, "telescope.actions.state", {
					get_selected_entry = function()
						return selected
					end,
				})
				helpers.mock(package.loaded, "telescope.actions", {
					select_default = {
						replace = function(_, fn)
							confirm = fn
						end,
					},
					close = function()
						selected = nil
						vim.api.nvim_set_current_win(source_win)
					end,
				})
				files.show_telescope()
				assert.is_not_nil(options)
				confirm()
			end,
		},
		{
			"snacks",
			function()
				local options
				helpers.mock(package.loaded, "snacks.picker", {
					pick = function(opts)
						options = opts
					end,
				})
				files.show_snacks()
				options.confirm({
					close = function()
						vim.api.nvim_set_current_win(source_win)
					end,
				}, options.items[1])
			end,
		},
		{
			"quickfix",
			function()
				files.show_quickfix()
				press_enter(vim.api.nvim_get_current_buf())
			end,
		},
	}

	for _, mode in ipairs({ "github", "local" }) do
		for _, route in ipairs(routes) do
			for _, case in ipairs({ "new", "existing", "no hunk" }) do
				it(mode .. " / " .. route[1] .. " / " .. case, function()
					set_mode(mode, case == "no hunk" and "" or target.patch)
					local expected
					if case == "existing" then
						vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
						vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
						vim.cmd("normal! zt")
						expected = current_view()
						vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
					end
					route[2]()
					drain()
					assert.are.equal(target.filename, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)))
					if case == "new" then
						assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
						local screen_row = vim.api.nvim_win_call(source_win, function()
							return vim.fn.winline()
						end)
						assert.is_true(math.abs(screen_row - math.ceil(vim.api.nvim_win_get_height(source_win) / 2)) <= 1)
						assert.are.equal(1, center_count)
					elseif case == "existing" then
						assert.are.same(expected, current_view())
						assert.are.equal(0, center_count)
					else
						assert.are.equal(1, vim.api.nvim_win_get_cursor(source_win)[1])
						assert.are.equal(0, center_count)
					end
				end)
			end
		end
	end

	it("does not treat an already registered unloaded buffer as new", function()
		vim.fn.bufadd(target.filename)
		files.open_file(target.filename, target)
		assert.are.equal(1, vim.api.nvim_win_get_cursor(source_win)[1])
		assert.are.equal(0, center_count)
	end)

	it("centers a quickfix-created buffer when opened through next-file instead", function()
		files.show_quickfix()
		vim.api.nvim_set_current_win(source_win)
		files.next_file()
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
		assert.are.equal(1, center_count)
	end)

	it("does not fail when quickfix cannot resolve a newly registered buffer", function()
		local original_list_bufs = vim.api.nvim_list_bufs
		local hide_target = true
		helpers.mock(vim.api, "nvim_list_bufs", function()
			local bufs = original_list_bufs()
			if not hide_target then
				return bufs
			end
			return vim.tbl_filter(function(buf)
				return vim.api.nvim_buf_get_name(buf) ~= target.filename
			end, bufs)
		end)

		local ok, err = pcall(files.show_quickfix)
		hide_target = false

		assert.is_true(ok, err)
		local buf = vim.fn.bufnr(target.filename)
		assert.are_not.equal(-1, buf)
		assert.is_nil(vim.b[buf].fude_quickfix_unopened)
	end)

	it("does not re-center a quickfix buffer read outside fude and later unloaded", function()
		files.show_quickfix()
		vim.api.nvim_set_current_win(source_win)
		vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
		vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
		vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
		vim.cmd("bunload " .. vim.fn.bufnr(target.filename))
		files.open_file(target.filename, target)
		assert.are.equal(65, vim.api.nvim_win_get_cursor(source_win)[1])
		assert.are.equal(0, center_count)
	end)

	it("opens the file when patch generation raises an error", function()
		helpers.mock(files, "resolve_patch", function()
			error("git unavailable")
		end)
		files.open_file(target.filename, target)
		assert.are.equal(target.filename, vim.api.nvim_buf_get_name(0))
		assert.are.equal(0, center_count)
	end)

	it("does not move after BufEnter has stopped the session", function()
		vim.api.nvim_create_autocmd("BufEnter", {
			group = config.state.augroup,
			once = true,
			callback = function()
				config.reset_state()
			end,
		})
		files.open_file(target.filename, target)
		assert.are.equal(0, center_count)
	end)

	it("keeps new-file positioning after preview rebuild and directory reveal", function()
		config.opts.sidepanel.file_tree = "tree"
		preview.open_preview(source_win)
		sidepanel.open()
		config.state.sidepanel.collapsed_dirs.nested = true
		sidepanel.refresh()
		vim.api.nvim_set_current_win(source_win)
		files.next_file()
		drain()
		assert.is_nil(config.state.sidepanel.collapsed_dirs.nested)
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
		assert.are.equal(1, center_count)
		assert.are.equal(vim.api.nvim_win_get_buf(source_win), config.state.preview_source_buf)
	end)

	it("keeps an existing view after preview rebuild and directory reveal", function()
		vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
		vim.api.nvim_win_set_cursor(source_win, { 100, 3 })
		vim.cmd("normal! zt")
		local expected = current_view()
		vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
		preview.open_preview(source_win)
		config.opts.sidepanel.file_tree = "tree"
		sidepanel.open()
		config.state.sidepanel.collapsed_dirs.nested = true
		sidepanel.refresh()
		vim.api.nvim_set_current_win(source_win)
		files.next_file()
		drain()
		assert.are.same(expected, current_view())
		assert.are.equal(0, center_count)
		assert.is_nil(config.state.sidepanel.collapsed_dirs.nested)
	end)

	it("keeps the quickfix selection index when opening an entry", function()
		config.state.changed_files = {
			{ path = "start.lua", status = "modified" },
			target,
		}
		files.show_quickfix()
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		press_enter(vim.api.nvim_get_current_buf())
		assert.are.equal(2, vim.fn.getqflist({ idx = 0 }).idx)
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
	end)

	it("does not position another buffer opened by an edit autocmd", function()
		vim.api.nvim_create_autocmd("BufEnter", {
			group = config.state.augroup,
			once = true,
			callback = function()
				vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
			end,
		})
		files.open_file(target.filename, target)
		assert.are.equal(root .. "/start.lua", vim.api.nvim_buf_get_name(0))
		assert.are.equal(0, center_count)
	end)

	it("handles file names containing spaces and pattern characters", function()
		local sibling = root .. "/a.lua"
		vim.fn.writefile(lines, sibling)
		vim.cmd("edit " .. vim.fn.fnameescape(sibling))
		target.filename = root .. "/[a].lua"
		vim.fn.writefile(lines, target.filename)
		files.open_file(target.filename, target)
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
		target.filename = root .. "/with spaces [b].lua"
		vim.fn.writefile(lines, target.filename)
		files.open_file(target.filename, target)
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
	end)

	it("prefers the exact buffer when a symlink alias was registered first", function()
		vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
		vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
		vim.cmd("normal! zt")
		local expected = current_view()
		vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
		local alias = root .. "/alias.lua"
		assert(vim.uv.fs_symlink(target.filename, alias))
		local alias_buf = helpers.create_buf()
		vim.b[alias_buf].fude_quickfix_unopened = true
		local original_get_name = vim.api.nvim_buf_get_name
		helpers.mock(vim.api, "nvim_buf_get_name", function(buf)
			return buf == alias_buf and alias or original_get_name(buf)
		end)
		local original_list_bufs = vim.api.nvim_list_bufs
		helpers.mock(vim.api, "nvim_list_bufs", function()
			local bufs = { alias_buf }
			vim.list_extend(
				bufs,
				vim.tbl_filter(function(buf)
					return buf ~= alias_buf
				end, original_list_bufs())
			)
			return bufs
		end)

		files.open_file(target.filename, target)

		assert.are.same(expected, current_view())
		assert.are.equal(0, center_count)
	end)

	it("continues when buffer lookup finds another alias of the opened file", function()
		vim.cmd("edit " .. vim.fn.fnameescape(target.filename))
		vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
		vim.cmd("normal! zt")
		local expected = current_view()
		vim.cmd("edit " .. vim.fn.fnameescape(root .. "/start.lua"))
		local alias = root .. "/alias.lua"
		assert(vim.uv.fs_symlink(target.filename, alias))
		local alias_buf = helpers.create_buf()
		local original_get_name = vim.api.nvim_buf_get_name
		helpers.mock(vim.api, "nvim_buf_get_name", function(buf)
			return buf == alias_buf and alias or original_get_name(buf)
		end)
		local target_buf = vim.fn.bufnr(target.filename)
		local original_list_bufs = vim.api.nvim_list_bufs
		local hide_target = true
		helpers.mock(vim.api, "nvim_list_bufs", function()
			if hide_target then
				local bufs = { alias_buf }
				vim.list_extend(
					bufs,
					vim.tbl_filter(function(buf)
						return buf ~= alias_buf and buf ~= target_buf
					end, original_list_bufs())
				)
				return bufs
			end
			return original_list_bufs()
		end)
		local preview_calls = 0
		helpers.mock(preview, "on_buf_enter", function()
			preview_calls = preview_calls + 1
		end)
		config.state.preview_win = source_win

		local ok, err = pcall(files.open_file, target.filename, target)
		hide_target = false
		config.state.preview_win = nil

		assert.is_true(ok, err)
		assert.are.equal(1, preview_calls)
		assert.are.same(expected, current_view())
	end)

	it("preserves a manually opened diff fold when returning to an existing file", function()
		files.open_file(target.filename, target)
		vim.wo.foldenable = true
		preview.open_preview(source_win)
		vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
		vim.cmd("normal! zvzt")
		local expected = current_view()
		files.open_file(root .. "/start.lua")
		files.open_file(target.filename, target)
		drain()
		assert.are.same(expected, current_view())
	end)

	it("does not center an unrelated quickfix list", function()
		files.show_quickfix()
		vim.fn.setqflist({}, " ", {
			items = { { filename = target.filename, lnum = 42 } },
			context = {},
		})
		press_enter(vim.api.nvim_get_current_buf())
		drain()
		assert.are.equal(42, vim.api.nvim_win_get_cursor(source_win)[1])
		assert.are.equal(0, center_count)
	end)

	it("uses the current scope's patch when selecting an older quickfix list", function()
		files.show_quickfix()
		config.state.changed_files =
			{ {
				path = target.path,
				status = "modified",
				patch = "@@ -125,2 +125,2 @@\n-old\n+new",
			} }
		press_enter(vim.api.nvim_get_current_buf())
		assert.are.equal(125, vim.api.nvim_win_get_cursor(source_win)[1])
	end)

	it("preserves a user's Enter mapping on unrelated quickfix lists", function()
		vim.cmd("copen")
		local called = 0
		vim.keymap.set("n", "<CR>", function()
			called = called + 1
		end, { buffer = vim.api.nvim_get_current_buf() })
		files.show_quickfix()
		files.show_quickfix()
		vim.fn.setqflist({}, " ", {
			items = { { filename = target.filename, lnum = 42 } },
		})
		press_enter(vim.api.nvim_get_current_buf())
		assert.are.equal(1, called)
		assert.are.equal(0, center_count)
	end)

	it("supports reusing the quickfix window after a review restart", function()
		files.show_quickfix()
		config.reset_state()
		config.state.active = true
		config.state.changed_files = { target }
		files.show_quickfix()
		press_enter(vim.api.nvim_get_current_buf())
		assert.are.equal(103, vim.api.nvim_win_get_cursor(source_win)[1])
	end)

	it("clears saved views when the session resets", function()
		files.save_view(vim.api.nvim_get_current_buf())
		assert.is_not_nil(next(config.state.file_views))
		config.reset_state()
		assert.are.same({}, config.state.file_views)
	end)

	it("keeps the current modified buffer and view without re-editing it", function()
		files.open_file(target.filename, target)
		vim.api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved edit" })
		vim.api.nvim_win_set_cursor(source_win, { 65, 3 })
		vim.cmd("normal! zt")
		local expected = current_view()
		center_count = 0
		files.open_file(target.filename, target)
		drain()
		assert.are.same(expected, current_view())
		assert.are.equal("unsaved edit", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
		assert.is_true(vim.bo.modified)
		assert.are.equal(0, center_count)
	end)
end)

describe("first hunk helpers", function()
	after_each(helpers.cleanup)
	it("parse_first_hunk_line reads the first hunk of a GitHub-style patch", function()
		local patch = "@@ -10,3 +12,4 @@ local x\n line\n+new\n line\n@@ -30,2 +33,2 @@\n line"
		assert.are.equal(13, files.parse_first_hunk_line(patch))
	end)

	it("skips the actual number of context lines before the first change", function()
		for _, count in ipairs({ 0, 1, 2, 3, 5 }) do
			local context = string.rep(" context\n", count)
			local patch = "@@ -10,8 +10,8 @@\n" .. context .. "-old\n+new\n context"
			assert.are.equal(10 + count, files.parse_first_hunk_line(patch))
		end
	end)

	it("positions a contextual deletion at the next surviving line", function()
		local patch = "@@ -10,5 +10,3 @@\n before\n-old\n-old2\n after\n end"
		assert.are.equal(11, files.parse_first_hunk_line(patch))
	end)

	it("keeps the anchor of a zero-context deletion", function()
		assert.are.equal(9, files.parse_first_hunk_line("@@ -10,2 +9,0 @@\n-a\n-b"))
	end)

	it("starts a new file at its first added line", function()
		assert.are.equal(1, files.parse_first_hunk_line("@@ -0,0 +1,2 @@\n+a\n+b"))
	end)

	it("does not mistake later file headers for a change in an empty hunk", function()
		local patch = "@@ -1 +1 @@\n same\ndiff --git a/next b/next\n--- a/next\n+++ b/next\n@@ -1 +1 @@\n+x"
		assert.is_nil(files.parse_first_hunk_line(patch))
	end)

	it("ignores a second hunk when the first contains no changes", function()
		assert.is_nil(files.parse_first_hunk_line("@@ -1 +1 @@\n same\n@@ -3 +3 @@\n+x"))
	end)

	it("returns nil for a header without changed lines", function()
		assert.is_nil(files.parse_first_hunk_line("@@ -1 +1 @@"))
	end)

	it("parse_first_hunk_line skips git-diff headers before the first hunk", function()
		local patch = "diff --git a/f.lua b/f.lua\nindex 111..222 100644\n--- a/f.lua\n+++ b/f.lua\n@@ -1 +5,2 @@\n+x"
		assert.are.equal(5, files.parse_first_hunk_line(patch))
	end)

	it("parse_first_hunk_line returns 0 for a leading pure-deletion hunk", function()
		assert.are.equal(0, files.parse_first_hunk_line("@@ -1,3 +0,0 @@\n-a\n-b\n-c"))
	end)

	it("parse_first_hunk_line ignores hunk-like text in diff content lines", function()
		local patch = " @@ -1 +9 @@ inside content\n+@@ -1 +9 @@ added line"
		assert.is_nil(files.parse_first_hunk_line(patch))
	end)

	it("parse_first_hunk_line returns nil for empty or non-string patches", function()
		assert.is_nil(files.parse_first_hunk_line(""))
		assert.is_nil(files.parse_first_hunk_line(nil))
		assert.is_nil(files.parse_first_hunk_line("no hunks here"))
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

		files.center_first_hunk(win, { patch = "@@ -10,3 +20,4 @@\n line\n+new" })

		assert.are.equal(21, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk clamps the hunk line to the buffer length", function()
		local buf = helpers.create_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)

		files.center_first_hunk(win, { patch = "@@ -1 +100 @@\n+x" })

		assert.are.equal(3, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("centers an end-of-file deletion on the last surviving line", function()
		local buf = helpers.create_buf({ "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		files.center_first_hunk(win, { patch = "@@ -1,4 +1,3 @@\n a\n b\n c\n-deleted" })
		assert.are.equal(3, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk clamps a leading deletion to line one", function()
		local buf = helpers.create_buf({ "remaining" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		files.center_first_hunk(win, { patch = "@@ -1,3 +0,0 @@\n-a\n-b\n-c" })
		assert.are.equal(1, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk leaves the cursor alone when the entry has no patch", function()
		local buf = helpers.create_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_cursor(win, { 2, 0 })

		files.center_first_hunk(win, { patch = "" })

		assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
	end)
end)
