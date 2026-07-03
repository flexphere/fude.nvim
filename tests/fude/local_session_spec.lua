local session = require("fude.local.session")
local store = require("fude.local.store")
local config = require("fude.config")
local helpers = require("tests.helpers")

describe("session.status_word", function()
	it("maps git letters to GitHub-style words", function()
		assert.equals("added", session.status_word("A"))
		assert.equals("modified", session.status_word("M"))
		assert.equals("removed", session.status_word("D"))
		assert.equals("renamed", session.status_word("R100"))
		assert.equals("copied", session.status_word("C75"))
	end)

	it("falls back to modified for unknown letters", function()
		assert.equals("modified", session.status_word("T"))
	end)
end)

describe("session.resolve_rename_path", function()
	it("resolves brace rename expressions", function()
		assert.equals("lua/fude/new/mod.lua", session.resolve_rename_path("lua/fude/{old => new}/mod.lua"))
	end)

	it("resolves whole-path renames", function()
		assert.equals("b.lua", session.resolve_rename_path("a.lua => b.lua"))
	end)

	it("collapses doubled slashes from empty brace sides", function()
		assert.equals("lua/mod.lua", session.resolve_rename_path("lua/{sub => }/mod.lua"))
	end)

	it("returns plain paths unchanged", function()
		assert.equals("lua/fude/init.lua", session.resolve_rename_path("lua/fude/init.lua"))
	end)
end)

