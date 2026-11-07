local helpers = require("tests.helpers")
local reactions = require("fude.reactions")
local format = require("fude.ui.format")

describe("reactions.format_reactions", function()
	it("lists the non-zero counts in GitHub's order", function()
		assert.are.equal(
			"👍 2  🎉 1  ❤️ 3",
			format.format_reactions({ heart = 3, ["+1"] = 2, hooray = 1, eyes = 0, total_count = 6, url = "x" })
		)
	end)

	it("returns nil without any reaction", function()
		assert.is_nil(format.format_reactions({ total_count = 0, ["+1"] = 0 }))
		assert.is_nil(format.format_reactions(nil))
		assert.is_nil(format.format_reactions(vim.NIL))
		assert.is_nil(format.format_reactions({ ["+1"] = vim.NIL, heart = -1, laugh = 1.5 }))
	end)
end)

describe("reactions.find_reaction_target", function()
	local repo = "repos/o/r"

	it("uses pulls/comments for a review comment and issues/comments otherwise", function()
		assert.are.equal(
			"repos/o/r/pulls/comments/10/reactions",
			reactions.find_reaction_target({ id = 10, path = "a.lua" }, {}, repo)
		)
		assert.are.equal("repos/o/r/issues/comments/11/reactions", reactions.find_reaction_target({ id = 11 }, {}, repo))
	end)

	it("refuses comments without a reactions endpoint", function()
		local cases = {
			{ nil, {}, "No comment" },
			{ { id = 1, path = "a" }, { is_local = true }, "Local" },
			{ { id = 1, path = "a", pull_request_review_id = 5 }, { pending_review_id = 5 }, "Pending" },
			{ { id = 1, is_review_summary = true }, {}, "Review summaries" },
			{ { id = "x" }, {}, "no GitHub ID" },
		}
		for _, case in ipairs(cases) do
			local path, reason = reactions.find_reaction_target(case[1], case[2], repo)
			assert.is_nil(path)
			assert.truthy(reason:find(case[3], 1, true), reason)
		end
		-- Another review's comment while a pending review exists is fine
		assert.is_not_nil(
			reactions.find_reaction_target(
				{ id = 2, path = "a", pull_request_review_id = 4 },
				{ pending_review_id = 5 },
				repo
			)
		)
	end)
end)

describe("reactions people", function()
	it("find_reaction_users lists each login that used the content, oldest first", function()
		local list = {
			{ content = "+1", user = { login = "b" } },
			{ content = "heart", user = { login = "c" } },
			{ content = "+1", user = { login = "a" } },
			{ content = "+1", user = { login = "b" } },
			{ content = "+1", user = vim.NIL },
			vim.NIL,
		}
		assert.are.same({ "b", "a" }, reactions.find_reaction_users(list, "+1"))
		assert.are.same({}, reactions.find_reaction_users(list, "eyes"))
		assert.are.same({}, reactions.find_reaction_users(nil, "+1"))
	end)

	it("build_people_prompt says what it lists and what <CR> / <Esc> do", function()
		assert.are.equal(
			"👍 +1 reacted by 2 (<CR> copy username, <Esc> back to reactions):",
			reactions.build_people_prompt("👍 +1", 2)
		)
	end)
end)

