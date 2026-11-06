--- Integration tests for overview re-request review flow.
local helpers = require("tests.helpers")

--- Whether a mocked gh call is the overview's separate CI checks request
--- (`gh pr view --json statusCheckRollup`), as opposed to its PR info request.
local function is_checks_request(args)
	return vim.tbl_contains(args, "statusCheckRollup")
end

--- Whether a mocked gh call is the overview's separate reviewers request
--- (`gh pr view --json reviewRequests,latestReviews`).
local function is_reviewers_request(args)
	return vim.tbl_contains(args, "reviewRequests,latestReviews")
end

--- Answer a reviewers request at once with no reviewers.
local function answer_reviewers(callback)
	vim.schedule(function()
		callback(nil, { reviewRequests = {}, latestReviews = {} })
	end)
end

--- Answer a CI checks request at once with no checks.
local function answer_checks(callback)
	vim.schedule(function()
		callback(nil, { statusCheckRollup = {} })
	end)
end

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
		assert.are.same(
			{ "✓ @bob  (last review: approved)", "● @carol  (review requested)", "○ @alice", "○ @copilot" },
			shown[2]
		)
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
		assert.are.same({ "✓ @bob  (last review: approved)", "● @carol  (review requested)", "○ @copilot" }, shown[1])
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

	it("does not reopen the overview when the reviewer picker closes, and lists Copilot alone for a solo repo", function()
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

		-- Nobody but the author: Copilot is still offered
		local pr_info = make_pr_info()
		pr_info.reviewRequests = {}
		pr_info.latestReviews = {}
		pr_info.author = { login = "alice" }
		overview.edit_reviewers(pr_info)
		assert.is_true(helpers.wait_for(function()
			return shown[2] ~= nil
		end))
		assert.are.same({ "○ @copilot" }, shown[2])
		assert.is_false(has_notification("No reviewers to choose from"))

		vim.wait(100, function()
			return pr_view_called
		end)
		assert.is_false(pr_view_called)
		assert.are.equal(2, #shown)
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

	it("Reviewer passes the avatar fetch as the picker's row images only when avatars are enabled", function()
		local avatars = require("fude.ui.avatars")
		local captured_opts
		helpers.mock(require("fude.ui.toggle_picker"), "open", function(opts)
			captured_opts = opts
		end)
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = { { login = "alice" } },
		})
		helpers.mock(avatars, "is_enabled", function()
			return true
		end)
		local fetched = {}
		helpers.mock(avatars, "fetch", function(login, cb)
			table.insert(fetched, login)
			cb("/cache/" .. login .. ".png")
		end)

		overview.edit_reviewers(make_pr_info())
		assert.is_true(helpers.wait_for(function()
			return captured_opts ~= nil
		end))
		assert.are.equal("function", type(captured_opts.images))
		local got
		captured_opts.images(captured_opts.items[1], function(path)
			got = path
		end)
		assert.are.same({ captured_opts.items[1].value }, fetched)
		assert.are.equal("/cache/" .. captured_opts.items[1].value .. ".png", got)

		captured_opts = nil
		helpers.mock(avatars, "is_enabled", function()
			return false
		end)
		overview.edit_reviewers(make_pr_info())
		assert.is_true(helpers.wait_for(function()
			return captured_opts ~= nil
		end))
		assert.is_nil(captured_opts.images)
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

	it("requests Copilot under its REST login and names it @copilot", function()
		local captured
		helpers.mock_gh({
			["api:repos/{owner}/{repo}/collaborators"] = {},
			[REVIEWERS_KEY] = function(args, callback, stdin)
				captured = { args = args, stdin = stdin }
				vim.schedule(function()
					callback(nil, {})
				end)
			end,
		})
		table.insert(responders, pick("@copilot"))
		local pr_info = make_pr_info()
		-- gh pr view names Copilot by its bare login
		pr_info.latestReviews = {
			{ author = { login = "copilot-pull-request-reviewer" }, state = "COMMENTED", authorAssociation = "CONTRIBUTOR" },
		}

		overview.edit_reviewers(pr_info)

		assert.is_true(helpers.wait_for(function()
			return captured ~= nil
		end))
		-- Reviewed (commented) ranks before requested
		assert.are.same({ " @copilot  (last review: commented)", "● @carol  (review requested)" }, shown[1])
		assert.is_truthy(table.concat(captured.args, " "):find("--method POST", 1, true))
		assert.are.same({ reviewers = { "copilot-pull-request-reviewer[bot]" } }, vim.json.decode(captured.stdin))
		assert.is_true(helpers.wait_for(function()
			return has_notification("Re-requested review from @copilot", vim.log.levels.INFO)
		end))
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
			["pr:view"] = function(args, callback)
				if is_checks_request(args) then
					return answer_checks(callback)
				end
				if is_reviewers_request(args) then
					return answer_reviewers(callback)
				end
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
			["pr:view"] = function(args, callback)
				if is_checks_request(args) then
					return answer_checks(callback)
				end
				if is_reviewers_request(args) then
					return answer_reviewers(callback)
				end
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
		-- The first show() is done: a new one (bypassing the cache it filled)
		-- fetches again
		overview.show({ fresh = true })
		assert.are.equal(2, fetches)
		assert.are.equal(2, #loadings)
	end)

	it("replaces the placeholder of a stopped session instead of dropping the new session's show()", function()
		local fetches = 0
		local pendings = {}
		helpers.mock_gh({
			["pr:view"] = function(args, callback)
				if is_checks_request(args) then
					return answer_checks(callback)
				end
				if is_reviewers_request(args) then
					return answer_reviewers(callback)
				end
				fetches = fetches + 1
				table.insert(pendings, callback)
			end,
			["api:repos/{owner}/{repo}/issues/7/comments"] = {},
			["api:repos/{owner}/{repo}/pulls/7/reviews"] = {},
		})
		overview.show()
		assert.are.equal(1, #loadings)
		-- stop → start of another session while the first fetch is pending
		config.reset_state()
		config.state.active = true
		config.state.review_mode = "github"

		overview.show()
		assert.are.equal(2, fetches)
		assert.are.equal(2, #loadings)
		-- The old session's placeholder is gone, the new one is up
		assert.is_false(loadings[1].is_open())
		assert.is_true(loadings[2].is_open())

		-- The stale response shows nothing and leaves the new placeholder alone
		pendings[1](nil, { number = 7, title = "old" })
		vim.wait(100, function()
			return shown_with ~= nil
		end)
		assert.is_nil(shown_with)
		assert.is_true(loadings[2].is_open())

		pendings[2](nil, { number = 7, title = "new" })
		assert.is_true(helpers.wait_for(function()
			return shown_with ~= nil
		end))
		assert.are.equal("new", shown_with.pr_info.title)
		assert.is_false(loadings[2].is_open())
	end)
end)

describe("overview prefetch and cache", function()
	local config = require("fude.config")
	local overview = require("fude.overview")
	local ui = require("fude.ui")

	local notifications
	-- Every show_overview_float call: { pr_info, comments, opts }
	local shown
	local loadings
	-- gh pr view calls, each { args, callback }; answered by respond()
	local pr_views
	-- The separate CI checks requests, each { args, callback }
	local check_views
	-- The separate reviewers requests, each { args, callback }
	local reviewer_views
	local comment_fetches

	local function gh_responses(extra)
		local responses = {
			["pr:view"] = function(args, callback)
				if is_checks_request(args) then
					table.insert(check_views, { args = args, callback = callback })
					return
				end
				if is_reviewers_request(args) then
					table.insert(reviewer_views, { args = args, callback = callback })
					return
				end
				table.insert(pr_views, { args = args, callback = callback })
			end,
			["api:repos/{owner}/{repo}/issues/7/comments"] = function(_, callback)
				comment_fetches = comment_fetches + 1
				vim.schedule(function()
					callback(nil, { { id = 1, body = "hi", created_at = "2030-01-01T00:00:00Z" } })
				end)
			end,
			["api:repos/{owner}/{repo}/pulls/7/reviews"] = {},
		}
		return vim.tbl_extend("force", responses, extra or {})
	end

	before_each(function()
		config.setup({ file_list_mode = "quickfix" })
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 7
		notifications = {}
		shown = {}
		loadings = {}
		pr_views = {}
		check_views = {}
		reviewer_views = {}
		comment_fetches = 0
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(ui, "show_overview_float", function(pr_info, comments, opts)
			table.insert(shown, { pr_info = pr_info, comments = comments, opts = opts })
		end)
		local open_loading = ui.open_overview_loading
		helpers.mock(ui, "open_overview_loading", function()
			local handle = open_loading()
			table.insert(loadings, handle)
			return handle
		end)
		helpers.mock_gh(gh_responses())
	end)

	after_each(function()
		for _, handle in ipairs(loadings) do
			if handle.is_open() then
				handle.close()
			end
		end
		helpers.cleanup()
	end)

	--- Answer the n-th gh pr view call.
	local function respond(n, err, data)
		pr_views[n].callback(err, data)
	end

	it("caches the prefetched data and show() opens from it without fetching", function()
		overview.prefetch()
		assert.are.equal(1, #pr_views)
		-- The session's PR number is passed, so gh never infers it from the branch
		assert.are.equal("7", pr_views[1].args[3])
		respond(1, nil, { number = 7, title = "T" })
		-- Cached with the body; the comments land on the same entry later
		assert.is_true(helpers.wait_for(function()
			return config.state.overview_cache ~= nil and config.state.overview_cache.pr_comments ~= nil
		end))
		assert.are.equal("T", config.state.overview_cache.pr_info.title)
		assert.are.equal(1, #config.state.overview_cache.pr_comments)

		overview.show()
		assert.are.equal(1, #shown)
		assert.are.equal("T", shown[1].pr_info.title)
		assert.are.equal(1, #shown[1].comments)
		assert.are.equal(1, #pr_views)
		assert.are.equal(1, comment_fetches)
		assert.are.equal(0, #loadings)
		assert.are.same({}, notifications)
	end)

	it("drops a prefetch response, success or failure, that arrives after the session was stopped", function()
		overview.prefetch()
		overview.prefetch()
		-- The second prefetch joins the first
		assert.are.equal(1, #pr_views)
		local old_state = config.state
		config.reset_state()
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 7
		-- The new session does not join the old session's request
		overview.prefetch()
		assert.are.equal(2, #pr_views)
		local new_state = config.state
		config.reset_state()

		respond(1, nil, { number = 7, title = "old" })
		respond(2, "gh: boom", nil)
		vim.wait(100, function()
			return config.state.overview_cache ~= nil or old_state.overview_cache ~= nil or new_state.overview_cache ~= nil
		end)
		assert.is_nil(config.state.overview_cache)
		assert.is_nil(old_state.overview_cache)
		assert.is_nil(new_state.overview_cache)
		-- With the PR number known the comments go out in parallel with the PR
		-- info, so both sessions fetched them; neither result is kept
		assert.are.equal(2, comment_fetches)
		assert.are.same({}, notifications)
		assert.are.same({}, shown)
	end)

	it("R in the overview refetches instead of reusing the cache, and updates it", function()
		config.state.overview_cache = { pr_info = { number = 7, title = "cached" }, pr_comments = {} }
		overview.show()
		assert.are.equal(1, #shown)
		assert.are.equal("cached", shown[1].pr_info.title)
		assert.are.equal(0, #pr_views)

		shown[1].opts.on_refresh()
		assert.are.equal(1, #pr_views)
		assert.are.equal(1, #loadings)
		respond(1, nil, { number = 7, title = "fresh" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 2
		end))
		assert.are.equal("fresh", shown[2].pr_info.title)
		assert.are.equal("fresh", config.state.overview_cache.pr_info.title)
		assert.is_false(loadings[1].is_open())
	end)

	it("refetches after posting a PR comment", function()
		config.state.overview_cache = { pr_info = { number = 7, title = "cached" }, pr_comments = {} }
		helpers.mock(ui, "open_comment_input", function(callback)
			callback("new comment", "submit")
		end)
		helpers.mock(require("fude.gh"), "create_issue_comment", function(_, _, callback)
			vim.schedule(function()
				callback(nil, {})
			end)
		end)

		overview.create_comment(7)
		assert.is_true(helpers.wait_for(function()
			return #pr_views == 1
		end))
		respond(1, nil, { number = 7, title = "fresh" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 1
		end))
		assert.are.equal("fresh", shown[1].pr_info.title)
	end)

	it("show() during the prefetch waits for it instead of fetching again", function()
		overview.prefetch()
		overview.show()
		assert.are.equal(1, #pr_views)
		assert.are.equal(1, #loadings)
		assert.is_true(loadings[1].is_open())

		respond(1, nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 1
		end))
		assert.are.equal("T", shown[1].pr_info.title)
		assert.are.equal(1, comment_fetches)
		assert.is_false(loadings[1].is_open())
		assert.is_not_nil(config.state.overview_cache)
	end)

	it("a failed prefetch is silent, and show() then fetches and reports errors itself", function()
		overview.prefetch()
		respond(1, "gh: boom", nil)
		vim.wait(100, function()
			return #notifications > 0
		end)
		assert.are.same({}, notifications)
		assert.is_nil(config.state.overview_cache)

		overview.show()
		assert.are.equal(2, #pr_views)
		assert.are.equal(1, #loadings)
		respond(2, "gh: boom again", nil)
		assert.is_true(helpers.wait_for(function()
			return #notifications > 0
		end))
		assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
		assert.is_false(loadings[1].is_open())
		assert.are.same({}, shown)
	end)

	it("requests the PR info, the comments and the checks in parallel, and opens before the checks", function()
		overview.show()
		-- All three went out before anything answered
		assert.are.equal(1, #pr_views)
		assert.are.equal(1, #check_views)
		assert.are.same({ "pr", "view", "7", "--json", "statusCheckRollup" }, check_views[1].args)
		assert.is_true(helpers.wait_for(function()
			return comment_fetches == 1
		end))

		local set = {}
		helpers.mock(ui, "show_overview_float", function(pr_info, comments, opts)
			table.insert(shown, { pr_info = pr_info, comments = comments, opts = opts })
			return {
				is_open = function()
					return true
				end,
				set_checks = function(checks, failed)
					table.insert(set, { checks = checks, failed = failed })
				end,
			}
		end)
		respond(1, nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 1
		end))
		-- Opened without the checks; CI STATUS fills in when they land
		assert.is_nil(shown[1].pr_info.statusCheckRollup)
		assert.are.same({}, set)
		check_views[1].callback(nil, { statusCheckRollup = { { name = "ci" } } })
		assert.are.same({ { checks = { { name = "ci" } }, failed = false } }, set)
		-- The cache has them too, so the next show() opens complete
		assert.are.same({ { name = "ci" } }, config.state.overview_cache.pr_info.statusCheckRollup)
		overview.show()
		assert.are.same({ { name = "ci" } }, shown[2].pr_info.statusCheckRollup)
		assert.are.equal(1, #check_views)
	end)

	it("opens with the body before the reviewers and comments, and fills them in as they land", function()
		-- Comments held until released
		local release_comments
		helpers.mock_gh(gh_responses({
			["api:repos/{owner}/{repo}/issues/7/comments"] = function(_, callback)
				comment_fetches = comment_fetches + 1
				release_comments = function()
					callback(nil, { { id = 1, body = "hi", created_at = "2030-01-01T00:00:00Z" } })
				end
			end,
		}))
		local calls = {}
		helpers.mock(ui, "show_overview_float", function(pr_info, comments, opts)
			table.insert(shown, { pr_info = pr_info, comments = comments, opts = opts })
			return {
				is_open = function()
					return true
				end,
				set_checks = function() end,
				set_reviewers = function()
					table.insert(calls, "reviewers")
				end,
				set_comments = function(comments_now)
					table.insert(calls, "comments:" .. #comments_now)
				end,
			}
		end)
		overview.show()
		assert.are.equal(1, #reviewer_views)
		assert.are.same({ "pr", "view", "7", "--json", "reviewRequests,latestReviews" }, reviewer_views[1].args)
		-- The body request asks for neither the reviewers nor the checks
		local fields = pr_views[1].args[#pr_views[1].args]
		assert.is_nil(fields:find("reviewRequests", 1, true))
		assert.is_nil(fields:find("statusCheckRollup", 1, true))

		respond(1, nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 1
		end))
		assert.is_true(shown[1].pr_info.reviewers_loading)
		assert.is_nil(shown[1].comments)

		reviewer_views[1].callback(nil, { reviewRequests = {}, latestReviews = { { author = { login = "a" } } } })
		assert.are.same({ "reviewers" }, calls)
		assert.is_nil(shown[1].pr_info.reviewers_loading)
		assert.are.equal(1, #shown[1].pr_info.latestReviews)
		release_comments()
		assert.is_true(helpers.wait_for(function()
			return #calls == 2
		end))
		assert.are.equal("comments:1", calls[2])
		assert.are.equal(1, #config.state.overview_cache.pr_comments)
	end)

	it("prefetch with the body already known sends no body request and reports ready", function()
		local ready = 0
		overview.prefetch({
			pr_info = { number = 7, title = "from lookup" },
			on_ready = function()
				ready = ready + 1
			end,
		})
		assert.are.equal(0, #pr_views)
		assert.are.equal(1, #reviewer_views)
		assert.are.equal(1, #check_views)
		assert.are.equal(1, ready)
		assert.are.equal("from lookup", config.state.overview_cache.pr_info.title)
		overview.show()
		assert.are.equal(1, #shown)
		assert.are.equal("from lookup", shown[1].pr_info.title)
	end)

	it("prefetch reports ready only on success and only for the active session", function()
		local ready = 0
		local function on_ready()
			ready = ready + 1
		end
		overview.prefetch({ on_ready = on_ready })
		respond(1, "gh: boom", nil)
		vim.wait(50)
		assert.are.equal(0, ready)

		overview.prefetch({ on_ready = on_ready })
		config.reset_state()
		respond(2, nil, { number = 7, title = "T" })
		vim.wait(50)
		assert.are.equal(0, ready)
	end)

	it("refuses the reviewer flows while the reviewers are loading or failed to load", function()
		local pr_info = { number = 7, url = "https://github.com/o/r/pull/7", reviewers_loading = true }
		overview.re_request_review(pr_info, config.state)
		overview.edit_reviewers(pr_info, config.state)
		assert.are.equal(2, #notifications)
		assert.are.equal("fude.nvim: Reviewers are still loading", notifications[1].msg)
		pr_info.reviewers_loading, pr_info.reviewers_failed = nil, true
		overview.re_request_review(pr_info, config.state)
		assert.are.equal(vim.log.levels.WARN, notifications[3].level)
	end)

	it("hands over checks that landed before the PR info, and marks a failed checks fetch", function()
		overview.prefetch()
		check_views[1].callback(nil, { statusCheckRollup = { { name = "early" } } })
		respond(1, nil, { number = 7, title = "T" })
		assert.is_true(helpers.wait_for(function()
			return config.state.overview_cache ~= nil
		end))
		assert.are.same({ { name = "early" } }, config.state.overview_cache.pr_info.statusCheckRollup)

		overview.show({ fresh = true })
		assert.are.equal(2, #check_views)
		check_views[2].callback("HTTP 502", nil)
		respond(2, nil, { number = 7, title = "T2" })
		assert.is_true(helpers.wait_for(function()
			return #shown == 1
		end))
		assert.is_true(shown[1].pr_info.checks_failed)
		assert.is_nil(shown[1].pr_info.statusCheckRollup)
		-- A failed checks fetch is not reported: CI STATUS says so
		assert.are.same({}, notifications)
	end)

	it("does nothing outside a GitHub review session", function()
		config.state.review_mode = "local"
		overview.prefetch()
		config.state.review_mode = "github"
		config.state.active = false
		overview.prefetch()
		assert.are.equal(0, #pr_views)
	end)

	it("drops the cache after a label edit, and a fetch in flight does not restore it", function()
		helpers.mock_gh(gh_responses({
			["api:repos/{owner}/{repo}/labels"] = { { name = "docs" } },
			["api:repos/{owner}/{repo}/issues/42/labels"] = {},
		}))
		local orig_select = vim.ui.select
		local selects = 0
		vim.ui.select = function(items, _, on_choice)
			selects = selects + 1
			on_choice(selects == 1 and items[1] or nil)
		end
		config.state.overview_cache = { pr_info = { number = 7 }, pr_comments = {} }
		-- A reload's prefetch is in flight while the label is added
		overview.prefetch()

		overview.edit_labels({ number = 42, labels = {} }, config.state)
		local ok = helpers.wait_for(function()
			return selects >= 2
		end)
		vim.ui.select = orig_select
		assert.is_true(ok)
		assert.is_nil(config.state.overview_cache)

		respond(1, nil, { number = 7, title = "before the edit" })
		vim.wait(100, function()
			return config.state.overview_cache ~= nil
		end)
		assert.is_nil(config.state.overview_cache)
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
		assert.are.same(
			{ "@carol", "@alice", "@copilot" },
			{ opened.items[1].text, opened.items[2].text, opened.items[3].text }
		)
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