describe("session.parse_name_status", function()
	it("parses statuses and paths", function()
		local out = "M\tlua/a.lua\nA\tlua/b.lua\nD\tlua/c.lua\n"
		local entries = session.parse_name_status(out)
		assert.equals(3, #entries)
		assert.same({ path = "lua/a.lua", status = "modified" }, entries[1])
		assert.same({ path = "lua/b.lua", status = "added" }, entries[2])
		assert.same({ path = "lua/c.lua", status = "removed" }, entries[3])
	end)

	it("uses the new path for renames", function()
		local entries = session.parse_name_status("R100\told.lua\tnew.lua\n")
		assert.same({ path = "new.lua", status = "renamed" }, entries[1])
	end)

	it("returns empty for nil / empty output", function()
		assert.same({}, session.parse_name_status(nil))
		assert.same({}, session.parse_name_status(""))
	end)
end)

describe("session.parse_numstat", function()
	it("parses counts per path", function()
		local counts = session.parse_numstat("10\t2\tlua/a.lua\n0\t5\tlua/b.lua\n")
		assert.same({ additions = 10, deletions = 2 }, counts["lua/a.lua"])
		assert.same({ additions = 0, deletions = 5 }, counts["lua/b.lua"])
	end)

	it("treats binary markers as zero", function()
		local counts = session.parse_numstat("-\t-\timg.png\n")
		assert.same({ additions = 0, deletions = 0 }, counts["img.png"])
	end)

	it("resolves rename expressions to the new path", function()
		local counts = session.parse_numstat("3\t1\tlua/{old => new}/mod.lua\n")
		assert.same({ additions = 3, deletions = 1 }, counts["lua/new/mod.lua"])
	end)
end)

describe("session.build_changed_files", function()
	it("merges name-status, numstat, and untracked files", function()
		local files = session.build_changed_files("M\tlua/a.lua\n", "7\t3\tlua/a.lua\n", "notes.md\n")
		assert.equals(2, #files)
		assert.same({ path = "lua/a.lua", status = "modified", additions = 7, deletions = 3 }, files[1])
		assert.same({ path = "notes.md", status = "added", additions = 0, deletions = 0 }, files[2])
	end)

	it("does not duplicate files present in both diff and untracked output", function()
		local files = session.build_changed_files("A\tnew.lua\n", nil, "new.lua\n")
		assert.equals(1, #files)
	end)

	it("defaults counts to zero when numstat is missing", function()
		local files = session.build_changed_files("M\tlua/a.lua\n", nil, nil)
		assert.same({ path = "lua/a.lua", status = "modified", additions = 0, deletions = 0 }, files[1])
	end)
end)

describe("session lifecycle (start/reload/stop)", function()
	local tmp_store, tmp_repo

	local function mock_local_git(overrides)
		local diff = require("fude.diff")
		local defaults = {
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
		for name, fn in pairs(vim.tbl_extend("force", defaults, overrides or {})) do
			helpers.mock(diff, name, fn)
		end
	end

	before_each(function()
		tmp_store = vim.fn.tempname()
		tmp_repo = vim.fn.tempname()
		vim.fn.mkdir(tmp_store, "p")
		vim.fn.mkdir(tmp_repo, "p")
		vim.fn.writefile({ "line1", "line2", "line3" }, tmp_repo .. "/f.lua")
		store._dir = tmp_store
		config.setup({})
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

	it("start populates state and creates session files", function()
		mock_local_git()
		session.start(nil)

		local state = config.state
		assert.is_true(state.active)
		assert.equals("local", state.review_mode)
		assert.equals("main", state.base_ref)
		assert.equals("feat/x", state.head_ref)
		assert.equals("basesha", state.merge_base_sha)
		assert.equals("flexphere", state.github_user)
		assert.equals(1, #state.changed_files)
		assert.equals("f.lua", state.changed_files[1].path)

		local current = store.read_current(tmp_repo)
		assert.is_not_nil(current)
		assert.equals(state.local_session.id, current.id)

		local events = store.read_events(state.local_session.file)
		assert.equals(1, #events)
		assert.equals("session", events[1].event)
	end)

	it("start with an explicit base ref uses it", function()
		mock_local_git()
		session.start("develop")
		assert.equals("develop", config.state.base_ref)
	end)

	it("start warns when already active", function()
		mock_local_git()
		session.start(nil)
		local before = config.state.local_session.id
		session.start(nil)
		assert.equals(before, config.state.local_session.id)
	end)

	it("resumes the session recorded in current.json", function()
		mock_local_git()
		session.start(nil)
		local first_id = config.state.local_session.id
		session.stop()

		-- Simulate an unfinished session left behind
		mock_local_git()
		session.start(nil)
		local second_id = config.state.local_session.id
		assert.are_not.equal(first_id, second_id)

		-- Leave the pointer in place (no stop) and restart via a fresh state
		config.state.active = false
		config.state.review_mode = nil
		session.start(nil)
		assert.equals(second_id, config.state.local_session.id)
	end)

	it("starts fresh when the pointed session file was deleted", function()
		mock_local_git()
		session.start(nil)
		local first_id = config.state.local_session.id
		local first_file = config.state.local_session.file

		-- Simulate a stale pointer: file removed, current.json left behind
		config.state.active = false
		config.state.review_mode = nil
		vim.fn.delete(first_file)

		session.start(nil)
		assert.are_not.equal(first_id, config.state.local_session.id)
		local events = store.read_events(config.state.local_session.file)
		assert.equals("session", events[1].event)
	end)

	it("reload picks up externally appended events", function()
		mock_local_git()
		session.start(nil)
		local state = config.state

		store.append_event(
			state.local_session.file,
			store.build_comment_event({
				id = "c1",
				path = "f.lua",
				start_line = 2,
				end_line = 2,
				body = "agent says hi",
				author = "claude",
				author_type = "agent",
				created_at = "2026-07-04T00:00:00Z",
			})
		)

		session.reload(true)
		assert.equals(1, #state.comments)
		assert.equals("agent says hi", state.comments[1].body)
		assert.is_not_nil(state.comment_map["f.lua"])
		assert.is_not_nil(state.comment_map["f.lua"][2])
	end)

	it("reload marks comments beyond EOF as outdated", function()
		mock_local_git()
		session.start(nil)
		local state = config.state

		store.append_event(
			state.local_session.file,
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 99, end_line = 99, body = "stale" })
		)

		session.reload(true)
		assert.is_true(state.comments[1].is_outdated)
		assert.is_nil(state.comment_map["f.lua"])
	end)

	it("stop clears state and the current pointer but keeps the session file", function()
		mock_local_git()
		session.start(nil)
		local file = config.state.local_session.file

		session.stop()
		assert.is_false(config.state.active)
		assert.is_nil(config.state.review_mode)
		assert.is_nil(config.state.local_session)
		assert.is_nil(store.read_current(tmp_repo))
		assert.equals(1, vim.fn.filereadable(file))
	end)

	it("init.stop delegates to the local session teardown", function()
		mock_local_git()
		session.start(nil)
		require("fude").stop()
		assert.is_false(config.state.active)
		assert.is_nil(store.read_current(tmp_repo))
	end)

	it("statusline shows the local session label", function()
		mock_local_git()
		session.start(nil)
		assert.equals("Local: main", require("fude.scope").statusline())
	end)
end)
