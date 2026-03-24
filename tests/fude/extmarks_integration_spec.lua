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

		it("sets virt_lines (not virt_text) when inline style is active", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = true
			config.state.current_comment_style = "inline"
			config.state.comment_map = {
				["test.lua"] = {
					[2] = {
						{ id = 1, body = "inline comment", user = { login = "tester" }, created_at = "2024-01-01T00:00:00Z" },
					},
				},
			}
			config.state.pending_comments = {}

			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })
			assert.is_true(#marks > 0, "Should have extmarks")

			local found_virt_lines = false
			for _, mark in ipairs(marks) do
				if mark[2] == 1 then -- 0-indexed line 1 = line 2
					local details = mark[4]
					if details.virt_lines and #details.virt_lines > 0 then
						found_virt_lines = true
						-- virt_text should NOT be set in inline mode
						assert.is_nil(details.virt_text, "Should not have virt_text in inline mode")
					end
				end
			end
			assert.is_true(found_virt_lines, "Should have virt_lines on line 2 in inline mode")
		end)

		it("does not clear extmarks on unnamed scratch buffers", function()
			-- Restore real to_repo_relative so the empty filepath guard is actually tested.
			-- The before_each mock always returns nil for unknown paths, masking the bug.
			helpers.restore_all()

			-- Simulate overview floating window buffer (unnamed, buftype=nofile)
			local scratch_buf = vim.api.nvim_create_buf(false, true)
			vim.bo[scratch_buf].buftype = "nofile"

			-- Add extmarks manually (like overview's CI check highlights)
			local ns = config.state.ns_id
			vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "line1", "line2", "line3" })
			vim.api.nvim_buf_set_extmark(scratch_buf, ns, 0, 0, {
				line_hl_group = "DiagnosticOk",
			})
			vim.api.nvim_buf_set_extmark(scratch_buf, ns, 1, 0, {
				line_hl_group = "DiagnosticError",
			})

			-- Switch to the scratch buffer (simulates Tab to right pane)
			vim.api.nvim_set_current_buf(scratch_buf)
			config.state.active = true

			extmarks.refresh_extmarks()

			-- Extmarks should still be present
			local marks = vim.api.nvim_buf_get_extmarks(scratch_buf, ns, 0, -1, {})
			assert.are.equal(2, #marks, "Extmarks on scratch buffer should not be cleared by refresh_extmarks")

			-- Cleanup
			pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
		end)

		it("marks pending comments with is_pending flag in inline mode", function()
			local buf = helpers.create_buf({ "line1", "line2", "line3" }, "test.lua")
			vim.api.nvim_set_current_buf(buf)

			config.state.active = true
			config.state.current_comment_style = "inline"
			config.state.pending_review_id = 999
			config.state.comment_map = {
				["test.lua"] = {
					[2] = {
						{
							id = 1,
							body = "pending inline comment",
							user = { login = "tester" },
							created_at = "2024-01-01T00:00:00Z",
							pull_request_review_id = 999,
						},
					},
				},
			}
			config.state.pending_comments = {}

			extmarks.refresh_extmarks()

			local marks = vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })
			assert.is_true(#marks > 0, "Should have extmarks")

			-- Check that virt_lines contain "[pending]" indicator
			local found_pending_indicator = false
			for _, mark in ipairs(marks) do
				if mark[2] == 1 and mark[4].virt_lines then
					for _, virt_line in ipairs(mark[4].virt_lines) do
						for _, chunk in ipairs(virt_line) do
							if type(chunk[1]) == "string" and chunk[1]:find("%[pending%]") then
								found_pending_indicator = true
								break
							end
						end
						if found_pending_indicator then
							break
						end
					end
				end
			end
			assert.is_true(found_pending_indicator, "Should show [pending] indicator in inline mode for pending comment")
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
