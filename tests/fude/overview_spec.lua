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

		overview.re_request_review(make_pr_info())

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
		overview.open_menu(make_pr_info())
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

		overview.edit_labels(make_pr_info())

		assert.is_true(helpers.wait_for(function()
			return has_notification("Not active", vim.log.levels.WARN)
		end))
		assert.is_false(posted)
	end)
end)
