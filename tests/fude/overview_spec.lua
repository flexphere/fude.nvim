--- Integration tests for overview re-request review flow.
local helpers = require("tests.helpers")

describe("overview re_request_review", function()
	local config = require("fude.config")
	local overview = require("fude.overview")

	local POST_KEY = "api:repos/{owner}/{repo}/pulls/42/requested_reviewers"

	local orig_select
	local select_choice
	local notifications

	local function make_pr_info()
		return {
			number = 42,
			author = { login = "author" },
			reviewRequests = {},
			latestReviews = { { author = { login = "alice" }, state = "APPROVED" } },
		}
	end

	local function has_notification(pattern, level)
		for _, n in ipairs(notifications) do
			if n.msg:find(pattern, 1, true) and (level == nil or n.level == level) then
				return true
			end
		end
		return false
	end

	before_each(function()
		config.setup({})
		notifications = {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		orig_select = vim.ui.select
		-- vim.ui.select stub returns the configured choice.
		vim.ui.select = function(_items, _opts, on_choice)
			on_choice(select_choice, nil)
		end
	end)

	after_each(function()
		vim.ui.select = orig_select
		helpers.cleanup()
	end)

	it("posts the selected reviewer to the requested_reviewers endpoint", function()
		select_choice = { login = "alice", state = "APPROVED" }
		local captured
		helpers.mock_gh({
			[POST_KEY] = function(args, callback, stdin)
				captured = { args = args, stdin = stdin }
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})

		overview.re_request_review(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		local joined = table.concat(captured.args, " ")
		assert.is_truthy(joined:find("--method POST", 1, true))
		assert.is_truthy(joined:find("--input -", 1, true))
		assert.are.same({ reviewers = { "alice" } }, vim.json.decode(captured.stdin))
		assert.is_true(helpers.wait_for(function()
			return has_notification("Re-requested review from @alice", vim.log.levels.INFO)
		end))
	end)

	it("notifies and does not post when there are no candidates", function()
		local posted = false
		helpers.mock_gh({
			[POST_KEY] = function()
				posted = true
			end,
		})

		local pr_info = make_pr_info()
		pr_info.latestReviews = {}
		overview.re_request_review(pr_info)

		vim.wait(100, function()
			return posted
		end)
		assert.is_false(posted)
		assert.is_true(has_notification("No reviewers to re-request", vim.log.levels.INFO))
	end)

	it("does not post when selection is cancelled", function()
		select_choice = nil
		local posted = false
		helpers.mock_gh({
			[POST_KEY] = function()
				posted = true
			end,
		})

		overview.re_request_review(make_pr_info())

		vim.wait(100, function()
			return posted
		end)
		assert.is_false(posted)
	end)

	it("notifies an error when the API call fails", function()
		select_choice = { login = "alice", state = "APPROVED" }
		helpers.mock_gh({
			[POST_KEY] = "gh: Unprocessable Entity (HTTP 422)",
		})

		overview.re_request_review(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return has_notification("Failed to re-request review", vim.log.levels.ERROR)
		end))
	end)

	it("re-shows the overview after a successful re-request while active", function()
		select_choice = { login = "alice", state = "APPROVED" }
		local pr_view_called = false
		helpers.mock_gh({
			[POST_KEY] = function(_args, callback)
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["pr:view"] = function(_args, callback)
				pr_view_called = true
				-- Respond with an error so M.show() bails out without
				-- actually opening the overview float in the test.
				vim.schedule(function()
					callback("mocked: stop after fetch", nil)
				end)
			end,
		})
		config.state.active = true

		overview.re_request_review(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return pr_view_called
		end))
	end)

	it("does not re-show the overview when the session was reset while the request was in flight", function()
		select_choice = { login = "alice", state = "APPROVED" }
		local pr_view_called = false
		helpers.mock_gh({
			[POST_KEY] = function(_args, callback)
				vim.schedule(function()
					-- Simulate stop() + start() of another session between the
					-- request and its response: the state table identity changes
					-- and the new session is active.
					config.reset_state()
					config.state.active = true
					callback(nil, {})
				end)
			end,
			["pr:view"] = function(_args, callback)
				pr_view_called = true
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})
		config.state.active = true

		overview.re_request_review(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return has_notification("Re-requested review from @alice", vim.log.levels.INFO)
		end))
		vim.wait(100, function()
			return pr_view_called
		end)
		assert.is_false(pr_view_called)
	end)

	it("does not re-show the overview when the session is no longer active", function()
		select_choice = { login = "alice", state = "APPROVED" }
		local pr_view_called = false
		helpers.mock_gh({
			[POST_KEY] = function(_args, callback)
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["pr:view"] = function(_args, callback)
				pr_view_called = true
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})
		config.state.active = false

		overview.re_request_review(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return has_notification("Re-requested review from @alice", vim.log.levels.INFO)
		end))
		vim.wait(100, function()
			return pr_view_called
		end)
		assert.is_false(pr_view_called)
	end)
end)

