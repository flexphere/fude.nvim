local config = require("fude.config")
local extmarks = require("fude.ui.extmarks")
local helpers = require("tests.helpers")

describe("extmarks integration", function()
	before_each(function()
		config.setup({})
		helpers.mock_diff({ ["test.lua"] = "test.lua" })
	end)

	after_each(function()
		helpers.cleanup()
	end)

	describe("refresh_extmarks", function()
		it("sets comment virtual text when active with comments", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = true
			config.state.comment_map = {
				["test.lua"] = {
					[2] = { { id = 1, body = "fix this" } },
				},
			}
			config.state.pending_comments = {}

			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })
			assert.is_true(#marks > 0, "Should have extmarks")

			-- The extmark should be on line 1 (0-indexed for line 2)
			local found = false
			for _, mark in ipairs(marks) do
				if mark[2] == 1 then -- 0-indexed line 1 = line 2
					found = true
					local details = mark[4]
					assert.is_not_nil(details.virt_text)
				end
			end
			assert.is_true(found, "Should have extmark on line 2")
		end)

		it("shows pending indicator for comments in comment_map with pending_review_id", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = true
			config.state.pending_review_id = 999
			config.state.comment_map = {
				["test.lua"] = {
					[2] = { { id = 1, body = "pending comment", pull_request_review_id = 999 } },
				},
			}
			config.state.pending_comments = {}

			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })
			local found_pending = false
			for _, mark in ipairs(marks) do
				if mark[2] == 1 then -- 0-indexed line 1 = line 2
					local details = mark[4]
					if details.virt_text then
						local text = details.virt_text[1][1]
						if text:find("pending", 1, true) then
							found_pending = true
						end
					end
				end
			end
			assert.is_true(found_pending, "Should show pending indicator for pending review comment in comment_map")
		end)

		it("does nothing when not active", function()
			local buf = helpers.create_buf({ "line1", "line2" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = false
			config.state.comment_map = {
				["test.lua"] = { [1] = { { id = 1, body = "comment" } } },
			}

			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, {})
			assert.are.equal(0, #marks)
		end)

		it("clears previous extmarks before setting new ones", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = true
			config.state.pending_comments = {}

			-- First call: comment on line 1
			config.state.comment_map = {
				["test.lua"] = { [1] = { { id = 1, body = "old" } } },
			}
			extmarks.refresh_extmarks()

			-- Second call: comment on line 3 (line 1 should be cleared)
			config.state.comment_map = {
				["test.lua"] = { [3] = { { id = 2, body = "new" } } },
			}
			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })
			-- Should only have marks for line 3, not line 1
			for _, mark in ipairs(marks) do
				assert.is_not.equal(0, mark[2], "Line 1 (0-indexed 0) should have been cleared")
			end
		end)
	end)

	describe("flash_line", function()
		it("creates a temporary highlight extmark", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3", "line4", "line5" }, "flash_test.lua")
			vim.api.nvim_set_current_buf(buf)

			extmarks.flash_line(3)

			local ns = config.state.ns_id
			local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
			local found = false
			for _, mark in ipairs(marks) do
				if mark[2] == 2 then -- 0-indexed line 2 = line 3
					local details = mark[4]
					if details.line_hl_group then
						found = true
					end
				end
			end
			assert.is_true(found, "Should have flash highlight on line 3")
		end)
	end)

	describe("highlight_comment_lines", function()
		it("highlights a range of lines", function()
			local buf = helpers.create_buf({ "a", "b", "c", "d", "e" }, "highlight_test.lua")
			vim.api.nvim_set_current_buf(buf)

			extmarks.highlight_comment_lines(buf, 2, 4)

			local ns = config.state.ns_id
			local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
			local highlighted_lines = {}
			for _, mark in ipairs(marks) do
				if mark[4].line_hl_group then
					table.insert(highlighted_lines, mark[2] + 1) -- convert to 1-indexed
				end
			end
			table.sort(highlighted_lines)
			assert.are.same({ 2, 3, 4 }, highlighted_lines)
		end)
	end)

	describe("clear_comment_line_highlight", function()
		it("removes highlight extmarks", function()
			local buf = helpers.create_buf({ "a", "b", "c" }, "clear_test.lua")
			vim.api.nvim_set_current_buf(buf)

			extmarks.highlight_comment_lines(buf, 1, 3)

			-- Verify highlights exist
			local ns = config.state.ns_id
			local marks_before = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
			assert.is_true(#marks_before > 0, "Should have highlights before clear")

			extmarks.clear_comment_line_highlight()

			local marks_after = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
			assert.are.equal(0, #marks_after, "Should have no highlights after clear")
		end)
	end)

	describe("clear_all_extmarks", function()
		it("clears extmarks across multiple buffers", function()
			local buf1 = helpers.create_buf({ "a", "b" }, "buf1.lua")
			local buf2 = helpers.create_buf({ "c", "d" }, "buf2.lua")

			local ns = config.state.ns_id
			vim.api.nvim_buf_set_extmark(buf1, ns, 0, 0, { virt_text = { { "mark1", "Comment" } } })
			vim.api.nvim_buf_set_extmark(buf2, ns, 0, 0, { virt_text = { { "mark2", "Comment" } } })

			-- Verify marks exist
			assert.is_true(#vim.api.nvim_buf_get_extmarks(buf1, ns, 0, -1, {}) > 0)
			assert.is_true(#vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, {}) > 0)

			extmarks.clear_all_extmarks()

			assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf1, ns, 0, -1, {}))
			assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, {}))
		end)
	end)
end)
