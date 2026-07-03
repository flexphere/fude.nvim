local tracker = require("fude.local.tracker")
local local_sync = require("fude.comments.local_sync")
local session = require("fude.local.session")
local store = require("fude.local.store")
local config = require("fude.config")
local helpers = require("tests.helpers")

describe("store.materialize reply position inheritance", function()
	it("replies inherit the root's path and line", function()
		local result = store.materialize({
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 3, end_line = 3, body = "root" }),
			store.build_reply_event({ id = "r1", thread_id = "c1", body = "reply" }),
		})
		assert.equals("f.lua", result.comments[2].path)
		assert.equals(3, result.comments[2].line)
	end)

	it("replies follow the root's move events", function()
		local result = store.materialize({
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 3, end_line = 3, body = "root" }),
			store.build_reply_event({ id = "r1", thread_id = "c1", body = "reply" }),
			store.build_move_event({ id = "c1", path = "f.lua", start_line = 7, end_line = 7 }),
		})
		assert.equals(7, result.comments[1].line)
		assert.equals(7, result.comments[2].line)
	end)

	it("replies of a deleted root stay unanchored", function()
		local result = store.materialize({
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 3, end_line = 3, body = "root" }),
			store.build_reply_event({ id = "r1", thread_id = "c1", body = "reply" }),
			store.build_delete_event({ id = "c1" }),
		})
		assert.equals(1, #result.comments)
		assert.is_nil(result.comments[1].line)
	end)
end)

describe("tracker line re-anchoring", function()
	local tmp_store, tmp_repo, buf

	local function start_session()
		local diff = require("fude.diff")
		local fns = {
			get_repo_root = function()
				return tmp_repo
			end,
			get_default_branch = function()
				return "main"
			end,
			get_merge_base = function()
				return "basesha"
			end,
			get_head_sha = function()
				return "headsha"
			end,
			get_current_branch = function()
				return "feat/x"
			end,
			get_git_user = function()
				return "flexphere"
			end,
			get_name_status = function()
				return "M\tf.lua\n"
			end,
			get_numstat = function()
				return "2\t1\tf.lua\n"
			end,
			get_untracked = function()
				return ""
			end,
		}
		for name, fn in pairs(fns) do
			helpers.mock(diff, name, fn)
		end
		session.start(nil)
	end

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.writefile({ "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		config.setup({})
		start_session()

		buf = helpers.create_buf({ "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		local diff = require("fude.diff")
		helpers.mock(diff, "to_repo_relative", function(filepath)
			if filepath:find("f.lua", 1, true) then
				return "f.lua"
			end
			return nil
		end)
	end)

	after_each(function()
		tracker.teardown()
		if config.state.active then
			session.stop()
		end
		store._dir = nil
		vim.fn.delete(tmp_store, "rf")
		vim.fn.delete(tmp_repo, "rf")
		helpers.cleanup()
	end)

	it("collect_moves reports drift after inserting lines above a comment", function()
		local_sync.create_comment("f.lua", 3, 3, "anchored", nil, function() end)
		tracker.sync_buffer(buf, "f.lua")

		-- Insert two lines at the top: comment line 3 should drift to 5
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new1", "new2" })

		local moves = tracker.collect_moves(buf)
		assert.equals(1, #moves)
		assert.equals(5, moves[1].end_line)
		assert.equals(5, moves[1].start_line)
		assert.equals("f.lua", moves[1].path)
	end)

	it("collect_moves is empty when nothing drifted", function()
		local_sync.create_comment("f.lua", 3, 3, "anchored", nil, function() end)
		tracker.sync_buffer(buf, "f.lua")
		assert.same({}, tracker.collect_moves(buf))
	end)

	it("tracks range comments with both endpoints", function()
		local_sync.create_comment("f.lua", 2, 4, "ranged", nil, function() end)
		tracker.sync_buffer(buf, "f.lua")

		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new1" })

		local moves = tracker.collect_moves(buf)
		assert.equals(1, #moves)
		assert.equals(3, moves[1].start_line)
		assert.equals(5, moves[1].end_line)
	end)

	it("on_buf_write persists moves and updates comment state", function()
		local_sync.create_comment("f.lua", 3, 3, "anchored", nil, function() end)
		local comment_id = config.state.comments[1].id
		tracker.sync_buffer(buf, "f.lua")

		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new1", "new2" })
		tracker.on_buf_write(buf)

		assert.equals(5, config.state.comments[1].line)
		assert.is_not_nil(config.state.comment_map["f.lua"][5])

		local events = store.read_events(config.state.local_session.file)
		local last = events[#events]
		assert.equals("move", last.event)
		assert.equals(comment_id, last.id)
		assert.equals(5, last.end_line)
	end)

	it("on_buf_write is a no-op without drift", function()
		local_sync.create_comment("f.lua", 3, 3, "anchored", nil, function() end)
		tracker.sync_buffer(buf, "f.lua")
		local before = #store.read_events(config.state.local_session.file)
		tracker.on_buf_write(buf)
		assert.equals(before, #store.read_events(config.state.local_session.file))
	end)

	it("replies stay attached to the moved root line", function()
		local_sync.create_comment("f.lua", 3, 3, "root", nil, function() end)
		local root_id = config.state.comments[1].id
		local_sync.reply_to_comment(root_id, "reply", function() end)
		tracker.sync_buffer(buf, "f.lua")

		vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new1" })
		tracker.on_buf_write(buf)

		local at_line = config.state.comment_map["f.lua"][4]
		assert.equals(2, #at_line)
	end)
end)
