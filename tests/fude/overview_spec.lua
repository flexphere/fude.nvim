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
		-- re_request_review refuses outside an active session
		config.state.active = true
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

	it("does not reopen the overview after a re-request, whatever its outcome", function()
		local cases = {
			{ name = "success", choice = { login = "alice", state = "APPROVED" }, post_err = nil },
			{ name = "failure", choice = { login = "alice", state = "APPROVED" }, post_err = "gh: HTTP 422" },
			{ name = "cancel", choice = nil },
			{ name = "no candidates", choice = nil, no_candidates = true },
		}
		for _, case in ipairs(cases) do
			select_choice = case.choice
			local settled, pr_view_called = false, false
			helpers.mock_gh({
				[POST_KEY] = function(_args, callback)
					vim.schedule(function()
						callback(case.post_err, case.post_err == nil and {} or nil)
						settled = true
					end)
				end,
				["pr:view"] = function()
					pr_view_called = true
				end,
			})

			local pr_info = make_pr_info()
			if case.no_candidates then
				pr_info.latestReviews = {}
			end
			overview.re_request_review(pr_info)

			if case.choice then
				assert.is_true(helpers.wait_for(function()
					return settled
				end))
			end
			vim.wait(100, function()
				return pr_view_called
			end)
			assert.is_false(pr_view_called, case.name)
		end
	end)

	it("refuses without posting when the session is no longer active", function()
		select_choice = { login = "alice", state = "APPROVED" }
		local posted, pr_view_called = false, false
		helpers.mock_gh({
			[POST_KEY] = function()
				posted = true
			end,
			["pr:view"] = function()
				pr_view_called = true
			end,
		})
		config.state.active = false

		overview.re_request_review(make_pr_info(), config.state)

		assert.is_true(has_notification("Not active", vim.log.levels.WARN))
		vim.wait(100, function()
			return posted or pr_view_called
		end)
		assert.is_false(posted)
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
		})
		table.insert(responders, pick("Reviewer"))
		table.insert(responders, pick("@carol"))

		overview.open_menu(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		assert.are.same({ "✓ @bob  (last review: approved)", "● @carol  (review requested)", "○ @alice" }, shown[2])
		assert.is_truthy(table.concat(captured.args, " "):find("--method DELETE", 1, true))
		assert.are.same({ reviewers = { "carol" } }, vim.json.decode(captured.stdin))
		assert.is_true(helpers.wait_for(function()
			return has_notification("Removed review request from @carol", vim.log.levels.INFO)
		end))
		assert.is_true(helpers.wait_for(function()
			return shown[3] ~= nil
		end))
		-- The select reopens with the flipped mark and detail
		assert.are.equal("○ @carol", shown[3][2])
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
		})
		table.insert(responders, pick("@bob"))

		overview.edit_reviewers(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		assert.is_true(has_notification("Could not list collaborators", vim.log.levels.WARN))
		-- bob already reviewed, so the request is a re-request
		assert.is_true(helpers.wait_for(function()
			return has_notification("Re-requested review from @bob", vim.log.levels.INFO)
		end))
		assert.are.same({ "✓ @bob  (last review: approved)", "● @carol  (review requested)" }, shown[1])
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

	it("does not reopen the overview when the label picker closes after an edit", function()
		local pr_view_called = false
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = {},
			["pr:view"] = function()
				pr_view_called = true
			end,
		})
		-- Toggle docs, then cancel the reopened select (closes the picker)
		table.insert(responders, pick("docs"))

		overview.edit_labels(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return shown[2] ~= nil
		end))
		assert.are.same({ "● bug", "● docs" }, shown[2])
		vim.wait(100, function()
			return pr_view_called
		end)
		assert.is_false(pr_view_called)
	end)

	it("does not reopen the overview when the reviewer picker closes, or when it has no rows", function()
		local pr_view_called = false
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = { { login = "alice" } },
			["pr:view"] = function()
				pr_view_called = true
			end,
		})
		-- Cancel the picker without toggling
		overview.edit_reviewers(make_pr_info())
		assert.is_true(helpers.wait_for(function()
			return shown[1] ~= nil
		end))

		-- No candidates at all: only the author
		local pr_info = make_pr_info()
		pr_info.reviewRequests = {}
		pr_info.latestReviews = {}
		pr_info.author = { login = "alice" }
		overview.edit_reviewers(pr_info)
		assert.is_true(helpers.wait_for(function()
			return has_notification("No reviewers to choose from", vim.log.levels.INFO)
		end))

		vim.wait(100, function()
			return pr_view_called
		end)
		assert.is_false(pr_view_called)
		assert.are.equal(1, #shown)
	end)

	it("refuses the menu of an overview opened in a session that was stopped and restarted", function()
		local old_state = config.state
		config.reset_state()
		config.state.active = true
		overview.open_menu(make_pr_info(), old_state)
		assert.are.equal(0, #shown)
		assert.is_true(has_notification("Not active", vim.log.levels.WARN))
	end)

	it("refuses a menu choice made after the session was stopped and restarted", function()
		local requested = false
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = function()
				requested = true
			end,
		})
		table.insert(responders, function(items, opts)
			config.reset_state()
			config.state.active = true
			return pick("Label")(items, opts)
		end)
		overview.open_menu(make_pr_info(), config.state)
		assert.is_true(has_notification("Not active", vim.log.levels.WARN))
		assert.is_false(requested)
	end)

	it("sends the label requests to the PR's repository, not the cwd's", function()
		local paths = {}
		helpers.mock_gh({
			["api:repos/octo/fude/labels"] = function(args, callback)
				table.insert(paths, args[2])
				vim.schedule(function()
					callback(nil, { { name = "docs" } })
				end)
			end,
			["api:repos/octo/fude/issues/42/labels"] = function(args, callback)
				table.insert(paths, args[2])
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})
		table.insert(responders, pick("docs"))
		local pr_info = make_pr_info()
		pr_info.url = "https://github.com/octo/fude/pull/42"

		overview.edit_labels(pr_info)

		assert.is_true(helpers.wait_for(function()
			return #paths == 2
		end))
		assert.are.same({ "repos/octo/fude/labels", "repos/octo/fude/issues/42/labels" }, paths)
	end)

	it("Reviewer offers <C-e> re-request only for users who reviewed and are not requested", function()
		local captured_opts
		helpers.mock(require("fude.ui.toggle_picker"), "open", function(opts)
			captured_opts = opts
		end)
		local posted
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = { { login = "alice" } },
			[REVIEWERS_KEY] = function(args, callback, stdin)
				posted = { args = args, stdin = stdin }
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})

		overview.edit_reviewers(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return captured_opts ~= nil
		end))
		local action = captured_opts.extra_action
		assert.are.equal("<C-e>", action.key)
		local by_text = {}
		for _, item in ipairs(captured_opts.items) do
			by_text[item.text] = item
		end
		-- carol is requested, bob approved, alice never reviewed
		assert.is_false(action.available(by_text["@carol"]))
		assert.is_true(action.available(by_text["@bob"]))
		assert.is_false(action.available(by_text["@alice"]))
		-- bob approved, so his hint is grey
		assert.are.equal("Comment", action.hint_hl(by_text["@bob"]))
		assert.is_nil(action.hint_hl({ text = "@dan", on = false, review_state = "DISMISSED" }))

		local ok_seen
		action.run(by_text["@bob"], function(ok)
			ok_seen = ok
		end)
		assert.is_true(helpers.wait_for(function()
			return ok_seen ~= nil
		end))
		assert.is_true(ok_seen)
		assert.is_truthy(table.concat(posted.args, " "):find("--method POST", 1, true))
		assert.are.same({ reviewers = { "bob" } }, vim.json.decode(posted.stdin))
		assert.is_true(has_notification("Re-requested review from @bob", vim.log.levels.INFO))
	end)

	it("keeps the mark and notifies when a label request fails", function()
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = "gh: Not Found (HTTP 404)",
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

		overview.edit_labels(make_pr_info(), config.state)

		assert.is_true(helpers.wait_for(function()
			return has_notification("Not active", vim.log.levels.WARN)
		end))
		assert.is_false(posted)
	end)

	it("an editor tied to no session (nil) keeps working after the session was stopped", function()
		local posted = false
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = function(_, callback)
				posted = true
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})
		table.insert(responders, function(items)
			config.reset_state()
			return items[2]
		end)

		overview.edit_labels(make_pr_info(), nil)

		assert.is_true(helpers.wait_for(function()
			return has_notification("Added label docs", vim.log.levels.INFO)
		end))
		assert.is_true(posted)
		assert.is_false(has_notification("Not active"))
	end)
