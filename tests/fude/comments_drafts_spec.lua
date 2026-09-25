local config = require("fude.config")
local comments = require("fude.comments")
local drafts = require("fude.drafts")
local ui = require("fude.ui")
local sync = require("fude.comments.sync")
local helpers = require("tests.helpers")

describe("comments local draft wiring", function()
	local tmp

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.pr_number = 132
		config.state.pr_url = "https://github.com/owner/repo/pull/132"
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
		helpers.mock_diff({ ["draft_test.lua"] = "draft_test.lua" })
		helpers.mock(ui, "refresh_extmarks", function() end)
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
		helpers.cleanup()
		config.setup({})
	end)

	local function focus_test_buf()
		local buf = helpers.create_buf({ "line content" }, "draft_test.lua")
		vim.api.nvim_set_current_buf(buf)
		return buf
	end

	it("create_comment prefills initial_lines from an existing draft (draft > pending)", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)
		drafts.set(key, "saved draft body")
		-- A pending comment at the same location must lose to the local draft.
		config.state.pending_comments["draft_test.lua:1:1"] = { body = "pending body" }

		local captured
		helpers.mock(ui, "open_comment_input", function(_callback, opts)
			captured = opts
		end)

		comments.create_comment(false)
		assert.same({ "saved draft body" }, captured.initial_lines)
		assert.is_true(captured.allow_draft)
	end)

	it("suggest_change opens in normal mode below the fence, clamped for short drafts", function()
		focus_test_buf()
		local captured
		helpers.mock(ui, "open_comment_input", function(_callback, opts)
			captured = opts
		end)

		comments.suggest_change(false)
		assert.same({ 2, 0 }, captured.cursor_pos)

		-- restored multi-line draft: same position (cursor_pos also forces
		-- normal mode, protecting the fence from the first keystroke)
		drafts.set(drafts.current_key("suggest", "draft_test.lua", 1, 1), "```suggestion\nsaved\n```")
		captured = nil
		comments.suggest_change(false)
		assert.same({ "```suggestion", "saved", "```" }, captured.initial_lines)
		assert.same({ 2, 0 }, captured.cursor_pos)

		-- single-line restored draft: clamped so nvim_win_set_cursor stays valid
		drafts.set(drafts.current_key("suggest", "draft_test.lua", 1, 1), "one liner")
		captured = nil
		comments.suggest_change(false)
		assert.same({ "one liner" }, captured.initial_lines)
		assert.same({ 1, 0 }, captured.cursor_pos)
	end)

	it("create_comment with action 'draft' saves the typed text", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)

		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback("work in progress", "draft")
		end)

		comments.create_comment(false)
		assert.equals("work in progress", drafts.get(key))
	end)

	it("create_comment submit removes the draft only after the pending save succeeds", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)
		drafts.set(key, "old draft")

		helpers.mock(sync, "sync_pending_review", function(callback)
			callback(nil)
		end)
		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback("final comment", "submit")
		end)

		comments.create_comment(false)
		-- Removal happens inside vim.schedule on success.
		helpers.wait_for(function()
			return drafts.get(key) == nil
		end)
		assert.is_nil(drafts.get(key))
	end)

	it("create_comment keeps the draft when the pending sync fails", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)
		drafts.set(key, "old draft")

		helpers.mock(sync, "sync_pending_review", function(callback)
			callback("network boom")
		end)
		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback("final comment", "submit")
		end)

		comments.create_comment(false)
		-- Failure path clears the optimistic pending entry; use that as the sync point.
		helpers.wait_for(function()
			return config.state.pending_comments["draft_test.lua:1:1"] == nil
		end)
		assert.equals("old draft", drafts.get(key))
	end)

	it("create_comment with action 'discard' removes the draft", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)
		drafts.set(key, "old draft")

		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback(nil, "discard")
		end)

		comments.create_comment(false)
		assert.is_nil(drafts.get(key))
	end)

	it("create_comment cancel leaves an existing draft untouched", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)
		drafts.set(key, "keep me")

		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback(nil, "cancel")
		end)

		comments.create_comment(false)
		assert.equals("keep me", drafts.get(key))
	end)

	it("reply_to_comment prefills from a draft and saves via on_save_draft", function()
		local data = require("fude.comments.data")
		helpers.mock(data, "get_comment_thread", function()
			return { { id = 7, body = "root" } }
		end)
		helpers.mock(data, "get_reply_target_id", function()
			return 7
		end)
		local key = drafts.current_key("reply", 7)
		drafts.set(key, "draft reply")

		local captured
		helpers.mock(ui, "open_reply_window", function(_thread, opts)
			captured = opts
		end)

		comments.reply_to_comment(7)
		assert.same({ "draft reply" }, captured.initial_lines)
		captured.on_save_draft("updated reply")
		assert.equals("updated reply", drafts.get(key))
		captured.on_discard_draft()
		assert.is_nil(drafts.get(key))
	end)

	it("reply_to_comment submit removes the draft", function()
		local data = require("fude.comments.data")
		helpers.mock(data, "get_comment_thread", function()
			return { { id = 7, body = "root" } }
		end)
		helpers.mock(data, "get_reply_target_id", function()
			return 7
		end)
		helpers.mock(sync, "reply_to_comment", function(_id, _body, callback)
			callback(nil)
		end)
		local key = drafts.current_key("reply", 7)
		drafts.set(key, "draft reply")

		helpers.mock(ui, "open_reply_window", function(_thread, opts)
			opts.on_submit("final reply")
		end)

		comments.reply_to_comment(7)
		assert.is_nil(drafts.get(key))
	end)

	it("reply_to_comment keeps the draft when the reply fails", function()
		local data = require("fude.comments.data")
		helpers.mock(data, "get_comment_thread", function()
			return { { id = 7, body = "root" } }
		end)
		helpers.mock(data, "get_reply_target_id", function()
			return 7
		end)
		helpers.mock(sync, "reply_to_comment", function(_id, _body, callback)
			callback("reply boom")
		end)
		local key = drafts.current_key("reply", 7)
		drafts.set(key, "draft reply")

		helpers.mock(ui, "open_reply_window", function(_thread, opts)
			opts.on_submit("final reply")
		end)

		comments.reply_to_comment(7)
		assert.equals("draft reply", drafts.get(key))
	end)

	it("edit_comment prefers a draft over the comment body for prefill", function()
		local data = require("fude.comments.data")
		config.state.github_user = "me"
		helpers.mock(data, "find_comment_by_id", function()
			return { comment = { id = 9, body = "original body", user = { login = "me" } } }
		end)
		helpers.mock(data, "get_comment_thread", function()
			return { { id = 9, body = "original body", user = { login = "me" } } }
		end)
		local key = drafts.current_key("edit", 9)
		drafts.set(key, "draft edit")

		local captured
		helpers.mock(ui, "open_edit_window", function(_thread, _comment, opts)
			captured = opts
		end)

		comments.edit_comment(9)
		assert.same({ "draft edit" }, captured.initial_lines)
	end)
