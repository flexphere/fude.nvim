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

	it("create_comment with action 'draft' saves the typed text", function()
		focus_test_buf()
		local key = drafts.current_key("line", "draft_test.lua", 1, 1)

		helpers.mock(ui, "open_comment_input", function(callback, _opts)
			callback("work in progress", "draft")
		end)

		comments.create_comment(false)
		assert.equals("work in progress", drafts.get(key))
	end)

	it("create_comment submit removes the draft for that location", function()
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
		assert.is_nil(drafts.get(key))
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