describe("reactions rollup and choices", function()
	local list = {
		{ id = 1, content = "+1", user = { login = "me" } },
		{ id = 2, content = "+1", user = { login = "other" } },
		{ id = 3, content = "heart", user = { login = "me" } },
		{ id = 4, content = "bogus", user = { login = "me" } },
		vim.NIL,
	}

	it("build_rollup counts each known content", function()
		local rollup = reactions.build_rollup(list)
		assert.are.equal(2, rollup["+1"])
		assert.are.equal(1, rollup.heart)
		assert.are.equal(0, rollup.eyes)
		assert.are.equal(3, rollup.total_count)
		assert.are.equal(0, reactions.build_rollup(nil).total_count)
	end)

	it("find_user_reactions maps the viewer's contents to reaction ids", function()
		assert.are.same({ ["+1"] = 1, heart = 3, bogus = 4 }, reactions.find_user_reactions(list, "me"))
		assert.are.same({}, reactions.find_user_reactions(list, nil))
	end)

	it("format_reaction_detail shows the count, who reacted and what <Tab> does", function()
		assert.are.equal("2 · @me, @a · <Tab>: remove", reactions.format_reaction_detail(2, true, { "me", "a" }))
		assert.are.equal("2 · <Tab>: remove", reactions.format_reaction_detail(2, true))
		assert.are.equal("1 · <Tab>: add", reactions.format_reaction_detail(1, false, {}))
		assert.are.equal("<Tab>: add", reactions.format_reaction_detail(0, false))
		assert.are.equal("<Tab>: add", reactions.format_reaction_detail(nil, false))
	end)

	it("format_reaction_users names the first few and counts the rest", function()
		assert.are.equal("@a", reactions.format_reaction_users({ "a" }))
		assert.are.equal("@a, @b, @c", reactions.format_reaction_users({ "a", "b", "c" }))
		assert.are.equal("@a, @b, @c +2", reactions.format_reaction_users({ "a", "b", "c", "d", "e" }))
		assert.are.equal("@a +1", reactions.format_reaction_users({ "a", "b" }, 1))
		assert.is_nil(reactions.format_reaction_users({}))
		assert.is_nil(reactions.format_reaction_users(nil))
	end)

	it("build_reaction_users maps every content to who used it", function()
		local users = reactions.build_reaction_users(list)
		assert.are.same({ "me", "other" }, users["+1"])
		assert.are.same({ "me" }, users.heart)
		assert.are.same({}, users.eyes)
	end)

	it("build_reaction_items lists every reaction, on for the viewer's, with live details", function()
		local counts = reactions.build_rollup(list)
		local items = reactions.build_reaction_items(counts, { ["+1"] = 1 })
		assert.are.equal(8, #items)
		assert.are.equal("👍 +1", items[1].text)
		assert.are.equal("+1", items[1].value)
		assert.is_true(items[1].on)
		assert.is_false(items[2].on)
		assert.are.equal("2 · <Tab>: remove", items[1].detail(items[1]))
		-- With the users table, the rows name who reacted
		local with_users = reactions.build_reaction_items(counts, { ["+1"] = 1 }, reactions.build_reaction_users(list))
		assert.are.equal("2 · @me, @other · <Tab>: remove", with_users[1].detail(with_users[1]))
		assert.are.equal("<Tab>: add", items[2].detail(items[2]))
		-- The detail follows the counts table and the item's state
		counts["-1"] = 4
		items[2].on = true
		assert.are.equal("4 · <Tab>: remove", items[2].detail(items[2]))
	end)
end)

describe("reactions.pick", function()
	local gh = require("fude.gh")
	local config = require("fude.config")
	local calls
	local listing

	before_each(function()
		config.state.github_user = "me"
		calls = {}
		listing = { { id = 7, content = "heart", user = { login = "me" } } }
		helpers.mock(gh, "get_reactions", function(path, cb)
			table.insert(calls, { "get", path })
			cb(nil, listing)
		end)
		helpers.mock(gh, "add_reaction", function(path, content, cb)
			table.insert(calls, { "add", path, content })
			table.insert(listing, { id = 8, content = content, user = { login = "me" } })
			cb(nil, {})
		end)
		helpers.mock(gh, "remove_reaction", function(path, id, cb)
			table.insert(calls, { "remove", path, id })
			listing = {}
			cb(nil)
		end)
		helpers.mock(vim, "notify", function() end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	--- Open the picker for `comment` and capture the toggle_picker opts.
	local function open_picker(comment, ctx, on_done)
		local opened
		helpers.mock(require("fude.ui.toggle_picker"), "open", function(opts)
			opened = opts
		end)
		reactions.pick(comment, ctx or { pr_url = "https://github.com/o/r/pull/1" }, on_done)
		return opened
	end

	local function item_for(opts, content)
		for _, item in ipairs(opts.items) do
			if item.value == content then
				return item
			end
		end
	end

	it("opens a <Tab> toggle picker titled Reactions with the viewer's reactions on", function()
		local opts = open_picker({ id = 5, path = "a.lua" })
		assert.are.equal("Reactions", opts.title)
		assert.are.equal(8, #opts.items)
		assert.is_true(item_for(opts, "heart").on)
		assert.is_false(item_for(opts, "rocket").on)
		assert.are.equal("1 · @me · <Tab>: remove", item_for(opts, "heart").detail(item_for(opts, "heart")))
	end)

	it("adds a reaction on <Tab>, reports success and updates the comment's rollup", function()
		local comment = { id = 5, path = "a.lua" }
		local redrawn
		local opts = open_picker(comment, nil, function(c)
			redrawn = c
		end)
		local item = item_for(opts, "rocket")
		local ok
		opts.on_toggle(item, function(result)
			ok = result
		end)
		assert.is_true(ok)
		assert.are.equal(comment, redrawn)
		assert.are.same({ "add", "repos/o/r/pulls/comments/5/reactions", "rocket" }, calls[2])
		assert.are.equal(1, comment.reactions.rocket)
		assert.are.equal(1, comment.reactions.heart)
		-- The row's count and users follow the new listing
		assert.are.equal("1 · @me · <Tab>: add", item.detail(item))
	end)

	it("removes the viewer's own reaction by its id", function()
		local comment = { id = 6 }
		local opts = open_picker(comment)
		local ok
		opts.on_toggle(item_for(opts, "heart"), function(result)
			ok = result
		end)
		assert.is_true(ok)
		assert.are.same({ "remove", "repos/o/r/issues/comments/6/reactions", 7 }, calls[2])
		assert.are.equal(0, comment.reactions.total_count)
	end)

	it("reports failure to the picker so the row's mark comes back", function()
		helpers.mock(gh, "add_reaction", function(_, _, cb)
			cb("boom")
		end)
		local comment = { id = 5, path = "a.lua" }
		local opts = open_picker(comment)
		local ok
		opts.on_toggle(item_for(opts, "rocket"), function(result)
			ok = result
		end)
		assert.is_false(ok)
		assert.is_nil(comment.reactions)
	end)

	it("offers <CR> to list who reacted: choosing copies the login, <Esc> reopens the reactions", function()
		listing = {
			{ id = 7, content = "heart", user = { login = "me" } },
			{ id = 8, content = "heart", user = { login = "alice" } },
		}
		local opens = 0
		local opened
		helpers.mock(require("fude.ui.toggle_picker"), "open", function(opts)
			opens = opens + 1
			opened = opts
		end)
		reactions.pick({ id = 5, path = "a.lua" }, { pr_url = "https://github.com/o/r/pull/1" })
		assert.are.equal(1, opens)
		assert.are.equal("who reacted", opened.confirm_label)

		local copied
		helpers.mock(require("fude.util"), "copy_to_clipboard", function(text)
			copied = text
			return true
		end)
		local prompt, shown
		local answer = "alice"
		helpers.mock(vim.ui, "select", function(items, sopts, on_choice)
			shown = vim.tbl_map(sopts.format_item, items)
			prompt = sopts.prompt
			on_choice(answer)
		end)
		opened.on_confirm(item_for(opened, "heart"))
		assert.are.same({ "@me", "@alice" }, shown)
		assert.truthy(prompt:find("<CR> copy username", 1, true))
		assert.truthy(prompt:find("<Esc> back to reactions", 1, true))
		assert.is_true(helpers.wait_for(function()
			return copied == "alice"
		end))
		assert.are.equal(1, opens)

		-- <Esc> (no choice): back to the reaction picker
		answer = nil
		opened.on_confirm(item_for(opened, "heart"))
		assert.is_true(helpers.wait_for(function()
			return opens == 2
		end))

		-- Nobody reacted with it: straight back to the reaction picker
		shown = nil
		opened.on_confirm(item_for(opened, "rocket"))
		assert.is_nil(shown)
		assert.are.equal(3, opens)
	end)

	it("refuses a local comment without a request or a picker", function()
		local opts = open_picker({ id = 5, path = "a.lua" }, { is_local = true })
		assert.is_nil(opts)
		assert.are.equal(0, #calls)
	end)
end)

describe("reactions in comment displays", function()
	local identity = function(s)
		return s
	end
	local comments = {
		{ user = { login = "a" }, body = "hi", created_at = "", reactions = { ["+1"] = 1, total_count = 1 } },
		{ user = { login = "b" }, body = "yo", created_at = "", reactions = { total_count = 0 } },
	}

	it("puts the reactions line after the body, inside the comment's range", function()
		for _, fn in ipairs({ format.format_comments_for_display, format.format_reply_comments_for_display }) do
			local result = fn(comments, identity)
			local line
			for i, l in ipairs(result.lines) do
				if l == "👍 1" then
					line = i - 1
				end
			end
			assert.is_not_nil(line)
			assert.are.equal(line, result.comment_ranges[1].end_line)
			-- No line for a comment without reactions
			assert.are.equal("yo", result.lines[result.comment_ranges[2].end_line + 1])
		end
	end)

	it("shows reactions under overview comments", function()
		local result = format.build_overview_left_lines({ number = 1, title = "T" }, comments, identity)
		assert.truthy(vim.tbl_contains(result.lines, "👍 1"))
	end)
end)

describe("+ in the comment viewer", function()
	local ui = require("fude.ui")

	before_each(function()
		require("fude.config").setup({})
	end)

	after_each(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		helpers.cleanup()
	end)

	it("reacts to the comment under the cursor and redraws the float in place", function()
		local picked
		helpers.mock(reactions, "pick", function(comment, _, on_done)
			picked = comment
			comment.reactions = { rocket = 2, total_count = 2 }
			on_done(comment)
		end)
		local comments = {
			{ id = 1, user = { login = "a" }, created_at = "", body = "first" },
			{ id = 2, user = { login = "b" }, created_at = "", body = "second" },
		}
		ui.show_comments_float(comments)
		local win = vim.api.nvim_get_current_win()
		local buf = vim.api.nvim_win_get_buf(win)
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		local rhs = vim.fn.maparg("+", "n", false, true)
		rhs.callback()
		assert.are.equal(comments[1], picked)
		assert.is_true(vim.api.nvim_win_is_valid(win))
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.are.same({ "@a  ", "first", "", "🚀 2" }, vim.list_slice(lines, 1, 4))
		assert.is_false(vim.bo[buf].modifiable)
	end)
end)

describe("PR body reactions", function()
	local identity = function(s)
		return s
	end

	it("build_rollup_from_reaction_groups maps gh's reactionGroups to the REST rollup", function()
		local rollup = format.build_rollup_from_reaction_groups({
			{ content = "THUMBS_UP", users = { totalCount = 2 } },
			{ content = "HEART", users = { totalCount = 1 } },
			{ content = "EYES", users = { totalCount = 0 } },
			{ content = "UNKNOWN", users = { totalCount = 5 } },
			{ content = "ROCKET", users = vim.NIL },
			vim.NIL,
		})
		assert.are.same({ ["+1"] = 2, heart = 1, total_count = 3 }, rollup)
		assert.is_nil(format.build_rollup_from_reaction_groups(nil))
		assert.is_nil(format.build_rollup_from_reaction_groups(vim.NIL))
	end)

	it("find_pr_reactions prefers the rollup fude set over reactionGroups", function()
		local groups = { { content = "HEART", users = { totalCount = 1 } } }
		assert.are.same({ heart = 1, total_count = 1 }, format.find_pr_reactions({ reactionGroups = groups }))
		assert.are.same({ rocket = 3 }, format.find_pr_reactions({ reactionGroups = groups, reactions = { rocket = 3 } }))
		assert.is_nil(format.find_pr_reactions({}))
	end)

	it("shows the PR's reactions under its body, before COMMENTS", function()
		local result = format.build_overview_left_lines({
			number = 1,
			title = "T",
			body = "the body",
			reactionGroups = { { content = "HOORAY", users = { totalCount = 4 } } },
		}, {}, identity)
		local body_line
		for i, l in ipairs(result.lines) do
			if l == "the body" then
				body_line = i
			end
		end
		assert.are.same({ "the body", "", "🎉 4" }, vim.list_slice(result.lines, body_line, body_line + 2))
		assert.truthy(result.lines[body_line + 4]:find("^## COMMENTS"))
		-- No line without reactions
		local plain = format.build_overview_left_lines({ number = 1, title = "T", body = "the body" }, {}, identity)
		assert.truthy(vim.tbl_contains(plain.lines, "the body"))
		assert.is_false(vim.tbl_contains(plain.lines, "🎉 4"))
	end)

	it("find_pr_reaction_target uses issues/<n>/reactions and refuses without a PR", function()
		assert.are.equal(
			"repos/o/r/issues/12/reactions",
			reactions.find_pr_reaction_target({ number = 12 }, {}, "repos/o/r")
		)
		local path, reason = reactions.find_pr_reaction_target({ number = 12 }, { is_local = true }, "repos/o/r")
		assert.is_nil(path)
		assert.truthy(reason:find("Local"))
		assert.is_nil(reactions.find_pr_reaction_target(nil, {}, "repos/o/r"))
		assert.is_nil(reactions.find_pr_reaction_target({ number = vim.NIL }, {}, "repos/o/r"))
	end)

	it("pick_pr toggles the PR's reactions in the PR's repository and updates pr_info", function()
		local gh = require("fude.gh")
		require("fude.config").state.github_user = "me"
		local listing = {}
		local calls = {}
		helpers.mock(gh, "get_reactions", function(path, cb)
			table.insert(calls, { "get", path })
			cb(nil, listing)
		end)
		helpers.mock(gh, "add_reaction", function(path, content, cb)
			table.insert(calls, { "add", path, content })
			table.insert(listing, { id = 9, content = content, user = { login = "me" } })
			cb(nil, {})
		end)
		helpers.mock(vim, "notify", function() end)
		local opened
		helpers.mock(require("fude.ui.toggle_picker"), "open", function(opts)
			opened = opts
		end)
		local pr_info = { number = 12, url = "https://github.com/o/r/pull/12" }
		local redrawn
		reactions.pick_pr(pr_info, { pr_url = "https://github.com/x/y/pull/1" }, function(t)
			redrawn = t
		end)
		assert.are.equal("Reactions", opened.title)
		opened.on_toggle(opened.items[1], function() end)
		assert.are.same({ "add", "repos/o/r/issues/12/reactions", "+1" }, calls[2])
		assert.are.equal(pr_info, redrawn)
		assert.are.equal(1, pr_info.reactions["+1"])
		helpers.cleanup()
	end)
end)

describe("+ in the PR overview", function()
	local ui = require("fude.ui")

	before_each(function()
		require("fude.config").setup({})
	end)

	after_each(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		helpers.cleanup()
	end)

	it("reacts to the PR off any comment, to the comment on one, and redraws the pane", function()
		local picked = {}
		helpers.mock(reactions, "pick_pr", function(pr_info, _, on_done)
			table.insert(picked, "pr")
			pr_info.reactions = { heart = 2, total_count = 2 }
			on_done(pr_info)
		end)
		helpers.mock(reactions, "pick", function(comment, _, on_done)
			table.insert(picked, comment.id)
			on_done(comment)
		end)
		local pr_info = {
			number = 1,
			title = "T",
			body = "the body",
			url = "https://github.com/o/r/pull/1",
			reviewRequests = {},
			latestReviews = {},
			statusCheckRollup = {},
		}
		local comments = { { id = 77, user = { login = "a" }, body = "c", created_at = "" } }
		ui.show_overview_float(pr_info, comments, {})
		local win = vim.api.nvim_get_current_win()
		local buf = vim.api.nvim_win_get_buf(win)
		local function line_of(text)
			for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
				if l == text then
					return i
				end
			end
		end
		vim.api.nvim_win_set_cursor(win, { line_of("the body"), 0 })
		vim.fn.maparg("+", "n", false, true).callback()
		assert.are.same({ "pr" }, picked)
		local body = line_of("the body")
		assert.are.equal("❤️ 2", vim.api.nvim_buf_get_lines(buf, body + 1, body + 2, false)[1])

		vim.api.nvim_win_set_cursor(win, { line_of("c"), 0 })
		vim.fn.maparg("+", "n", false, true).callback()
		assert.are.same({ "pr", 77 }, picked)
	end)
end)

describe("reactions.show_people", function()
	local config = require("fude.config")
	local saved

	before_each(function()
		saved = package.loaded["snacks.picker"]
	end)

	after_each(function()
		package.loaded["snacks.picker"] = saved
		helpers.cleanup()
	end)

	it("vim.ui.select: shows even a single user instead of choosing it", function()
		config.setup({ file_list_mode = "quickfix" })
		local shown
		helpers.mock(vim.ui, "select", function(items, _, on_choice)
			shown = items
			on_choice(nil)
		end)
		local cancelled = false
		reactions.show_people({ "solo" }, "t", function() end, function()
			cancelled = true
		end)
		assert.are.same({ "solo" }, shown)
		assert.is_true(helpers.wait_for(function()
			return cancelled
		end))
	end)

	it("snacks: never auto-confirms, <CR> picks, any other close goes back once", function()
		config.setup({ file_list_mode = "snacks" })
		local popts
		package.loaded["snacks.picker"] = {
			pick = function(o)
				popts = o
			end,
		}
		local picked, cancels = nil, 0
		local function open()
			reactions.show_people({ "solo" }, "👍 +1 reacted by 1", function(login)
				picked = login
			end, function()
				cancels = cancels + 1
			end)
		end
		open()
		assert.is_false(popts.auto_confirm)
		assert.are.equal("👍 +1 reacted by 1", popts.title)
		assert.are.equal("@solo", popts.format(popts.items[1])[1][1])
		local picker = {
			close = function()
				popts.on_close()
			end,
		}
		popts.confirm(picker, popts.items[1])
		assert.is_true(helpers.wait_for(function()
			return picked == "solo"
		end))
		vim.wait(20)
		assert.are.equal(0, cancels)

		open()
		popts.on_close()
		popts.on_close()
		assert.is_true(helpers.wait_for(function()
			return cancels == 1
		end))
		vim.wait(20)
		assert.are.equal(1, cancels)
	end)
end)

describe("reactions.find_line_targets", function()
	it("keeps the comments that can be reacted to, in the line's order", function()
		local comments = {
			{ id = 1, path = "a.lua" },
			{ id = 2, path = "a.lua", pull_request_review_id = 9 },
			{ id = 3, path = "a.lua" },
		}
		local targets = reactions.find_line_targets(comments, { pending_review_id = 9 })
		assert.are.same({ comments[1], comments[3] }, targets)
	end)

	it("returns why nothing on the line can be reacted to", function()
		local cases = {
			{ {}, {}, "No comments on this line" },
			{ nil, {}, "No comments on this line" },
			{ { { id = 1, path = "a" } }, { is_local = true }, "Local" },
			{ { { id = 1, path = "a", pull_request_review_id = 5 } }, { pending_review_id = 5 }, "Pending" },
			{ { { id = 1, is_review_summary = true } }, {}, "Review summaries" },
		}
		for _, case in ipairs(cases) do
			local targets, reason = reactions.find_line_targets(case[1], case[2])
			assert.is_nil(targets)
			assert.truthy(reason:find(case[3], 1, true), reason)
		end
	end)
end)

describe("reactions.format_comment_choice", function()
	it("shows the login and the first non-blank body line", function()
		assert.are.equal(
			"@alice: second line",
			reactions.format_comment_choice({ user = { login = "alice" }, body = "\r\n  \r\n  second line\nthird" })
		)
	end)

	it("cuts a long first line and tolerates a missing login or body", function()
		local long = string.rep("あ", reactions.CHOICE_BODY_WIDTH + 5)
		assert.are.equal(
			"@a: " .. string.rep("あ", reactions.CHOICE_BODY_WIDTH) .. "…",
			reactions.format_comment_choice({ user = { login = "a" }, body = long })
		)
		assert.are.equal("@unknown: ", reactions.format_comment_choice({ user = vim.NIL, body = vim.NIL }))
	end)
end)

describe("reactions.react_at_cursor", function()
	local config = require("fude.config")
	local comments_mod = require("fude.comments")
	local picked, notified, line_comments

	before_each(function()
		config.setup({})
		picked, notified = {}, {}
		line_comments = {}
		helpers.mock(reactions, "pick", function(comment)
			table.insert(picked, comment)
		end)
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notified, { msg = msg, level = level })
		end)
		helpers.mock(require("fude.diff"), "to_repo_relative", function()
			return "a.lua"
		end)
		helpers.mock(comments_mod, "get_comments_at", function(path, line)
			assert.are.equal("a.lua", path)
			assert.are.equal(1, line)
			return line_comments
		end)
		vim.api.nvim_set_current_buf(helpers.create_buf({ "x" }, "/repo/a.lua"))
		config.state.active = true
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("runs the handler registered for the current buffer instead of reading the line", function()
		local ran = 0
		local buf = vim.api.nvim_get_current_buf()
		reactions.set_buffer_handler(buf, function()
			ran = ran + 1
		end)
		config.state.active = false
		reactions.react_at_cursor()
		assert.are.equal(1, ran)
		assert.are.equal(0, #notified)

		-- A wiped buffer's handler is gone: a new buffer reusing nothing of it
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.api.nvim_set_current_buf(helpers.create_buf({ "x" }, "/repo/a.lua"))
		config.state.active = true
		reactions.react_at_cursor()
		assert.are.equal(1, ran)
	end)

	it("opens the picker at once for the line's only reactable comment", function()
		line_comments = { { id = 1, path = "a.lua", pull_request_review_id = 9 }, { id = 2, path = "a.lua" } }
		config.state.pending_review_id = 9
		reactions.react_at_cursor()
		assert.are.same({ line_comments[2] }, picked)
	end)

	it("asks which comment when the line has several", function()
		line_comments = {
			{ id = 1, path = "a.lua", user = { login = "a" }, body = "one" },
			{ id = 2, path = "a.lua", user = { login = "b" }, body = "two" },
		}
		local shown, kind
		helpers.mock(vim.ui, "select", function(items, opts, on_choice)
			shown = vim.tbl_map(opts.format_item, items)
			kind = opts.kind
			on_choice(items[2])
		end)
		reactions.react_at_cursor()
		assert.are.same({ "@a: one", "@b: two" }, shown)
		assert.are.equal("fude_reaction_target", kind)
		assert.are.same({ line_comments[2] }, picked)

		-- Cancelling the choice opens nothing
		picked = {}
		helpers.mock(vim.ui, "select", function(_, _, on_choice)
			on_choice(nil)
		end)
		reactions.react_at_cursor()
		assert.are.equal(0, #picked)
	end)

	it("notifies the reason at INFO when nothing on the line can be reacted to", function()
		reactions.react_at_cursor()
		assert.are.equal(0, #picked)
		assert.are.same({ msg = "fude.nvim: No comments on this line", level = vim.log.levels.INFO }, notified[1])

		config.state.review_mode = "local"
		line_comments = { { id = 1, path = "a.lua" } }
		reactions.react_at_cursor()
		assert.are.equal(0, #picked)
		assert.truthy(notified[2].msg:find("Local review", 1, true))
		assert.are.equal(vim.log.levels.INFO, notified[2].level)
	end)

	it("warns outside a review", function()
		config.state.active = false
		reactions.react_at_cursor()
		assert.are.equal(0, #picked)
		assert.are.same({ msg = "fude.nvim: Not active", level = vim.log.levels.WARN }, notified[1])
	end)
end)

describe(":FudeReviewReact in the comment UIs", function()
	local ui = require("fude.ui")

	before_each(function()
		require("fude.config").setup({})
	end)

	after_each(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		helpers.cleanup()
	end)

	it("reacts to the comment under the cursor in the comment viewer", function()
		local picked
		helpers.mock(reactions, "pick", function(comment)
			picked = comment
		end)
		local comments = {
			{ id = 1, user = { login = "a" }, created_at = "", body = "first" },
			{ id = 2, user = { login = "b" }, created_at = "", body = "second" },
		}
		ui.show_comments_float(comments)
		local win = vim.api.nvim_get_current_win()
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		for i, l in ipairs(lines) do
			if l == "second" then
				vim.api.nvim_win_set_cursor(win, { i, 0 })
			end
		end
		reactions.react_at_cursor()
		assert.are.equal(comments[2], picked)
	end)

	it("reacts to the PR in the overview's right pane and to a comment in the left one", function()
		local picked = {}
		helpers.mock(reactions, "pick_pr", function()
			table.insert(picked, "pr")
		end)
		helpers.mock(reactions, "pick", function(comment)
			table.insert(picked, comment.id)
		end)
		local pr_info = {
			number = 1,
			title = "T",
			body = "the body",
			url = "https://github.com/o/r/pull/1",
			reviewRequests = {},
			latestReviews = {},
			statusCheckRollup = {},
		}
		ui.show_overview_float(pr_info, { { id = 77, user = { login = "a" }, body = "c", created_at = "" } }, {})
		local left_win = vim.api.nvim_get_current_win()
		for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
			if l == "c" then
				vim.api.nvim_win_set_cursor(left_win, { i, 0 })
			end
		end
		reactions.react_at_cursor()
		local right_win
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if win ~= left_win and vim.api.nvim_win_get_config(win).relative ~= "" then
				right_win = win
			end
		end
		vim.api.nvim_set_current_win(right_win)
		reactions.react_at_cursor()
		assert.are.same({ 77, "pr" }, picked)
	end)
end)