describe("overview menu and toggle editors", function()
	local config = require("fude.config")
	local overview = require("fude.overview")

	local REVIEWERS_KEY = "api:repos/{owner}/{repo}/pulls/42/requested_reviewers"
	local orig_select
	local notifications
	-- Each vim.ui.select call pops the next responder; a responder receives
	-- (items, opts) and returns the choice.
	local responders
	local shown

	local function make_pr_info()
		return {
			number = 42,
			author = { login = "author" },
			reviewRequests = { { login = "carol" } },
			latestReviews = { { author = { login = "bob" }, state = "APPROVED", authorAssociation = "MEMBER" } },
			labels = { { name = "bug" } },
		}
	end

	local function has_notification(pattern, level)
		for _, n in ipairs(notifications) do
			if n.msg:find(pattern, 1, true) and (level == nil or n.level == level) then
				return true
			end
		end
		return false
	end

	local function pick(text)
		return function(items, opts)
			for _, item in ipairs(items) do
				if opts.format_item(item):find(text, 1, true) then
					return item
				end
			end
			error("no item matching " .. text)
		end
	end

	before_each(function()
		config.setup({ file_list_mode = "quickfix" })
		config.state.active = true
		notifications = {}
		responders = {}
		shown = {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		orig_select = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			local lines = {}
			for _, item in ipairs(items) do
				table.insert(lines, opts.format_item(item))
			end
			table.insert(shown, lines)
			local responder = table.remove(responders, 1)
			on_choice(responder and responder(items, opts) or nil)
		end
	end)

	after_each(function()
		vim.ui.select = orig_select
		helpers.cleanup()
	end)

	it("lists Comment, Reviewer and Label in the menu and reopens the overview on cancel", function()
		local pr_view_called = false
		helpers.mock_gh({
			["pr:view"] = function(_, callback)
				pr_view_called = true
				vim.schedule(function()
					callback("mocked: stop after fetch", nil)
				end)
			end,
		})
		overview.open_menu(make_pr_info())
		assert.are.same({
			"Comment: write a new comment on the PR",
			"Reviewer: request a review or remove a review request",
			"Label: add or remove labels on the PR",
		}, shown[1])
		assert.is_true(helpers.wait_for(function()
			return pr_view_called
		end))
	end)

	it("C in the overview float closes it and runs on_menu", function()
		local menu_called = false
		require("fude.ui").show_overview_float(make_pr_info(), {}, {
			on_menu = function()
				menu_called = true
			end,
		})
		local win = vim.api.nvim_get_current_win()
		local callback
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
			if map.lhs == "C" then
				callback = map.callback
			end
		end
		callback()
		assert.is_true(menu_called)
		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)

	it("Reviewer removes the pending request of a requested user", function()
		local captured
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = { { login = "alice" }, { login = "author" } },
			[REVIEWERS_KEY] = function(args, callback, stdin)
				captured = { args = args, stdin = stdin }
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["pr:view"] = "mocked: stop after fetch",
		})
		table.insert(responders, pick("Reviewer"))
		table.insert(responders, pick("@carol"))

		overview.open_menu(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		assert.are.same({ "● @carol  (review requested)", "○ @bob  (last review: approved)", "○ @alice" }, shown[2])
		assert.is_truthy(table.concat(captured.args, " "):find("--method DELETE", 1, true))
		assert.are.same({ reviewers = { "carol" } }, vim.json.decode(captured.stdin))
		assert.is_true(helpers.wait_for(function()
			return has_notification("Removed review request from @carol", vim.log.levels.INFO)
		end))
		assert.is_true(helpers.wait_for(function()
			return shown[3] ~= nil
		end))
		-- The select reopens with the flipped mark and detail
		assert.are.equal("○ @carol", shown[3][1])
	end)

	it("Reviewer falls back to requested and reviewed users when collaborators cannot be listed", function()
		local captured
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = "gh: Must have push access (HTTP 403)",
			[REVIEWERS_KEY] = function(args, callback, stdin)
				captured = { args = args, stdin = stdin }
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["pr:view"] = "mocked: stop after fetch",
		})
		table.insert(responders, pick("@bob"))

		overview.edit_reviewers(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		assert.is_true(has_notification("Could not list collaborators", vim.log.levels.WARN))
		assert.are.same({ "● @carol  (review requested)", "○ @bob  (last review: approved)" }, shown[1])
		assert.is_truthy(table.concat(captured.args, " "):find("--method POST", 1, true))
		assert.are.same({ reviewers = { "bob" } }, vim.json.decode(captured.stdin))
	end)

	it("Label adds an unapplied label and removes an applied one", function()
		local requests = {}
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "bug" }, { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = function(args, callback, stdin)
				table.insert(requests, { args = args, stdin = stdin })
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["api:repos/{owner}/{repo}/issues/42/labels/bug"] = function(args, callback)
				table.insert(requests, { args = args })
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
			["pr:view"] = "mocked: stop after fetch",
		})
		table.insert(responders, pick("docs"))
		table.insert(responders, pick("bug"))

		overview.edit_labels(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return #requests == 2
		end))
		assert.are.same({ "● bug", "○ docs" }, shown[1])
		assert.are.same({ labels = { "docs" } }, vim.json.decode(requests[1].stdin))
		assert.is_truthy(table.concat(requests[2].args, " "):find("--method DELETE", 1, true))
		assert.is_true(helpers.wait_for(function()
			return shown[3] ~= nil
		end))
		assert.are.same({ "○ bug", "● docs" }, shown[3])
	end)

	it("keeps the mark and notifies when a label request fails", function()
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = "gh: Not Found (HTTP 404)",
			["pr:view"] = "mocked: stop after fetch",
		})
		table.insert(responders, pick("docs"))

		overview.edit_labels(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return shown[2] ~= nil
		end))
		assert.is_true(has_notification("Failed to add label docs", vim.log.levels.ERROR))
		assert.are.same({ "● bug", "○ docs" }, shown[2])
	end)

	it("refuses a toggle after the session was stopped while the picker was open", function()
		local posted = false
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = function()
				posted = true
			end,
		})
		table.insert(responders, function(items)
			config.reset_state()
			return items[2]
		end)

		overview.edit_labels(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return has_notification("Not active", vim.log.levels.WARN)
		end))
		assert.is_false(posted)
	end)
end)
