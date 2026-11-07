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

	it("format_reaction_detail shows the count and what <Tab> does", function()
		assert.are.equal("2 · <Tab>: remove", reactions.format_reaction_detail(2, true))
		assert.are.equal("1 · <Tab>: add", reactions.format_reaction_detail(1, false))
		assert.are.equal("<Tab>: add", reactions.format_reaction_detail(0, false))
		assert.are.equal("<Tab>: add", reactions.format_reaction_detail(nil, false))
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
		assert.are.equal("1 · <Tab>: remove", item_for(opts, "heart").detail(item_for(opts, "heart")))
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
		-- The row's count follows the new listing
		assert.are.equal("1 · <Tab>: add", item.detail(item))
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
