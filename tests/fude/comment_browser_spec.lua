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

describe("comment browser o key", function()
	local opened, notified
	before_each(function()
		config.setup({ drafts = { enabled = false } })
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 42
		config.state.pr_url = "https://gh/pull/42"
		config.state.comments = {
			{ id = 1, path = "a.lua", line = 3, body = "root", created_at = "2026-01-01", html_url = "https://gh/r1" },
			{
				id = 2,
				in_reply_to_id = 1,
				path = "a.lua",
				line = 3,
				body = "reply",
				created_at = "2026-01-02",
				html_url = "https://gh/r2",
			},
		}
		config.state.comment_map = data.build_comment_map(config.state.comments)
		opened, notified = {}, {}
		helpers.mock(require("fude.diff"), "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(require("fude.comments.sync"), "fetch_pr_level_comments", function(_, cb)
			cb({ { id = 9, body = "issue", created_at = "2025-12-01", html_url = "https://gh/i9" } })
		end)
		helpers.mock(vim.ui, "open", function(url)
			table.insert(opened, url)
			return {}, nil
		end)
		helpers.mock(vim, "notify", function(msg)
			table.insert(notified, msg)
		end)
	end)

	after_each(function()
		browser_mod.close()
		helpers.cleanup()
	end)

	it("opens the thread root from the list and the comment under the cursor from the thread pane", function()
		browser_mod.open()
		local browser = config.state.comment_browser
		assert.are.equal("review", browser.entries[1].type)
		press(browser.left_buf, "o")
		local lines = vim.api.nvim_buf_get_lines(browser.upper_buf, 0, -1, false)
		vim.api.nvim_win_set_cursor(browser.upper_win, { #lines, 0 })
		press(browser.upper_buf, "o")
		-- the separator between the two comments belongs to neither
		vim.api.nvim_win_set_cursor(browser.upper_win, { #lines - 2, 0 })
		press(browser.upper_buf, "o")
		assert.are.same({ "https://gh/r1", "https://gh/r2" }, opened)
		assert.are.same({ "fude.nvim: No comment under cursor" }, notified)
	end)

	it("opens the PR from the PR-level row and the PR-level comment from the thread pane", function()
		browser_mod.open()
		local browser = config.state.comment_browser
		vim.api.nvim_set_current_win(browser.left_win)
		vim.api.nvim_win_set_cursor(browser.left_win, { 2, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.left_buf })
		assert.are.equal("issue", browser.entries[2].type)
		press(browser.left_buf, "o")
		vim.api.nvim_win_set_cursor(browser.upper_win, { 1, 0 })
		press(browser.upper_buf, "o")
		assert.are.same({ "https://gh/pull/42", "https://gh/i9" }, opened)
	end)

	it("keeps the review state it was opened with after :FudeReviewStop resets the state", function()
		config.state.pending_review_id = 7
		config.state.comments[1].pull_request_review_id = 7
		config.state.comments[2].pull_request_review_id = 7
		config.state.comment_map = data.build_comment_map(config.state.comments)
		browser_mod.open()
		local browser = config.state.comment_browser
		local saved = config.state
		config.reset_state()
		press(browser.left_buf, "o")
		vim.api.nvim_win_set_cursor(browser.upper_win, { 1, 0 })
		press(browser.upper_buf, "o")
		assert.are.same({}, opened)
		local reason = "fude.nvim: Pending comments are not published on GitHub until the review is submitted"
		assert.are.same({ reason, reason }, notified)
		-- after_each closes the browser through the state it was registered in
		config.state = saved
	end)

	it("opens the PR from the PR-level row after :FudeReviewStop resets the state", function()
		browser_mod.open()
		local browser = config.state.comment_browser
		vim.api.nvim_set_current_win(browser.left_win)
		vim.api.nvim_win_set_cursor(browser.left_win, { 2, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.left_buf })
		local saved = config.state
		config.reset_state()
		press(browser.left_buf, "o")
		assert.are.same({ "https://gh/pull/42" }, opened)
		config.state = saved
	end)

	it(":FudeReviewReact in the thread pane reacts to the comment under the cursor, like +", function()
		local reactions = require("fude.reactions")
		local picked = {}
		helpers.mock(reactions, "pick", function(comment)
			table.insert(picked, comment.id)
		end)
		browser_mod.open()
		local browser = config.state.comment_browser
		local lines = vim.api.nvim_buf_get_lines(browser.upper_buf, 0, -1, false)
		vim.api.nvim_set_current_win(browser.upper_win)
		vim.api.nvim_win_set_cursor(browser.upper_win, { #lines, 0 })
		reactions.react_at_cursor()
		press(browser.upper_buf, "+")
		assert.are.same({ 2, 2 }, picked)
	end)

	it("opens nothing for a draft row from either pane and says why", function()
		helpers.mock(require("fude.drafts"), "list_drafts", function()
			return {
				{
					key = "k",
					kind = "line",
					body = "draft body",
					saved_at = "2027-01-01T00:00:00Z",
					path = "b.lua",
					end_line = 1,
				},
			}
		end)
		browser_mod.open()
		local browser = config.state.comment_browser
		local idx
		for i, e in ipairs(browser.entries) do
			if e.type == "draft" then
				idx = i
			end
		end
		vim.api.nvim_set_current_win(browser.left_win)
		vim.api.nvim_win_set_cursor(browser.left_win, { idx, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.left_buf })
		press(browser.left_buf, "o")
		vim.api.nvim_win_set_cursor(browser.upper_win, { 3, 0 })
		press(browser.upper_buf, "o")
		assert.are.same({}, opened)
		local reason = "fude.nvim: Drafts are not on GitHub until they are submitted"
		assert.are.same({ reason, reason }, notified)
	end)
end)

describe("comment browser r key", function()
	local notified
	before_each(function()
		config.setup({ drafts = { enabled = false } })
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 42
		config.state.comments = {
			{ id = 1, path = "a.lua", line = 3, body = "root", created_at = "2026-01-01" },
		}
		config.state.comment_map = data.build_comment_map(config.state.comments)
		notified = {}
		helpers.mock(require("fude.diff"), "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(require("fude.comments.sync"), "fetch_pr_level_comments", function(_, cb)
			cb({ { id = 9, body = "issue", created_at = "2025-12-01" } })
		end)
		helpers.mock(vim, "notify", function(msg)
			table.insert(notified, msg)
		end)
	end)

	after_each(function()
		browser_mod.close()
		helpers.cleanup()
	end)

	local function select_row(browser, idx)
		vim.api.nvim_set_current_win(browser.left_win)
		vim.api.nvim_win_set_cursor(browser.left_win, { idx, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = browser.left_buf })
	end

	it("focuses the Reply input from the list pane and from the thread pane", function()
		browser_mod.open()
		local browser = config.state.comment_browser
		assert.are.equal("review", browser.entries[1].type)
		vim.api.nvim_set_current_win(browser.left_win)
		press(browser.left_buf, "r")
		assert.are.equal(browser.lower_win, vim.api.nvim_get_current_win())
		assert.are.equal("reply", browser.mode)
		vim.api.nvim_set_current_win(browser.upper_win)
		press(browser.upper_buf, "r")
		assert.are.equal(browser.lower_win, vim.api.nvim_get_current_win())
		assert.are.same({}, notified)
	end)

	it("focuses the New PR Comment input on the PR-level row", function()
		browser_mod.open()
		local browser = config.state.comment_browser
		assert.are.equal("issue", browser.entries[2].type)
		select_row(browser, 2)
		press(browser.left_buf, "r")
		assert.are.equal(browser.lower_win, vim.api.nvim_get_current_win())
		assert.are.equal("new_pr_comment", browser.mode)
	end)

	it("stays put on a line draft row and says to edit it in the file", function()
		helpers.mock(require("fude.drafts"), "list_drafts", function()
			return {
				{
					key = "k",
					kind = "line",
					body = "draft body",
					saved_at = "2027-01-01T00:00:00Z",
					path = "b.lua",
					end_line = 1,
				},
			}
		end)
		browser_mod.open()
		local browser = config.state.comment_browser
		local idx
		for i, e in ipairs(browser.entries) do
			if e.type == "draft" then
				idx = i
			end
		end
		select_row(browser, idx)
		press(browser.left_buf, "r")
		assert.are.equal(browser.left_win, vim.api.nvim_get_current_win())
		vim.api.nvim_set_current_win(browser.upper_win)
		press(browser.upper_buf, "r")
		assert.are.equal(browser.upper_win, vim.api.nvim_get_current_win())
		local reason = "fude.nvim: Press <CR> to edit this draft in the file"
		assert.are.same({ reason, reason }, notified)
	end)
end)

describe("comment browser open helpers", function()
	it("find_entry_open_target picks the thread root, the PR, or explains a draft", function()
		local root = { id = 1 }
		assert.are.equal(root, (browser_mod.find_entry_open_target({ type = "review", comments = { root, { id = 2 } } })))
		assert.are.same({ nil, "u", nil }, { browser_mod.find_entry_open_target({ type = "issue" }, "u") })
		assert.are.same({ nil, nil, "No PR URL to open" }, { browser_mod.find_entry_open_target({ type = "issue" }, nil) })
		assert.are.same(
			{ nil, nil, "Drafts are not on GitHub until they are submitted" },
			{ browser_mod.find_entry_open_target({ type = "draft", kind = "line" }, "u") }
		)
		assert.are.same({ nil, nil, "No thread under cursor" }, { browser_mod.find_entry_open_target(nil, "u") })
		assert.are.same(
			{ nil, nil, "No comment under cursor" },
			{ browser_mod.find_entry_open_target({ type = "review", comments = {} }, "u") }
		)
	end)

	it("find_thread_comments lists what the thread pane shows", function()
		local c = { { id = 1 } }
		local issues = { { id = 9 } }
		assert.are.equal(c, browser_mod.find_thread_comments({ type = "review", comments = c }, issues))
		assert.are.equal(issues, browser_mod.find_thread_comments({ type = "issue" }, issues))
		assert.are.same({}, browser_mod.find_thread_comments({ type = "draft" }, issues))
		assert.are.same({}, browser_mod.find_thread_comments(nil, issues))
	end)
end)