end)

describe("comments single comment submit", function()
	local tmp

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.pr_number = 132
		config.state.pr_url = "https://github.com/owner/repo/pull/132"
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		drafts._dir = tmp
		helpers.mock_diff({ ["single_test.lua"] = "single_test.lua" })
		helpers.mock(ui, "refresh_extmarks", function() end)
		local buf = helpers.create_buf({ "line content" }, "single_test.lua")
		vim.api.nvim_set_current_buf(buf)
	end)

	after_each(function()
		drafts._dir = nil
		vim.fn.delete(tmp, "rf")
		helpers.cleanup()
		config.setup({})
	end)

	-- create_comment and suggest_change wire the single path separately, so
	-- every case runs against both entry points.
	local entry_points = {
		{ name = "create_comment", kind = "line", run = comments.create_comment },
		{ name = "suggest_change", kind = "suggest", run = comments.suggest_change },
	}

	for _, ep in ipairs(entry_points) do
		it(ep.name .. " posts a single comment without touching pending_comments", function()
			local key = drafts.current_key(ep.kind, "single_test.lua", 1, 1)
			drafts.set(key, "old draft")
			local posted
			helpers.mock(sync, "create_single_comment", function(path, s_line, e_line, body, callback)
				posted = { path = path, start_line = s_line, end_line = e_line, body = body }
				callback(nil)
			end)
			local synced = false
			helpers.mock(sync, "sync_pending_review", function()
				synced = true
			end)
			helpers.mock(ui, "open_comment_input", function(callback, _opts)
				callback("single body", "single")
			end)

			ep.run(false)
			assert.same({ path = "single_test.lua", start_line = 1, end_line = 1, body = "single body" }, posted)
			assert.is_false(synced)
			assert.same({}, config.state.pending_comments)
			assert.is_nil(drafts.get(key))
		end)

		it(ep.name .. " keeps the draft when the single comment fails", function()
			local key = drafts.current_key(ep.kind, "single_test.lua", 1, 1)
			drafts.set(key, "old draft")
			helpers.mock(sync, "create_single_comment", function(_, _, _, _, callback)
				callback("Validation Failed")
			end)
			helpers.mock(ui, "open_comment_input", function(callback, _opts)
				callback("single body", "single")
			end)

			ep.run(false)
			assert.equals("old draft", drafts.get(key))
		end)

		it(ep.name .. " offers review and single choices when no pending review exists", function()
			local opts_captured
			helpers.mock(ui, "open_comment_input", function(_callback, opts)
				opts_captured = opts
			end)
			local items
			local on_choice
			helpers.mock(vim.ui, "select", function(its, _, cb)
				items = its
				on_choice = cb
			end)

			ep.run(false)
			local kinds = {}
			opts_captured.pick_submit_kind(function(kind)
				table.insert(kinds, kind or "nil")
			end)
			assert.same(
				{ "review", "single" },
				vim.tbl_map(function(i)
					return i.kind
				end, items)
			)
			on_choice(items[2])
			on_choice(nil)
			assert.same({ "single", "nil" }, kinds)
		end)

		it(ep.name .. " skips the choice while the first pending sync is in flight", function()
			config.state.pending_comments = { ["other.lua:3:3"] = { body = "queued" } }
			local opts_captured
			helpers.mock(ui, "open_comment_input", function(_callback, opts)
				opts_captured = opts
			end)
			local selected = false
			helpers.mock(vim.ui, "select", function()
				selected = true
			end)

			ep.run(false)
			local picked
			opts_captured.pick_submit_kind(function(kind)
				picked = kind
			end)
			assert.equals("review", picked)
			assert.is_false(selected)
		end)

		it(ep.name .. " skips the choice and uses the review while a pending review exists", function()
			config.state.pending_review_id = 5
			local opts_captured
			helpers.mock(ui, "open_comment_input", function(_callback, opts)
				opts_captured = opts
			end)
			local selected = false
			helpers.mock(vim.ui, "select", function()
				selected = true
			end)

			ep.run(false)
			local picked
			opts_captured.pick_submit_kind(function(kind)
				picked = kind
			end)
			assert.equals("review", picked)
			assert.is_false(selected)
		end)
	end
end)
