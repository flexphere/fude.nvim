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

	it("excludes the plugin's own .fude/ store artifacts", function()
		local files = session.build_changed_files(
			"M\tlua/a.lua\nA\t.fude/reviews/s1.jsonl\n",
			nil,
			".fude/current.json\nuntracked.md\n"
		)
		local paths = {}
		for _, f in ipairs(files) do
			paths[f.path] = true
		end
		assert.is_true(paths["lua/a.lua"])
		assert.is_true(paths["untracked.md"])
		assert.is_nil(paths[".fude/reviews/s1.jsonl"])
		assert.is_nil(paths[".fude/current.json"])
	end)
end)

describe("session.is_store_path", function()
	it("matches .fude and its descendants", function()
		assert.is_true(session.is_store_path(".fude"))
		assert.is_true(session.is_store_path(".fude/current.json"))
		assert.is_true(session.is_store_path(".fude/reviews/s1.jsonl"))
	end)

	it("does not match unrelated paths", function()
		assert.is_false(session.is_store_path("lua/fude/init.lua"))
		assert.is_false(session.is_store_path(".fuderc"))
		assert.is_false(session.is_store_path("src/.fude_notes.md"))
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

	it("falls back to uncommitted scope when no base branch is found", function()
		mock_local_git({
			get_default_branch = function()
				return nil
			end,
		})
		session.start(nil)
		assert.is_true(config.state.active)
		assert.equals("uncommitted", config.state.local_session.scope)
		assert.equals("HEAD", config.state.local_session.base_sha)
		assert.is_nil(config.state.base_ref)
		assert.equals("Local: uncommitted", require("fude.scope").statusline())
	end)

	it("reviews a zero-commit repo against the empty tree", function()
		mock_local_git({
			get_default_branch = function()
				return nil
			end,
			get_head_sha = function()
				return nil
			end,
			get_empty_tree = function()
				return "emptytreehash"
			end,
			get_name_status = function(ref)
				-- git diff <empty-tree> shows staged files as added
				return (ref == "emptytreehash") and "A\tnew.py\n" or ""
			end,
			get_untracked = function()
				return "loose.txt\n"
			end,
		})
		session.start(nil)
		assert.is_true(config.state.active)
		assert.equals("uncommitted", config.state.local_session.scope)
		assert.equals("emptytreehash", config.state.local_session.base_sha)
		local paths = {}
		for _, f in ipairs(config.state.changed_files) do
			paths[f.path] = true
		end
		assert.is_true(paths["new.py"]) -- staged, via empty-tree diff
		assert.is_true(paths["loose.txt"]) -- untracked
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

	it("surfaces a warning and keeps going when the pointer write fails", function()
		mock_local_git()
		helpers.mock(store, "write_current", function()
			return false, "disk full"
		end)
		-- start must not crash on a failed pointer write; session still active.
		session.start(nil)
		assert.is_true(config.state.active)
		assert.is_false(session.persist_current(config.state.local_session))
	end)

	it("persists the scope across a resume", function()
		mock_local_git()
		session.start(nil)
		session.set_scope("uncommitted")

		-- current.json should carry the scope
		local current = store.read_current(tmp_repo)
		assert.equals("uncommitted", current.scope)

		-- Restart (pointer left in place) → resumes at the persisted scope
		config.state.active = false
		config.state.review_mode = nil
		session.start(nil)
		assert.equals("uncommitted", config.state.local_session.scope)
	end)

	it("resume with a different base arg keeps the existing session base", function()
		mock_local_git()
		session.start("main")
		local sid = config.state.local_session.id

		-- Restart with a different base arg; the resumed session wins.
		config.state.active = false
		config.state.review_mode = nil
		session.start("develop")
		assert.equals(sid, config.state.local_session.id)
		assert.equals("main", config.state.base_ref)
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

	it("starts in base scope with the branch base", function()
		mock_local_git()
		session.start(nil)
		assert.equals("base", config.state.local_session.scope)
		assert.equals("basesha", config.state.local_session.base_sha)
		assert.equals("main", config.state.local_session.content_ref)
	end)

	it("set_scope switches the diff base to HEAD for uncommitted", function()
		mock_local_git()
		local diff = require("fude.diff")
		local diffed_ref
		helpers.mock(diff, "get_name_status", function(ref)
			diffed_ref = ref
			return "M\tf.lua\n"
		end)
		session.start(nil)

		session.set_scope("uncommitted")
		assert.equals("uncommitted", config.state.local_session.scope)
		assert.equals("HEAD", config.state.local_session.base_sha)
		assert.equals("HEAD", config.state.local_session.content_ref)
		assert.equals("HEAD", diffed_ref)
		assert.equals("Local: uncommitted", require("fude.scope").statusline())
	end)

	it("set_scope back to base restores the merge-base", function()
		mock_local_git()
		session.start(nil)
		session.set_scope("uncommitted")
		session.set_scope("base")
		assert.equals("base", config.state.local_session.scope)
		assert.equals("basesha", config.state.local_session.base_sha)
		assert.equals("main", config.state.local_session.content_ref)
	end)

	it("set_scope rejects an unknown scope", function()
		mock_local_git()
		session.start(nil)
		session.set_scope("bogus")
		assert.equals("base", config.state.local_session.scope)
	end)

	it("set_scope preserves comments across a scope switch", function()
		mock_local_git()
		session.start(nil)
		store.append_event(
			config.state.local_session.file,
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 1, end_line = 1, body = "keep me" })
		)
		session.reload(true)
		assert.equals(1, #config.state.comments)

		session.set_scope("uncommitted")
		assert.equals(1, #config.state.comments)
		assert.equals("keep me", config.state.comments[1].body)
	end)
end)

describe("session.resolve_scope_base", function()
	after_each(function()
		helpers.cleanup()
	end)

	it("uncommitted resolves to literal HEAD when HEAD exists", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_head_sha", function()
			return "somesha"
		end)
		local diff_base, content_ref = session.resolve_scope_base("uncommitted", "main")
		assert.equals("HEAD", diff_base)
		assert.equals("HEAD", content_ref)
	end)

	it("uncommitted falls back to the empty tree when there is no HEAD", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_head_sha", function()
			return nil
		end)
		helpers.mock(diff, "get_empty_tree", function()
			return "emptyhash"
		end)
		local diff_base, content_ref = session.resolve_scope_base("uncommitted", "main")
		assert.equals("emptyhash", diff_base)
		assert.equals("emptyhash", content_ref)
	end)

	it("base resolves to the merge-base sha with the base branch as content ref", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_merge_base", function(ref)
			assert.equals("main", ref)
			return "mergesha"
		end)
		local diff_base, content_ref = session.resolve_scope_base("base", "main")
		assert.equals("mergesha", diff_base)
		assert.equals("main", content_ref)
	end)

	it("returns nil when the merge-base cannot be resolved", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_merge_base", function()
			return nil
		end)
		local diff_base = session.resolve_scope_base("base", "main")
		assert.is_nil(diff_base)
	end)
end)

describe("scope.format_local_scope_label", function()
	local scope = require("fude.scope")

	it("shows the base ref for base scope", function()
		assert.equals("Local: main", scope.format_local_scope_label("main", "base"))
		assert.equals("Local: main", scope.format_local_scope_label("main", nil))
	end)

	it("shows a neutral label for uncommitted scope", function()
		assert.equals("Local: uncommitted", scope.format_local_scope_label("main", "uncommitted"))
	end)
end)
