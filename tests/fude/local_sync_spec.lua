local local_sync = require("fude.comments.local_sync")
local session = require("fude.local.session")
local store = require("fude.local.store")
local config = require("fude.config")
local helpers = require("tests.helpers")

--- Start a mocked local session against a tmp repo containing f.lua.
local function start_session(tmp_repo)
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

describe("local_sync CRUD", function()
	local tmp_store, tmp_repo

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.writefile({ "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		config.setup({})
		start_session(tmp_repo)
	end)

	after_each(function()
		if config.state.active then
			session.stop()
		end
		store._dir = nil
		vim.fn.delete(tmp_store, "rf")
		vim.fn.delete(tmp_repo, "rf")
		helpers.cleanup()
	end)

	local function create_comment(body, start_line, end_line)
		local err_result
		local_sync.create_comment("f.lua", start_line or 2, end_line or 2, body, "ctx", function(err)
			err_result = err
		end)
		assert.is_nil(err_result)
		return config.state.comments[#config.state.comments]
	end

	it("create_comment appends and refreshes state", function()
		local comment = create_comment("first comment")
		assert.equals("first comment", comment.body)
		assert.equals("flexphere", comment.user.login)
		assert.equals("human", comment.author_type)
		assert.is_not_nil(config.state.comment_map["f.lua"][2])

		local events = store.read_events(config.state.local_session.file)
		assert.equals("comment", events[#events].event)
		assert.equals("ctx", events[#events].context)
	end)

	it("reply_to_comment builds a thread", function()
		local root = create_comment("root")
		local err_result
		local_sync.reply_to_comment(root.id, "a reply", function(err)
			err_result = err
		end)
		assert.is_nil(err_result)

		local data = require("fude.comments.data")
		local thread = data.get_comment_thread(root.id, config.state.comments)
		assert.equals(2, #thread)
		assert.equals(root.id, thread[2].in_reply_to_id)
	end)

	it("edit_comment replaces the body", function()
		local comment = create_comment("before")
		local_sync.edit_comment(comment.id, "after", function() end)
		assert.equals("after", config.state.comments[1].body)
	end)

	it("delete_comment hides the comment but keeps the audit trail", function()
		local comment = create_comment("to delete")
		local_sync.delete_comment(comment.id, function() end)
		assert.equals(0, #config.state.comments)

		local events = store.read_events(config.state.local_session.file)
		assert.equals("delete", events[#events].event)
	end)

	it("toggle_resolved resolves then reopens a thread", function()
		local root = create_comment("resolve me")

		local resolved_state
		local_sync.toggle_resolved(root.id, false, function(_, resolved)
			resolved_state = resolved
		end)
		assert.is_true(resolved_state)
		assert.is_true(config.state.comments[1].resolved)

		local_sync.toggle_resolved(root.id, true, function(_, resolved)
			resolved_state = resolved
		end)
		assert.is_false(resolved_state)
		assert.is_false(config.state.comments[1].resolved)
	end)

	it("operations fail with an error when no session is active", function()
		session.stop()
		local err_result
		local_sync.create_comment("f.lua", 1, 1, "x", nil, function(err)
			err_result = err
		end)
		assert.equals("Not active", err_result)
	end)

	it("set_viewed persists and updates state.viewed_files", function()
		local_sync.set_viewed("f.lua", true, function() end)
		assert.equals("VIEWED", config.state.viewed_files["f.lua"])

		local events = store.read_events(config.state.local_session.file)
		assert.equals("viewed", events[#events].event)
		assert.is_true(events[#events].viewed)

		local_sync.set_viewed("f.lua", false, function() end)
		assert.equals("UNVIEWED", config.state.viewed_files["f.lua"])
	end)

	it("viewed state survives a reload from disk", function()
		local_sync.set_viewed("f.lua", true, function() end)
		session.reload(true)
		assert.equals("VIEWED", config.state.viewed_files["f.lua"])
	end)
end)

describe("files.apply_viewed_toggle in local mode", function()
	local files = require("fude.files")
	local tmp_store, tmp_repo

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.writefile({ "l1", "l2" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		config.setup({})
		start_session(tmp_repo)
	end)

	after_each(function()
		if config.state.active then
			session.stop()
		end
		store._dir = nil
		vim.fn.delete(tmp_store, "rf")
		vim.fn.delete(tmp_repo, "rf")
		helpers.cleanup()
	end)

	it("toggles viewed state via the local backend (no gh)", function()
		local updated
		files.apply_viewed_toggle("f.lua", function(u)
			updated = u
		end)
		assert.is_not_nil(updated)
		assert.equals("VIEWED", updated.viewed_state)
		assert.equals("VIEWED", config.state.viewed_files["f.lua"])

		files.apply_viewed_toggle("f.lua", function(u)
			updated = u
		end)
		assert.equals("UNVIEWED", updated.viewed_state)
		assert.equals("UNVIEWED", config.state.viewed_files["f.lua"])
	end)
end)

describe("comments facade in local mode", function()
	local comments = require("fude.comments")
	local tmp_store, tmp_repo

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.writefile({ "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		config.setup({})
		start_session(tmp_repo)
		helpers.mock_diff({ ["f.lua"] = "f.lua" })
	end)

	after_each(function()
		if config.state.active then
			session.stop()
		end
		store._dir = nil
		vim.fn.delete(tmp_store, "rf")
		vim.fn.delete(tmp_repo, "rf")
		helpers.cleanup()
	end)

	it("create_comment routes to the local backend", function()
		local ui = require("fude.ui")
		helpers.mock(ui, "open_comment_input", function(cb, opts)
			assert.is_false(opts.allow_draft)
			cb("via facade")
		end)

		local buf = helpers.create_buf({ "line1", "line2", "line3" }, tmp_repo .. "/f.lua")
		vim.api.nvim_win_set_buf(0, buf)
		comments.create_comment(false)

		assert.equals(1, #config.state.comments)
		assert.equals("via facade", config.state.comments[1].body)
	end)

	it("toggle_resolve resolves the thread on the current line", function()
		local_sync.create_comment("f.lua", 1, 1, "root", nil, function() end)

		local buf = helpers.create_buf({ "line1", "line2", "line3" }, tmp_repo .. "/f.lua")
		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })

		comments.toggle_resolve()
		assert.is_true(config.state.comments[1].resolved)

		comments.toggle_resolve()
		assert.is_false(config.state.comments[1].resolved)
	end)

	it("suggest_change routes to the local backend with a suggestion template", function()
		local ui = require("fude.ui")
		local seen_initial
		helpers.mock(ui, "open_comment_input", function(cb, opts)
			seen_initial = opts.initial_lines
			cb(table.concat(opts.initial_lines, "\n"))
		end)

		local buf = helpers.create_buf({ "target line" }, tmp_repo .. "/f.lua")
		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		comments.suggest_change(false)

		assert.same({ "```suggestion", "target line", "```" }, seen_initial)
		assert.equals(1, #config.state.comments)
		assert.is_truthy(config.state.comments[1].body:find("```suggestion", 1, true))
	end)
end)

describe("format.comment_badges", function()
	local format = require("fude.ui.format")

	it("returns empty for plain GitHub comments", function()
		assert.equals("", format.comment_badges({ user = { login = "a" } }))
	end)

	it("labels agent comments", function()
		assert.equals(" [agent]", format.comment_badges({ author_type = "agent" }))
	end)

	it("labels resolved threads", function()
		assert.equals(" [resolved]", format.comment_badges({ resolved = true }))
	end)

	it("combines both badges", function()
		assert.equals(" [agent] [resolved]", format.comment_badges({ author_type = "agent", resolved = true }))
	end)

	it("does not label human authors", function()
		assert.equals("", format.comment_badges({ author_type = "human" }))
	end)
end)
