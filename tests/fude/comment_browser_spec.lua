local config = require("fude.config")
local data = require("fude.comments.data")
local browser_mod = require("fude.ui.comment_browser")
local helpers = require("tests.helpers")

local function press(buf, key)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == key then
			map.callback()
			return
		end
	end
	error("Missing mapping: " .. key)
end

describe("comment browser independent threads", function()
	after_each(function()
		browser_mod.close()
		helpers.cleanup()
	end)

	for _, mode in ipairs({ "github", "local" }) do
		it("routes selection, reply, edit and delete to one thread in " .. mode .. " mode", function()
			config.setup({ drafts = { enabled = false } })
			config.state.active = true
			config.state.review_mode = mode
			config.state.pr_number = 42
			config.state.github_user = "me"
			config.state.comments = {
				{ id = 1, path = "a.lua", line = 20, body = "single", user = { login = "me" }, created_at = "2026-01-01" },
				{
					id = 2,
					path = "a.lua",
					line = 20,
					start_line = 15,
					body = "range",
					user = { login = "me" },
					created_at = "2026-01-02",
				},
			}
			config.state.comment_map = data.build_comment_map(config.state.comments)
			helpers.mock(require("fude.diff"), "get_repo_root", function()
				return "/repo"
			end)
			helpers.mock(require("fude.comments.sync"), "fetch_pr_level_comments", function(_, cb)
				cb({})
			end)
			helpers.mock(vim, "notify", function() end)
			helpers.mock(vim.ui, "select", function(_, _, cb)
				cb("Yes")
			end)
			local backend = require(mode == "local" and "fude.comments.local_sync" or "fude.comments.sync")
			local replied, edited, deleted
			helpers.mock(backend, "reply_to_comment", function(id)
				replied = id
			end)
			helpers.mock(backend, "edit_comment", function(id)
				edited = id
			end)
			helpers.mock(backend, "delete_comment", function(id)
				deleted = id
			end)
			browser_mod.open()
			local browser = config.state.comment_browser
			assert.are.equal(2, #browser.entries)
			assert.are.equal(2, browser.entries[1].comments[1].id)
			local body = table.concat(vim.api.nvim_buf_get_lines(browser.upper_buf, 0, -1, false), "\n")
			assert.is_truthy(body:find("range", 1, true))
			assert.is_nil(body:find("single", 1, true))
			vim.api.nvim_buf_set_lines(browser.lower_buf, 0, -1, false, { "reply" })
			press(browser.lower_buf, "<CR>")
			assert.are.equal(2, replied)
			press(browser.upper_buf, "e")
			press(browser.lower_buf, "<CR>")
			assert.are.equal(2, edited)
			press(browser.upper_buf, "d")
			assert.are.equal(2, deleted)
			vim.api.nvim_set_current_win(browser.left_win)
			vim.api.nvim_win_set_cursor(browser.left_win, { 2, 0 })
			vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.left_buf })
			body = table.concat(vim.api.nvim_buf_get_lines(browser.upper_buf, 0, -1, false), "\n")
			assert.is_truthy(body:find("single", 1, true))
			assert.is_nil(body:find("range", 1, true))
			press(browser.upper_buf, "d")
			assert.are.equal(1, deleted)
			-- The earliest surviving reply has no position and is absent from the
			-- inline map. Reply routing must use the selected thread's data.
			config.state.comments = {
				{ id = 3, in_reply_to_id = 2, path = "a.lua", line = vim.NIL, body = "first reply", created_at = "2026-01-03" },
				{ id = 4, in_reply_to_id = 2, path = "a.lua", line = 20, body = "second reply", created_at = "2026-01-04" },
			}
			config.state.comment_map = data.build_comment_map(config.state.comments)
			press(browser.left_buf, "R")
			assert.are.equal(1, #browser.entries)
			assert.are.equal(3, browser.entries[1].comments[1].id)
			replied = nil
			press(browser.lower_buf, "<CR>")
			assert.are.equal(2, replied)
			local opened, jumped
			helpers.mock(vim, "cmd", function(cmd)
				opened = cmd
			end)
			helpers.mock(vim.api, "nvim_win_set_cursor", function(_, pos)
				jumped = pos[1]
			end)
			helpers.mock(require("fude.comments"), "view_comments", function() end)
			helpers.mock(require("fude.ui"), "flash_line", function() end)
			press(browser.left_buf, "<CR>")
			assert.are.equal("edit /repo/a.lua", opened)
			assert.are.equal(20, jumped)
			assert.is_nil(config.state.comment_browser)
		end)
	end
end)
