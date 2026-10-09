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

	it("load_comments normalizes resolved onto is_resolved for the whole thread", function()
		local root = create_comment("resolve me")
		local_sync.reply_to_comment(root.id, "a reply", function() end)
		local_sync.toggle_resolved(root.id, false, function() end)

		-- The display layer reads is_resolved; local review must populate it from
		-- the thread-level `resolved` flag, propagated to the reply as well.
		for _, c in ipairs(config.state.comments) do
			assert.is_true(c.is_resolved)
		end

		local_sync.toggle_resolved(root.id, true, function() end)
		for _, c in ipairs(config.state.comments) do
			assert.is_falsy(c.is_resolved)
		end
	end)

	it("resolved.show = false suppresses is_resolved normalization", function()
		config.opts.resolved.show = false
		local root = create_comment("resolve me")
		local_sync.toggle_resolved(root.id, false, function() end)

		-- The toggle source of truth (`resolved`) is still updated, but the
		-- display-facing is_resolved stays unset so nothing renders.
		assert.is_true(config.state.comments[1].resolved)
		assert.is_falsy(config.state.comments[1].is_resolved)
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

	it("re-anchors a comment on reload when the file content shifts on disk", function()
		-- f.lua initial content is line1..line5; comment anchors to line3 with
		-- its content as context.
		local_sync.create_comment("f.lua", 3, 3, "note", "line3", function() end)
		local comment_id = config.state.comments[1].id
		assert.equals(3, config.state.comments[1].line)

		-- External edit: insert two lines at the top, shifting line3 -> line5.
		vim.fn.writefile({ "new1", "new2", "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")

		session.reload(true)
		assert.equals(5, config.state.comments[1].line)
		assert.is_nil(config.state.comments[1].is_outdated)
		assert.is_not_nil(config.state.comment_map["f.lua"][5])

		-- The re-anchor was persisted as a move event.
		local events = store.read_events(config.state.local_session.file)
		local last = events[#events]
		assert.equals("move", last.event)
		assert.equals(comment_id, last.id)
		assert.equals(5, last.end_line)
	end)

	it("marks a comment outdated when its context vanished and its line is gone", function()
		-- Context "line3" is unfindable and the file is now shorter than line 3,
		-- so it cannot be re-anchored and falls through to outdated.
		local_sync.create_comment("f.lua", 3, 3, "note", "line3", function() end)
		vim.fn.writefile({ "only-one-line" }, tmp_repo .. "/f.lua")
		session.reload(true)
		assert.is_true(config.state.comments[1].is_outdated)
	end)

	it("does not persist a re-anchor move from an unsaved open buffer", function()
		-- Open f.lua in a loaded, MODIFIED buffer whose content differs from disk.
		local buf =
			helpers.create_buf({ "new1", "new2", "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		vim.bo[buf].modified = true

		local_sync.create_comment("f.lua", 3, 3, "note", "line3", function() end)
		local before = #store.read_events(config.state.local_session.file)

		-- Reload: disk still has the original file, the drift only exists in the
		-- unsaved buffer. reanchor must not write a move from buffer content.
		session.reload(true)
		local after = #store.read_events(config.state.local_session.file)
		assert.equals(before, after)
	end)

	it("reverts to on-disk positions when persisting a re-anchor move fails", function()
		local_sync.create_comment("f.lua", 3, 3, "note", "line3", function() end)

		-- Drift the file on disk so reanchor wants to move the comment to line 5.
		vim.fn.writefile({ "new1", "new2", "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")

		-- Make move-event persistence fail during the reload's reanchor pass.
		helpers.mock(store, "append_event", function()
			return false, "disk full"
		end)

		session.reload(true)

		-- State must match the on-disk (un-moved) position, not the in-memory
		-- reanchor, since the move could not be persisted.
		assert.equals(3, config.state.comments[1].line)
		assert.is_not_nil(config.state.comment_map["f.lua"][3])
	end)

	it("keeps a comment anchored when only its line content changed", function()
		-- Content edited in place (context gone) but the line still exists: the
		-- comment stays put rather than being falsely marked outdated.
		local_sync.create_comment("f.lua", 3, 3, "note", "line3", function() end)
		vim.fn.writefile({ "line1", "line2", "line3-edited", "line4", "line5" }, tmp_repo .. "/f.lua")
		session.reload(true)
		assert.equals(3, config.state.comments[1].line)
		assert.is_nil(config.state.comments[1].is_outdated)
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

	it("sidepanel <Tab> (toggle_file_viewed) routes to the local backend", function()
		-- The panel's file-row <Tab> must not require pr_node_id in local mode.
		local sidepanel = require("fude.ui.sidepanel")
		sidepanel.toggle_file_viewed(nil, { entry = { path = "f.lua" } })
		assert.equals("VIEWED", config.state.viewed_files["f.lua"])
	end)
end)

describe("comments facade in local mode", function()
	local comments = require("fude.comments")
	local drafts = require("fude.drafts")
	local tmp_store, tmp_repo, tmp_drafts

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		tmp_drafts = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.mkdir(tmp_drafts, "p")
		vim.fn.writefile({ "line1", "line2", "line3", "line4", "line5" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		drafts._dir = tmp_drafts
		config.setup({})
		start_session(tmp_repo)
		helpers.mock_diff({ ["f.lua"] = "f.lua" })
	end)

	after_each(function()
		if config.state.active then
			session.stop()
		end
		store._dir = nil
		drafts._dir = nil
		vim.fn.delete(tmp_store, "rf")
		vim.fn.delete(tmp_repo, "rf")
		vim.fn.delete(tmp_drafts, "rf")
		helpers.cleanup()
	end)

	local function focus_f_lua(line)
		local buf = helpers.create_buf({ "line1", "line2", "line3" }, tmp_repo .. "/f.lua")
		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
		return buf
	end

	it("create_comment routes to the local backend", function()
		local ui = require("fude.ui")
		helpers.mock(ui, "open_comment_input", function(cb, opts)
			assert.is_true(opts.allow_draft)
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

	describe("local drafts", function()
		local ui = require("fude.ui")

		before_each(function()
			helpers.mock(ui, "refresh_extmarks", function() end)
		end)

		it("create_comment with action 'draft' saves the text under the local session key", function()
			helpers.mock(ui, "open_comment_input", function(cb)
				cb("half written", "draft")
			end)
			focus_f_lua(2)
			comments.create_comment(false)

			assert.equals("half written", drafts.get(drafts.current_key("line", "f.lua", 2, 2)))
			assert.equals(0, #config.state.comments)
		end)

		it("create_comment prefills from a saved draft and removes it once saved", function()
			local key = drafts.current_key("line", "f.lua", 2, 2)
			drafts.set(key, "draft body\nsecond line")
			local seen_initial
			helpers.mock(ui, "open_comment_input", function(cb, opts)
				seen_initial = opts.initial_lines
				cb("final body", "submit")
			end)
			focus_f_lua(2)
			comments.create_comment(false)

			assert.same({ "draft body", "second line" }, seen_initial)
			assert.equals("final body", config.state.comments[1].body)
			assert.is_nil(drafts.get(key))
		end)

		it("create_comment keeps the draft when the local save fails", function()
			local key = drafts.current_key("line", "f.lua", 2, 2)
			drafts.set(key, "keep me")
			helpers.mock(local_sync, "create_comment", function(_, _, _, _, _, cb)
				cb("disk full")
			end)
			helpers.mock(ui, "open_comment_input", function(cb)
				cb("final body", "submit")
			end)
			focus_f_lua(2)
			comments.create_comment(false)

			assert.equals("keep me", drafts.get(key))
		end)

		it("create_comment with action 'discard' removes the draft", function()
			local key = drafts.current_key("line", "f.lua", 2, 2)
			drafts.set(key, "old")
			helpers.mock(ui, "open_comment_input", function(cb)
				cb(nil, "discard")
			end)
			focus_f_lua(2)
			comments.create_comment(false)

			assert.is_nil(drafts.get(key))
		end)

		it("create_comment cancel leaves an existing draft untouched", function()
			local key = drafts.current_key("line", "f.lua", 2, 2)
			drafts.set(key, "old")
			helpers.mock(ui, "open_comment_input", function(cb)
				cb(nil, "cancel")
			end)
			focus_f_lua(2)
			comments.create_comment(false)

			assert.equals("old", drafts.get(key))
		end)

		it("suggest_change restores a draft and clamps the cursor for a short one", function()
			drafts.set(drafts.current_key("suggest", "f.lua", 1, 1), "one line")
			local seen
			helpers.mock(ui, "open_comment_input", function(_, opts)
				seen = opts
			end)
			focus_f_lua(1)
			comments.suggest_change(false)

			assert.same({ "one line" }, seen.initial_lines)
			assert.same({ 1, 0 }, seen.cursor_pos)
			assert.is_true(seen.allow_draft)
		end)

		it("suggest_change keeps the cursor below the fence without a draft", function()
			local seen
			helpers.mock(ui, "open_comment_input", function(_, opts)
				seen = opts
			end)
			focus_f_lua(1)
			comments.suggest_change(false)

			assert.same({ 2, 0 }, seen.cursor_pos)
		end)

		it("reply_to_comment offers the save-draft option and saves under the local key", function()
			local_sync.create_comment("f.lua", 1, 1, "root", nil, function() end)
			local root_id = config.state.comments[1].id
			local seen
			helpers.mock(ui, "open_reply_window", function(_, opts)
				seen = opts
			end)
			comments.reply_to_comment(root_id)

			assert.is_true(seen.allow_draft)
			seen.on_save_draft("reply draft")
			assert.equals("reply draft", drafts.get(drafts.current_key("reply", root_id)))
		end)

		it("reply_to_comment removes the draft and re-renders after the reply is saved", function()
			local_sync.create_comment("f.lua", 1, 1, "root", nil, function() end)
			local root_id = config.state.comments[1].id
			local key = drafts.current_key("reply", root_id)
			drafts.set(key, "reply draft")
			local seen
			helpers.mock(ui, "open_reply_window", function(_, opts)
				seen = opts
			end)
			comments.reply_to_comment(root_id)

			-- Record whether the draft was gone when each refresh ran: the backend's
			-- own refresh runs before the removal and must not be the last one.
			local refreshed_without_draft = false
			helpers.mock(ui, "refresh_extmarks", function()
				if drafts.get(key) == nil then
					refreshed_without_draft = true
				end
			end)
			seen.on_submit("final reply")

			assert.is_nil(drafts.get(key))
			assert.is_true(helpers.wait_for(function()
				return refreshed_without_draft
			end))
		end)

		it("edit_comment offers the save-draft option", function()
			local_sync.create_comment("f.lua", 1, 1, "root", nil, function() end)
			local root_id = config.state.comments[1].id
			local seen
			helpers.mock(ui, "open_edit_window", function(_, _, opts)
				seen = opts
			end)
			comments.edit_comment(root_id)

			assert.is_true(seen.allow_draft)
		end)
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

	it("does not badge resolved state per comment (shown once on the thread head)", function()
		-- Resolved is thread-level and propagated to every comment, so it is
		-- indicated once via the inline border label / viewer title, not repeated
		-- as a per-comment header badge.
		assert.equals("", format.comment_badges({ is_resolved = true }))
		assert.equals("", format.comment_badges({ resolved = true }))
	end)

	it("keeps only the agent badge even when the thread is resolved", function()
		assert.equals(" [agent]", format.comment_badges({ author_type = "agent", is_resolved = true }))
	end)

	it("does not label human authors", function()
		assert.equals("", format.comment_badges({ author_type = "human" }))
	end)
end)
