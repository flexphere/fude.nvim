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