end)

describe("overview show loading state", function()
	local config = require("fude.config")
	local overview = require("fude.overview")
	local ui = require("fude.ui")

	local notifications
	local shown_with
	-- Every placeholder handle show() opened, in order
	local loadings

	--- The placeholder window of the latest show(), while it is open.
	local function loading_win()
		local handle = loadings[#loadings]
		if handle and handle.is_open() then
			return handle.win
		end
		return nil
	end

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.review_mode = "github"
		notifications = {}
		shown_with = nil
		loadings = {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(ui, "show_overview_float", function(pr_info, comments)
			shown_with = { pr_info = pr_info, comments = comments }
		end)
		local open_loading = ui.open_overview_loading
		helpers.mock(ui, "open_overview_loading", function()
			local handle = open_loading()
			handle.win = vim.api.nvim_get_current_win()
			table.insert(loadings, handle)
			return handle
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	--- Mock gh so that `pr view` answers only when `respond` is called.
	--- @return fun(err: string|nil, data: table|nil) respond
	local function mock_pending_pr_view()
		local pending
		helpers.mock_gh({
			["pr:view"] = function(_, callback)
				pending = callback
			end,
			["api:repos/{owner}/{repo}/issues/7/comments"] = {},
			["api:repos/{owner}/{repo}/pulls/7/reviews"] = {},
		})
		return function(err, data)
			pending(err, data)
		end
	end

	it("shows the placeholder while fetching and replaces it with the overview", function()
		local respond = mock_pending_pr_view()
		overview.show()
		local win = loading_win()
		assert.is_not_nil(win)
		assert.are.equal(win, vim.api.nvim_get_current_win())

		respond(nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return shown_with ~= nil
		end))
		assert.are.equal(7, shown_with.pr_info.number)
		assert.is_nil(loading_win())
	end)

	it("closes the placeholder and notifies when the PR cannot be fetched", function()
		local respond = mock_pending_pr_view()
		overview.show()
		assert.is_not_nil(loading_win())

		respond("gh: not found", nil)
		assert.is_true(helpers.wait_for(function()
			return #notifications > 0
		end))
		assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
		assert.is_nil(loading_win())
		assert.is_nil(shown_with)
	end)

	it("does not show the overview when the placeholder was closed while fetching", function()
		local respond = mock_pending_pr_view()
		overview.show()
		vim.api.nvim_win_close(loading_win(), true)

		respond(nil, { number = 7, title = "T" })
		vim.wait(100, function()
			return shown_with ~= nil
		end)
		assert.is_nil(shown_with)
		assert.are.same({}, notifications)
	end)

	it("closes the placeholder when the session was stopped while fetching", function()
		local respond = mock_pending_pr_view()
		overview.show()
		assert.is_not_nil(loading_win())
		config.reset_state()

		respond(nil, { number = 7, title = "T" })
		vim.wait(100, function()
			return shown_with ~= nil
		end)
		assert.is_nil(shown_with)
		assert.is_nil(loading_win())
	end)

	it("drops a second show() while the placeholder is open, and allows one after it closed", function()
		local fetches = 0
		local pending
		helpers.mock_gh({
			["pr:view"] = function(_, callback)
				fetches = fetches + 1
				pending = callback
			end,
			["api:repos/{owner}/{repo}/issues/7/comments"] = {},
			["api:repos/{owner}/{repo}/pulls/7/reviews"] = {},
		})
		overview.show()
		overview.show()
		assert.are.equal(1, fetches)
		assert.are.equal(1, #loadings)

		pending(nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return shown_with ~= nil
		end))
		-- The first show() is done: a new one fetches again
		overview.show()
		assert.are.equal(2, fetches)
		assert.are.equal(2, #loadings)
	end)
end)

describe("overview edit commands (:FudeEditReviewers / :FudeEditLabels)", function()
	local config = require("fude.config")
	local overview = require("fude.overview")
	local gh = require("fude.gh")
	local toggle_picker = require("fude.ui.toggle_picker")

	local notifications
	local opened

	local function has_notification(pattern, level)
		for _, n in ipairs(notifications) do
			if n.msg:find(pattern, 1, true) and (level == nil or n.level == level) then
				return true
			end
		end
		return false
	end

	local function make_pr_info()
		return {
			number = 42,
			url = "https://github.com/octo/fude/pull/42",
			author = { login = "author" },
			reviewRequests = { { login = "carol" } },
			latestReviews = {},
			labels = { { name = "bug" } },
		}
	end

	--- Mock gh.get_pr_edit_info; `seen.num` records the number it was asked for.
	local function mock_edit_info(err, data, seen)
		helpers.mock(gh, "get_pr_edit_info", function(num, callback)
			if seen then
				seen.num = num
			end
			callback(err, data)
		end)
	end

	before_each(function()
		config.setup({ file_list_mode = "quickfix" })
		notifications = {}
		opened = nil
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(toggle_picker, "open", function(opts)
			opened = opts
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("FudeEditLabels opens the label picker of the current branch's PR outside a review", function()
		local seen = { num = "unset" }
		mock_edit_info(nil, make_pr_info(), seen)
		helpers.mock_gh({
			["api:repos/octo/fude/labels"] = { { name = "bug" }, { name = "docs" } },
		})

		overview.edit_current_labels()

		assert.is_true(helpers.wait_for(function()
			return opened ~= nil
		end))
		assert.is_nil(seen.num)
		assert.are.equal("Labels", opened.title)
		assert.are.same({ "bug", "docs" }, { opened.items[1].text, opened.items[2].text })
		assert.is_true(opened.items[1].on)
		assert.is_false(opened.items[2].on)
	end)

	it("FudeEditReviewers looks the review session's PR up by URL and edits in the PR's repository", function()
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 42
		-- The URL pins the repository: a bare number would be resolved against
		-- the cwd, which a `:cd` may have moved to another repository
		config.state.pr_url = "https://github.com/octo/fude/pull/42"
		local seen = {}
		mock_edit_info(nil, make_pr_info(), seen)
		local paths = {}
		helpers.mock_gh({
			["api:repos/octo/fude/collaborators"] = function(args, callback)
				table.insert(paths, args[2])
				vim.schedule(function()
					callback(nil, { { login = "alice" } })
				end)
			end,
		})

		overview.edit_current_reviewers()

		assert.is_true(helpers.wait_for(function()
			return opened ~= nil
		end))
		assert.are.equal("https://github.com/octo/fude/pull/42", seen.num)
		assert.are.same({ "repos/octo/fude/collaborators" }, paths)
		assert.are.equal("Reviewers", opened.title)
		assert.are.same({ "@carol", "@alice" }, { opened.items[1].text, opened.items[2].text })
	end)

	it("ties the editor to no session: a toggle still runs after the session was stopped", function()
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 42
		mock_edit_info(nil, make_pr_info())
		local posted = false
		helpers.mock_gh({
			["api:repos/octo/fude/labels"] = { { name = "docs" } },
			["api:repos/octo/fude/issues/42/labels"] = function(_, callback)
				posted = true
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})

		overview.edit_current_labels()

		assert.is_true(helpers.wait_for(function()
			return opened ~= nil
		end))
		config.reset_state()
		assert.is_true(opened.is_alive())
		local ok_seen
		opened.on_toggle(opened.items[2], function(ok)
			ok_seen = ok
		end)
		assert.is_true(helpers.wait_for(function()
			return ok_seen ~= nil
		end))
		assert.is_true(ok_seen)
		assert.is_true(posted)
		assert.is_false(has_notification("Not active"))
	end)

	it("refuses in the local commit scope without looking the PR up", function()
		helpers.mock(require("fude.local.session"), "in_commit_scope", function()
			return true
		end)
		local looked_up = false
		helpers.mock(gh, "get_pr_edit_info", function()
			looked_up = true
		end)

		overview.edit_current_reviewers()

		assert.is_false(looked_up)
		assert.is_true(has_notification("commit scope", vim.log.levels.WARN))
		assert.is_nil(opened)
	end)

	it("reports a branch without a PR as a WARN and any other lookup failure as an ERROR", function()
		mock_edit_info('no pull requests found for branch "feat/x"\n', nil)
		overview.edit_current_labels()
		assert.is_true(has_notification('no pull requests found for branch "feat/x"', vim.log.levels.WARN))

		mock_edit_info("HTTP 401: Bad credentials\n", nil)
		overview.edit_current_labels()
		assert.is_true(has_notification("HTTP 401: Bad credentials", vim.log.levels.ERROR))

		mock_edit_info(nil, { number = nil })
		overview.edit_current_labels()
		assert.is_true(has_notification("No PR found for current branch", vim.log.levels.WARN))

		assert.is_nil(opened)
	end)
end)
