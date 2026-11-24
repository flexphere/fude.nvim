local config = require("fude.config")
local all_diffs = require("fude.all_diffs")
local helpers = require("tests.helpers")

describe("all_diffs", function()
	describe("parse_patch_rows", function()
		it("returns no rows for nil or a patch without hunks", function()
			assert.same({}, all_diffs.parse_patch_rows(nil))
			assert.same({}, all_diffs.parse_patch_rows(""))
		end)

		it("puts context lines on both sides with their own line numbers", function()
			local rows = all_diffs.parse_patch_rows("@@ -10,2 +20,2 @@\n a\n b")
			assert.equals("hunk", rows[1].kind)
			assert.equals(20, rows[1].lnum)
			assert.same({ kind = "context", left = "a", right = "a", old_lnum = 10, new_lnum = 20, lnum = 20 }, rows[2])
			assert.same({ kind = "context", left = "b", right = "b", old_lnum = 11, new_lnum = 21, lnum = 21 }, rows[3])
		end)

		it("pairs removed lines with the added lines that follow and leaves the shorter side nil", function()
			local rows = all_diffs.parse_patch_rows("@@ -1,2 +1,3 @@\n-old\n+new1\n+new2\n keep")
			assert.same({ kind = "change", left = "old", right = "new1", old_lnum = 1, new_lnum = 1, lnum = 1 }, rows[2])
			assert.same({ kind = "change", right = "new2", new_lnum = 2, lnum = 2 }, rows[3])
			assert.same({ kind = "context", left = "keep", right = "keep", old_lnum = 2, new_lnum = 3, lnum = 3 }, rows[4])
		end)

		it("jumps from a deletion-only row to the head line after it", function()
			local rows = all_diffs.parse_patch_rows("@@ -1,3 +1,1 @@\n a\n-b\n-c")
			assert.same({ kind = "change", left = "b", old_lnum = 2, lnum = 2 }, rows[3])
			assert.same({ kind = "change", left = "c", old_lnum = 3, lnum = 2 }, rows[4])
		end)

		it("starts a new pair block when a removal follows additions", function()
			local rows = all_diffs.parse_patch_rows("@@ -1,2 +1,2 @@\n-a\n+A\n-b\n+B")
			assert.equals(3, #rows)
			assert.equals("a", rows[2].left)
			assert.equals("A", rows[2].right)
			assert.equals("b", rows[3].left)
			assert.equals("B", rows[3].right)
		end)

		it("skips the no-newline marker and reads every hunk", function()
			local rows = all_diffs.parse_patch_rows("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n@@ -9 +9 @@\n c")
			assert.equals(4, #rows)
			assert.equals("a", rows[2].left)
			assert.equals("b", rows[2].right)
			assert.equals("hunk", rows[3].kind)
			assert.equals(9, rows[4].new_lnum)
		end)

		it("jumps from the hunk of a file added from nothing (+0) to line 1", function()
			local rows = all_diffs.parse_patch_rows("@@ -1 +0,0 @@\n-gone")
			assert.equals(1, rows[1].lnum)
			assert.equals(1, rows[2].lnum)
		end)
	end)

	describe("format_file_header", function()
		it("shows the status label, the path and the line counts", function()
			assert.equals(
				"M lua/a.lua  +3 -1",
				all_diffs.format_file_header({ path = "lua/a.lua", status = "modified", additions = 3, deletions = 1 })
			)
		end)

		it("shows a rename as old → new and an unknown status as ?", function()
			assert.equals(
				"R old.lua → new.lua  +0 -0",
				all_diffs.format_file_header({ path = "new.lua", previous_path = "old.lua", status = "renamed" })
			)
			assert.equals("? x  +0 -0", all_diffs.format_file_header({ path = "x", status = "weird" }))
		end)
	end)

	describe("build_rows", function()
		it("starts each file with a header row, separates files and records each file's row range", function()
			local rows, ranges = all_diffs.build_rows({
				{ path = "a", status = "modified", patch = "@@ -1 +1 @@\n-x\n+y" },
				{ path = "b", status = "added", patch = "" },
			})
			assert.same(
				{ "file", "hunk", "change", "blank", "file", "note" },
				vim.tbl_map(function(r)
					return r.kind
				end, rows)
			)
			assert.equals(all_diffs.NO_DIFF_TEXT, rows[6].left)
			assert.same({ { first = 1, last = 3 }, { first = 5, last = 6 } }, ranges)
			assert.equals(1, rows[4].file_index)
			assert.equals(2, rows[6].file_index)
		end)

		it("makes both sides the same number of lines, with fillers as empty lines", function()
			local rows = all_diffs.build_rows({ { path = "a", status = "modified", patch = "@@ -1 +1,2 @@\n-x\n+y\n+z" } })
			local left, right = all_diffs.build_buffer_lines(rows)
			assert.equals(#left, #right)
			assert.same({ "M a  +0 -0", "@@ -1 +1,2 @@", "x", "" }, left)
			assert.same({ "M a  +0 -0", "@@ -1 +1,2 @@", "y", "z" }, right)
		end)
	end)

	describe("row_highlights", function()
		it("colours removed/added sides and marks the missing side as a filler", function()
			local l, r, lf, rf = all_diffs.row_highlights({ kind = "change", right = "z" })
			assert.is_nil(l)
			assert.equals(all_diffs.HL.add, r)
			assert.is_true(lf)
			assert.is_false(rf)
			l, r = all_diffs.row_highlights({ kind = "change", left = "a", right = "b" })
			assert.equals(all_diffs.HL.delete, l)
			assert.equals(all_diffs.HL.add, r)
		end)

		it("leaves context rows uncoloured", function()
			assert.same({ nil, nil, false, false }, { all_diffs.row_highlights({ kind = "context" }) })
		end)
	end)

	describe("tokenize", function()
		it("splits words, whitespace and punctuation with byte columns", function()
			local tokens = all_diffs.tokenize("foo(bar, 1)")
			assert.same(
				{ "foo", "(", "bar", ",", " ", "1", ")" },
				vim.tbl_map(function(t)
					return t.text
				end, tokens)
			)
			assert.equals(4, tokens[3].start)
		end)

		it("keeps a multibyte run as one token", function()
			local tokens = all_diffs.tokenize("a 日本")
			assert.equals("日本", tokens[3].text)
			assert.equals(2, tokens[3].start)
		end)
	end)

	describe("find_inline_ranges", function()
		it("marks only the changed word on each side", function()
			local old_ranges, new_ranges = all_diffs.find_inline_ranges('local y = "old"', 'local y = "new"')
			assert.same({ { 11, 14 } }, old_ranges)
			assert.same({ { 11, 14 } }, new_ranges)
		end)

		it("marks an insertion on the new side only", function()
			local old_ranges, new_ranges = all_diffs.find_inline_ranges("f(a)", "f(a, b)")
			assert.same({}, old_ranges)
			assert.same({ { 3, 6 } }, new_ranges)
		end)

		it("marks nothing when the lines share no token, are equal, or one is empty", function()
			assert.same({ {}, {} }, { all_diffs.find_inline_ranges("abc", "xyz") })
			assert.same({ {}, {} }, { all_diffs.find_inline_ranges("same", "same") })
			assert.same({ {}, {} }, { all_diffs.find_inline_ranges("", "x") })
		end)
	end)

	describe("build_syntax_source", function()
		it("joins one side's code lines of a file and maps them to buffer rows", function()
			local rows, ranges = all_diffs.build_rows({
				{ path = "a.lua", status = "modified", patch = "@@ -1,2 +1,2 @@\n local a\n-x\n+y" },
			})
			local left, left_map = all_diffs.build_syntax_source(rows, ranges[1], "left")
			local right, right_map = all_diffs.build_syntax_source(rows, ranges[1], "right")
			assert.equals("local a\nx", left)
			assert.same({ 3, 4 }, left_map)
			assert.equals("local a\ny", right)
			assert.same({ 3, 4 }, right_map)
		end)

		it("leaves out filler rows of that side", function()
			local rows, ranges = all_diffs.build_rows({
				{ path = "a.lua", status = "modified", patch = "@@ -1 +1,2 @@\n-x\n+y\n+z" },
			})
			local left, left_map = all_diffs.build_syntax_source(rows, ranges[1], "left")
			assert.equals("x", left)
			assert.same({ 3 }, left_map)
		end)
	end)

	describe("find_jump_target", function()
		local files = {
			{ path = "a.lua", status = "modified", patch = "@@ -1,2 +5,2 @@\n ctx\n-x\n+y" },
			{ path = "gone.lua", status = "removed", patch = "@@ -1 +0,0 @@\n-x" },
		}
		local rows = all_diffs.build_rows(files)

		it("jumps from a code row to its head line and from the file header to the first hunk", function()
			assert.same({ file = files[1], lnum = 5 }, all_diffs.find_jump_target(rows, files, 3))
			assert.same({ file = files[1], lnum = 6 }, all_diffs.find_jump_target(rows, files, 4))
			assert.same({ file = files[1], lnum = 5 }, all_diffs.find_jump_target(rows, files, 1))
		end)

		it("jumps from a separator to the file above", function()
			assert.same({ file = files[1], lnum = 5 }, all_diffs.find_jump_target(rows, files, 5))
		end)

		it("refuses a removed file and a row without a file", function()
			local target, reason = all_diffs.find_jump_target(rows, files, 7)
			assert.is_nil(target)
			assert.equals("gone.lua was removed", reason)
			target, reason = all_diffs.find_jump_target({ { kind = "note" } }, files, 1)
			assert.is_nil(target)
			assert.equals("No file on this line", reason)
		end)
	end)

	describe("format_line_number / calculate_number_width", function()
		it("shows the old number on the left, the new one on the right and blanks a filler side", function()
			local row = { old_lnum = 7, new_lnum = 12 }
			assert.equals(" 7", all_diffs.format_line_number(row, "left", 2))
			assert.equals("12", all_diffs.format_line_number(row, "right", 2))
			assert.equals("  ", all_diffs.format_line_number({ new_lnum = 3 }, "left", 2))
			assert.equals("  ", all_diffs.format_line_number(nil, "right", 2))
		end)

		it("sizes the column by the widest number, at least 2", function()
			assert.equals(2, all_diffs.calculate_number_width({ { old_lnum = 1 } }))
			assert.equals(3, all_diffs.calculate_number_width({ { old_lnum = 9 }, { new_lnum = 120 } }))
		end)
	end)

	describe("view", function()
		local notifications
		local tmpdir

		local function start_session(files)
			config.setup({})
			-- reset_state() gives a new state table, as a stop → start does.
			config.reset_state()
			config.state.active = true
			config.state.changed_files = files
		end

		before_each(function()
			notifications = {}
			helpers.mock(vim, "notify", function(msg, level)
				table.insert(notifications, { msg = msg, level = level })
			end)
			tmpdir = vim.fn.resolve(vim.fn.tempname())
			vim.fn.mkdir(tmpdir, "p")
			vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, tmpdir .. "/a.lua")
			helpers.mock(require("fude.diff"), "get_repo_root", function()
				return tmpdir
			end)
			start_session({
				{
					path = "a.lua",
					status = "modified",
					additions = 1,
					deletions = 1,
					patch = "@@ -1,3 +1,3 @@\n local a = 1\n-local b = 0\n+local b = 2\n local c = 3",
				},
			})
		end)

		after_each(function()
			all_diffs.close()
			vim.cmd("silent! tabonly")
			helpers.cleanup()
			vim.fn.delete(tmpdir, "rf")
		end)

		it("opens a new tab with two scroll-bound windows of the same length", function()
			local tabs_before = #vim.api.nvim_list_tabpages()
			all_diffs.open()
			assert.is_true(all_diffs.is_open())
			assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
			local wins = vim.api.nvim_tabpage_list_wins(0)
			assert.equals(2, #wins)
			local left_buf, right_buf = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2])
			assert.equals(vim.api.nvim_buf_line_count(left_buf), vim.api.nvim_buf_line_count(right_buf))
			assert.equals("local b = 0", vim.api.nvim_buf_get_lines(left_buf, 3, 4, false)[1])
			assert.equals("local b = 2", vim.api.nvim_buf_get_lines(right_buf, 3, 4, false)[1])
			for _, win in ipairs(wins) do
				assert.is_true(vim.wo[win].scrollbind)
				assert.is_true(vim.wo[win].cursorbind)
				assert.is_false(vim.wo[win].wrap)
			end
		end)

		it("highlights the changed word and the code syntax", function()
			all_diffs.open()
			local right_buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[2])
			local groups = {}
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(right_buf, -1, 0, -1, { details = true })) do
				if mark[4].hl_group then
					groups[mark[4].hl_group] = true
				end
			end
			assert.is_true(groups[all_diffs.HL.add_text])
			assert.is_true(groups["@keyword.lua"])
		end)

		it("closes the whole view when one of its windows is closed", function()
			all_diffs.open()
			vim.cmd("close")
			assert.is_true(helpers.wait_for(function()
				return not all_diffs.is_open()
			end, 1000))
		end)

		it("gives windows it cannot close (the view tab is the last one) their own options back", function()
			all_diffs.open()
			local wins = vim.api.nvim_tabpage_list_wins(0)
			vim.cmd("tabonly")
			all_diffs.close()
			assert.is_false(all_diffs.is_open())
			for _, win in ipairs(wins) do
				if vim.api.nvim_win_is_valid(win) then
					assert.is_false(vim.wo[win].scrollbind)
					assert.is_false(vim.wo[win].cursorbind)
					assert.equals(vim.go.statuscolumn, vim.wo[win].statuscolumn)
				end
			end
		end)

		it("shows ordinary line numbers for another buffer opened in a view window", function()
			all_diffs.open()
			local win = vim.api.nvim_get_current_win()
			local other = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_win_set_buf(win, other)
			vim.g.statusline_winid = win
			assert.equals("%l ", all_diffs.statuscolumn())
			vim.g.statusline_winid = nil
		end)

		it("q closes the tab", function()
			local tabs_before = #vim.api.nvim_list_tabpages()
			all_diffs.open()
			vim.api.nvim_feedkeys("q", "x", false)
			assert.is_false(all_diffs.is_open())
			assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
		end)

		it("<CR> opens the file at the row's head line in the original tab", function()
			local origin_tab = vim.api.nvim_get_current_tabpage()
			all_diffs.open()
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			all_diffs.jump()
			assert.equals(origin_tab, vim.api.nvim_get_current_tabpage())
			assert.equals(tmpdir .. "/a.lua", vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
			assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
			vim.cmd("silent! bwipeout!")
		end)

		it("re-running open focuses and rebuilds the view from the current scope", function()
			all_diffs.open()
			local tab = vim.api.nvim_get_current_tabpage()
			vim.cmd("tabprevious")
			config.state.changed_files = {
				{ path = "b.lua", status = "added", patch = "@@ -0,0 +1 @@\n+new" },
			}
			all_diffs.open()
			assert.equals(tab, vim.api.nvim_get_current_tabpage())
			local right_buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[2])
			assert.equals("A b.lua  +0 -0", vim.api.nvim_buf_get_lines(right_buf, 0, 1, false)[1])
		end)

		it("replaces the view of a stopped session instead of reusing it", function()
			all_diffs.open()
			local old_tab = vim.api.nvim_get_current_tabpage()
			vim.cmd("tabprevious")
			start_session({ { path = "c.lua", status = "added", patch = "@@ -0,0 +1 @@\n+c" } })
			all_diffs.open()
			assert.is_false(vim.api.nvim_tabpage_is_valid(old_tab))
			assert.is_true(all_diffs.is_open())
		end)

		it("refuses R and <CR> once the session the view was opened in has ended", function()
			all_diffs.open()
			config.reset_state()
			all_diffs.refresh()
			all_diffs.jump()
			assert.equals(2, #notifications)
			assert.truthy(notifications[1].msg:find("has ended"))
		end)

		it("reads local review patches with one git diff and falls back per file only for the rest", function()
			local diff = require("fude.diff")
			local batch_calls, single_paths = 0, {}
			helpers.mock(diff, "get_review_patches", function(base_sha, cwd)
				batch_calls = batch_calls + 1
				assert.equals("base123", base_sha)
				assert.equals(tmpdir, cwd)
				return { ["a.lua"] = "@@ -1 +1 @@\n-old\n+new" }
			end)
			helpers.mock(diff, "get_review_patch", function(_, path)
				table.insert(single_paths, path)
				return "@@ -0,0 +1 @@\n+untracked"
			end)
			config.state.review_mode = "local"
			config.state.local_session = { base_sha = "base123", worktree_root = tmpdir }
			config.state.changed_files = {
				{ path = "a.lua", status = "modified" },
				{ path = "u.lua", status = "added" },
			}
			all_diffs.open()
			assert.equals(1, batch_calls)
			assert.same({ "u.lua" }, single_paths)
			local right_buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[2])
			local lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
			assert.equals("new", lines[3])
			assert.equals("untracked", lines[7])
		end)

		it("is closed by :FudeReviewStop", function()
			all_diffs.open()
			require("fude").stop()
			assert.is_false(all_diffs.is_open())
		end)

		it("warns and opens nothing outside a review", function()
			config.state.active = false
			all_diffs.open()
			assert.is_false(all_diffs.is_open())
			assert.equals(vim.log.levels.WARN, notifications[1].level)
		end)
	end)
end)
