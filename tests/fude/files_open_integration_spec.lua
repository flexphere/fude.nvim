local files = require("fude.files")
local helpers = require("tests.helpers")

describe("first hunk helpers", function()
	after_each(helpers.cleanup)
	it("parse_first_hunk_line reads the first hunk of a GitHub-style patch", function()
		local patch = "@@ -10,3 +12,4 @@ local x\n line\n+new\n line\n@@ -30,2 +33,2 @@\n line"
		assert.are.equal(12, files.parse_first_hunk_line(patch))
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

		assert.are.equal(20, vim.api.nvim_win_get_cursor(win)[1])
	end)

	it("center_first_hunk clamps the hunk line to the buffer length", function()
		local buf = helpers.create_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)

		files.center_first_hunk(win, { patch = "@@ -1 +100 @@\n+x" })

		assert.are.equal(3, vim.api.nvim_win_get_cursor(win)[1])
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
