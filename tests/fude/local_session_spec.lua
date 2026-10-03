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

		local current = store.read_current(tmp_repo, "feat/x")
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

	it("switching to base scope with no base ref stays put without crashing", function()
		mock_local_git({
			get_default_branch = function()
				return nil
			end,
		})
		session.start(nil)
		assert.equals("uncommitted", config.state.local_session.scope)

		-- Selecting the "Base branch" scope row (e.g. from the side panel) must
		-- not crash when the session never had a base branch.
		session.set_scope("base")
		assert.equals("uncommitted", config.state.local_session.scope)
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
		local current = store.read_current(tmp_repo, "feat/x")
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

	it("keeps separate sessions per branch in one worktree", function()
		mock_local_git() -- branch feat/x
		session.start(nil)
		local id_x = config.state.local_session.id

		-- Switch branch without stopping, then start again → a fresh session.
		config.state.active = false
		config.state.review_mode = nil
		helpers.mock(require("fude.diff"), "get_current_branch", function()
			return "feat/y"
		end)
		session.start(nil)
		local id_y = config.state.local_session.id

		assert.are_not.equal(id_x, id_y)
		-- Both branches' pointers coexist in current.json (no collision).
		assert.equals(id_x, store.read_current(tmp_repo, "feat/x").id)
		assert.equals(id_y, store.read_current(tmp_repo, "feat/y").id)
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
		assert.is_nil(store.read_current(tmp_repo, "feat/x"))
		assert.equals(1, vim.fn.filereadable(file))
	end)

	it("init.stop delegates to the local session teardown", function()
		mock_local_git()
		session.start(nil)
		require("fude").stop()
		assert.is_false(config.state.active)
		assert.is_nil(store.read_current(tmp_repo, "feat/x"))
	end)

	it("toggle starts when inactive and stops when a local session is active", function()
		mock_local_git()
		session.toggle(nil)
		assert.is_true(config.state.active)
		assert.equals("local", config.state.review_mode)

		session.toggle(nil)
		assert.is_false(config.state.active)
	end)

	it("toggle passes the base arg through to start", function()
		mock_local_git()
		session.toggle("develop")
		assert.equals("develop", config.state.base_ref)
	end)

	it("toggle refuses to start while a GitHub review is active", function()
		config.state.active = true
		config.state.review_mode = "github"
		session.toggle(nil)
		-- unchanged: still the GitHub session, no local session created
		assert.equals("github", config.state.review_mode)
		assert.is_nil(config.state.local_session)
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
		-- The preview pane reads content_ref. It has to be the merge-base as well,
		-- not the base branch tip ("main"), or the preview drifts away from the
		-- changed-files list as soon as the base branch moves on.
		assert.equals("basesha", config.state.local_session.content_ref)
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

	it("set_scope clears a pending gitsigns reset before restoring the base", function()
		mock_local_git()
		session.start(nil)
		-- :FudeReviewToggleGitsigns left gitsigns on HEAD
		config.state.gitsigns_reset = true
		local reset_flag_at_restore
		helpers.mock(require("fude"), "restore_gitsigns_base", function()
			reset_flag_at_restore = config.state.gitsigns_reset
		end)

		session.set_scope("uncommitted")
		-- the flag must be cleared before the restore, otherwise
		-- apply_gitsigns_base_for_buffer skips every buffer and the new
		-- scope's base is never applied
		assert.is_false(reset_flag_at_restore)
		assert.is_false(config.state.gitsigns_reset)
	end)

	it("set_scope back to base restores the merge-base", function()
		mock_local_git()
		session.start(nil)
		session.set_scope("uncommitted")
		session.set_scope("base")
		assert.equals("base", config.state.local_session.scope)
		assert.equals("basesha", config.state.local_session.base_sha)
		assert.equals("basesha", config.state.local_session.content_ref)
	end)

	it("set_scope rejects an unknown scope", function()
		mock_local_git()
		session.start(nil)
		session.set_scope("bogus")
		assert.equals("base", config.state.local_session.scope)
	end)

	it("set_scope returns true only when the scope actually changed", function()
		mock_local_git()
		session.start(nil)

		assert.is_true(session.set_scope("uncommitted"))
		-- Same scope again → no-op
		assert.is_false(session.set_scope("uncommitted"))
		-- Unknown scope → rejected
		assert.is_false(session.set_scope("bogus"))
	end)

	it("set_scope returns false when the scope base cannot be resolved", function()
		mock_local_git({
			get_default_branch = function()
				return nil
			end,
		})
		session.start(nil)
		assert.equals("uncommitted", config.state.local_session.scope)

		assert.is_false(session.set_scope("base"))
	end)

	it("set_scope returns false when no local session is active", function()
		mock_local_git()
		helpers.mock(vim, "notify", function() end)
		assert.is_false(session.set_scope("uncommitted"))
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

	-- === commit scope: HEAD moves ===

	local COMMITS = {
		{ sha = "c1sha", short_sha = "c1", subject = "first" },
		{ sha = "c2sha", short_sha = "c2", subject = "second" },
	}

	--- Mock the git helpers the commit scope drives, recording every checkout.
	--- @return table calls { checkout = string[] }
	local function mock_commit_git(overrides)
		local calls = { checkout = {} }
		mock_local_git(vim.tbl_extend("force", {
			get_commit_log = function()
				return vim.deepcopy(COMMITS)
			end,
			is_worktree_dirty = function()
				return false
			end,
			get_parent = function(sha)
				return sha .. "^", "parent"
			end,
			-- HEAD sits on whatever commit the scope checked out (the restore
			-- and commit-to-commit switches verify this), else on the branch tip
			get_head_sha = function()
				local s = config.state.local_session
				return (s and s.scope_commit_sha) or "headsha"
			end,
			checkout = function(ref)
				table.insert(calls.checkout, ref)
				return true
			end,
		}, overrides or {}))
		return calls
	end

	it("set_scope commit checks the commit out and diffs it against its parent", function()
		local calls = mock_commit_git()
		session.start(nil)

		assert.is_true(session.set_scope("commit", { commit_sha = "c2sha" }))
		local s = config.state.local_session
		assert.same({ "c2sha" }, calls.checkout)
		assert.equals("commit", s.scope)
		assert.equals("c2sha", s.scope_commit_sha)
		assert.equals(2, s.scope_commit_index)
		assert.equals("c2sha^", s.base_sha)
		assert.equals("c2sha^", config.state.merge_base_sha)
		assert.equals("feat/x", s.original_branch)
		assert.is_true(session.in_commit_scope())
		assert.equals("Local: 2/2", require("fude.scope").statusline())

		-- The picker flags the checked-out commit, not its sibling
		local current = vim.tbl_filter(function(spec)
			return spec.is_current
		end, session.scope_specs(s))
		assert.equals(1, #current)
		assert.equals("c2sha", current[1].commit_sha)
	end)

	it("set_scope commit without a sha is refused", function()
		local calls = mock_commit_git()
		session.start(nil)
		assert.is_false(session.set_scope("commit"))
		assert.same({}, calls.checkout)
		assert.equals("base", config.state.local_session.scope)
	end)

	it("re-selecting the checked-out commit is a no-op", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({ "c1sha" }, calls.checkout)
	end)

	it("switching between commits checks the tree again and refuses a dirty one", function()
		local dirty = false
		local calls = mock_commit_git({
			is_worktree_dirty = function()
				return dirty
			end,
		})
		session.start(nil)
		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))

		-- A file saved while the commit was checked out must not be carried
		-- onto the next commit by the second checkout.
		dirty = true
		assert.is_false(session.set_scope("commit", { commit_sha = "c2sha" }))
		assert.same({ "c1sha" }, calls.checkout)
		assert.equals("c1sha", config.state.local_session.scope_commit_sha)

		dirty = false
		assert.is_true(session.set_scope("commit", { commit_sha = "c2sha" }))
		assert.same({ "c1sha", "c2sha" }, calls.checkout)
		assert.equals("c2sha", config.state.local_session.scope_commit_sha)
	end)

	it("refuses the commit scope while a buffer under the worktree is unsaved", function()
		local calls = mock_commit_git()
		session.start(nil)

		-- git status cannot see this edit; the checkout would leave the buffer
		-- showing neither commit and write it onto whatever is checked out.
		local buf = vim.fn.bufadd(tmp_repo .. "/f.lua")
		vim.fn.bufload(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
		assert.is_true(vim.bo[buf].modified)

		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({}, calls.checkout)
		assert.equals("base", config.state.local_session.scope)

		vim.api.nvim_buf_delete(buf, { force = true })
		-- A modified buffer elsewhere does not block
		local other = vim.fn.bufadd(vim.fn.tempname() .. "/elsewhere.lua")
		vim.fn.bufload(other)
		vim.api.nvim_buf_set_lines(other, 0, -1, false, { "edited" })
		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		vim.api.nvim_buf_delete(other, { force = true })
	end)

	it("refuses to leave the commit scope while a buffer under the worktree is unsaved", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- Edited after the checkout: git cannot carry it back and the reload
		-- would skip it, so it would overwrite the branch on the next save.
		local buf = vim.fn.bufadd(tmp_repo .. "/f.lua")
		vim.fn.bufload(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited on the commit" })

		assert.is_false(session.set_scope("uncommitted"))
		assert.same({ "c1sha" }, calls.checkout)
		assert.equals("commit", config.state.local_session.scope)
		assert.equals("c1sha", config.state.local_session.scope_commit_sha)

		-- stop() is refused the same way and keeps the session
		session.stop()
		assert.is_true(config.state.active)
		assert.same({ "c1sha" }, calls.checkout)

		-- VimLeavePre forces the restore anyway and leaves a non-commit pointer
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		assert.same({ "c1sha", "feat/x" }, calls.checkout)
		local pointer = store.read_current(tmp_repo, "feat/x")
		assert.equals("base", pointer.scope)
		assert.is_nil(pointer.scope_commit_sha)
		assert.is_nil(pointer.original_branch)

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("removes the pointer when the non-commit rewrite after a restore fails", function()
		mock_commit_git()
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.equals("commit", store.read_current(tmp_repo, "feat/x").scope)

		-- The disk turns read-only for JSON writes; the stale commit entry must
		-- not outlive the restore (a later deliberate detach would match it).
		helpers.mock(store, "write_current", function()
			return false, "read-only"
		end)
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		assert.is_nil(store.read_current(tmp_repo, "feat/x"))
		assert.is_nil(store.read_stranded_commit_session(tmp_repo, "c1sha"))
	end)

	it("removes the pointer when the rollback after a failed checkout cannot be written", function()
		local writes = 0
		mock_commit_git({
			checkout = function()
				return false, "conflict"
			end,
		})
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		local real_write = store.write_current
		helpers.mock(store, "write_current", function(...)
			writes = writes + 1
			if writes == 1 then
				return real_write(...) -- the pending pointer goes through
			end
			return false, "read-only" -- the rollback does not
		end)

		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		-- HEAD never moved, so no pointer naming the commit may remain
		assert.is_nil(store.read_current(tmp_repo, "feat/x"))
		assert.equals("base", config.state.local_session.scope)
	end)

	it("a forced restore leaves no pointer a deliberate detach could be mistaken for", function()
		mock_commit_git()
		session.start(nil)
		session.set_scope("uncommitted")
		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.equals("commit", store.read_current(tmp_repo, "feat/x").scope)

		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		-- The scope the user had before entering the commit is written back
		assert.equals("uncommitted", store.read_current(tmp_repo, "feat/x").scope)
		assert.is_nil(store.read_stranded_commit_session(tmp_repo, "c1sha"))
	end)

	it("ignores buffers of a worktree nested inside this one", function()
		local calls = mock_commit_git()
		local diff = require("fude.diff")
		local nested = tmp_repo .. "/.claude/worktrees/x"
		vim.fn.mkdir(nested, "p")
		helpers.mock(diff, "get_worktree_roots", function()
			return { tmp_repo, nested }
		end)
		session.start(nil)

		-- Lives under tmp_repo by prefix, but belongs to the nested worktree
		local buf = vim.fn.bufadd(nested .. "/g.lua")
		vim.fn.bufload(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited elsewhere" })
		assert.is_true(vim.bo[buf].modified)

		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({ "c1sha" }, calls.checkout)
		-- and it was not reloaded under the parent's checkout
		assert.is_true(vim.bo[buf].modified)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("keeps the scope to return to across a failed switch that re-enters the commit", function()
		mock_commit_git()
		session.start(nil)
		session.set_scope("uncommitted")
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- unpushed is unavailable → back to the commit; the pointer must still
		-- know the user came from uncommitted, not from "commit".
		assert.is_false(session.set_scope("unpushed"))
		assert.equals("commit", config.state.local_session.scope)
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		assert.equals("uncommitted", store.read_current(tmp_repo, "feat/x").scope)
	end)

	it("sees a comment input in another tab and closes empty ones everywhere", function()
		local calls = mock_commit_git()
		session.start(nil)

		local origin_tab = vim.api.nvim_get_current_tabpage()
		vim.cmd("tabnew")
		local buf = vim.api.nvim_create_buf(false, true)
		vim.b[buf].fude_comment = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "typed in another tab" })
		local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })
		vim.api.nvim_set_current_tabpage(origin_tab)

		-- bufwinid() would not find it from here; win_findbuf() does
		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({}, calls.checkout)

		-- Emptied, it no longer blocks, and entering closes it so a later
		-- submit cannot be refused after the float is gone
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.is_false(vim.api.nvim_win_is_valid(win))

		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= origin_tab then
				pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
			end
		end
	end)

	it("refuses every restore once HEAD moved off the reviewed commit, even on quit", function()
		local calls = mock_commit_git()
		local diff = require("fude.diff")
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- The user committed on the detached HEAD: a checkout away from it
		-- would leave that commit reachable only through the reflog.
		helpers.mock(diff, "get_head_sha", function()
			return "newcommit"
		end)
		local warned = {}
		helpers.mock(vim, "notify", function(msg)
			table.insert(warned, msg)
		end)

		assert.is_false(session.set_scope("uncommitted"))
		assert.is_false(session.set_scope("commit", { commit_sha = "c2sha" }))
		session.stop()
		assert.is_true(config.state.active)
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		assert.same({ "c1sha" }, calls.checkout)
		assert.truthy(table.concat(warned, "\n"):find("HEAD moved off the reviewed commit to newcomm", 1, true))
		assert.truthy(table.concat(warned, "\n"):find("git branch <name>", 1, true))

		-- Back on the reviewed commit (the user moved theirs to a branch) → fine
		helpers.mock(diff, "get_head_sha", function()
			return "c1sha"
		end)
		assert.is_true(session.set_scope("uncommitted"))
		assert.same({ "c1sha", "feat/x" }, calls.checkout)
	end)

	it("entering the commit scope closes open comment viewer floats in any tab", function()
		mock_commit_git()
		session.start(nil)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.b[buf].fude_comment_view = true
		local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })

		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.is_false(vim.api.nvim_win_is_valid(win))
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end)

	it("computes the empty tree inside the reviewed worktree", function()
		local asked = {}
		mock_commit_git({
			get_parent = function()
				return nil, "root"
			end,
			get_empty_tree = function(cwd)
				table.insert(asked, cwd)
				return "emptyhash"
			end,
		})
		session.start(nil)
		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({ tmp_repo }, asked)
		assert.equals("emptyhash", config.state.local_session.base_sha)
	end)

	it("lists worktrees from the session root, detached ones included", function()
		local calls = mock_commit_git()
		local diff = require("fude.diff")
		local nested = tmp_repo .. "/.claude/worktrees/detached"
		vim.fn.mkdir(nested, "p")
		local asked = {}
		helpers.mock(diff, "get_worktree_roots", function(cwd)
			table.insert(asked, cwd)
			return { tmp_repo, nested }
		end)
		session.start(nil)

		local buf = vim.fn.bufadd(nested .. "/h.lua")
		vim.fn.bufload(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited in a detached worktree" })

		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({ "c1sha" }, calls.checkout)
		assert.equals(tmp_repo, asked[1])
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("reports a stale pointer it could neither rewrite nor remove", function()
		mock_commit_git()
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		helpers.mock(store, "write_current", function()
			return false, "read-only"
		end)
		helpers.mock(store, "clear_current", function()
			return false, "read-only"
		end)
		local errors = {}
		helpers.mock(vim, "notify", function(msg, level)
			if level == vim.log.levels.ERROR then
				table.insert(errors, msg)
			end
		end)
		vim.api.nvim_exec_autocmds("VimLeavePre", { group = config.state.augroup })
		assert.equals(1, #errors)
		assert.truthy(errors[1]:find("stale commit-scope entry remains", 1, true))
		assert.truthy(errors[1]:find("feat/x", 1, true))
	end)

	it("relative_path resolves against the session root even after :cd elsewhere", function()
		mock_commit_git()
		session.start(nil)
		local elsewhere = vim.fn.tempname()
		vim.fn.mkdir(elsewhere, "p")
		local original_cwd = vim.fn.getcwd()
		vim.cmd.cd(elsewhere)

		assert.equals("f.lua", session.relative_path(tmp_repo .. "/f.lua"))
		assert.equals("sub/dir/g.lua", session.relative_path(tmp_repo .. "/sub/dir/g.lua"))
		assert.is_nil(session.relative_path(elsewhere .. "/x.lua"))
		assert.is_nil(session.relative_path(""))
		assert.is_nil(session.relative_path(nil))

		vim.cmd.cd(original_cwd)
		vim.fn.delete(elsewhere, "rf")
	end)

	it("ignores a scope picked from a picker built for an earlier session", function()
		local calls = mock_commit_git()
		local captured
		helpers.mock(vim.ui, "select", function(_, _, on_choice)
			captured = on_choice
		end)
		session.start(nil)
		session.select_scope()
		assert.is_function(captured)

		-- stop → start while the picker is still open
		session.stop()
		session.start(nil)
		helpers.mock(vim, "notify", function() end)
		captured({ scope = "commit", commit_sha = "c1sha" })
		assert.same({}, calls.checkout)
		assert.equals("base", config.state.local_session.scope)
	end)

	it("rewrites the stranded pointer right after returning to the branch", function()
		mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		config.state.active = false
		config.state.review_mode = nil
		local diff = require("fude.diff")
		local on_branch = false
		helpers.mock(diff, "get_current_branch", function()
			return on_branch and "feat/x" or nil
		end)
		helpers.mock(diff, "get_head_sha", function()
			return on_branch and "headsha" or "c1sha"
		end)
		local pointer_after_checkout
		helpers.mock(diff, "checkout", function(ref)
			on_branch = (ref == "feat/x")
			return true
		end)
		-- The first write after the checkout must already be non-commit: fail
		-- everything after it so nothing later could paper over the window.
		local real_write = store.write_current
		local writes = 0
		helpers.mock(store, "write_current", function(root, branch, data)
			writes = writes + 1
			if writes == 1 then
				pointer_after_checkout = vim.deepcopy(data)
				return real_write(root, branch, data)
			end
			return false, "later writes fail"
		end)
		helpers.mock(vim, "notify", function() end)

		session.start(nil)
		assert.is_not_nil(pointer_after_checkout)
		assert.is_nil(pointer_after_checkout.scope_commit_sha)
		assert.is_nil(pointer_after_checkout.original_branch)
		assert.not_equals("commit", pointer_after_checkout.scope)
	end)

	it("leaving the commit scope restores the branch first", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		assert.is_true(session.set_scope("uncommitted"))
		local s = config.state.local_session
		assert.same({ "c1sha", "feat/x" }, calls.checkout)
		assert.equals("uncommitted", s.scope)
		assert.is_nil(s.scope_commit_sha)
		assert.is_nil(s.scope_commit_index)
		assert.is_nil(s.original_branch)
		assert.is_false(session.in_commit_scope())
	end)

	it("stop restores the branch left by the commit scope", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		session.stop()
		assert.same({ "c1sha", "feat/x" }, calls.checkout)
		assert.is_false(config.state.active)
	end)

	it("stop keeps the session when the branch cannot be restored", function()
		local fail_restore = false
		mock_commit_git({
			checkout = function()
				if fail_restore then
					return false, "conflict"
				end
				return true
			end,
		})
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- Tearing down anyway would strand the user on the detached HEAD with
		-- no pointer and no original_branch left to retry from.
		fail_restore = true
		session.stop()
		assert.is_true(config.state.active)
		assert.equals("feat/x", config.state.local_session.original_branch)
		assert.is_not_nil(store.read_current(tmp_repo, "feat/x"))

		fail_restore = false
		session.stop()
		assert.is_false(config.state.active)
		assert.is_nil(store.read_current(tmp_repo, "feat/x"))
	end)

	it("offers the unpushed scope from a detached commit by asking for the branch's upstream", function()
		local asked = {}
		mock_commit_git({
			get_upstream_ref = function(_, branch)
				table.insert(asked, branch)
				return "origin/feat/x"
			end,
		})
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		asked = {}
		local specs = session.scope_specs(config.state.local_session)
		local has_unpushed = vim.tbl_contains(
			vim.tbl_map(function(s)
				return s.scope
			end, specs),
			"unpushed"
		)
		assert.is_true(has_unpushed)
		-- A bare @{upstream} would not resolve on the detached HEAD
		assert.same({ "feat/x" }, asked)
	end)

	it("caps the unbounded commit list at the newest COMMIT_LIST_LIMIT", function()
		local limits = {}
		mock_commit_git({
			get_default_branch = function()
				return nil
			end,
			get_upstream_ref = function()
				return nil
			end,
			get_commit_log = function(_, _, _, limit)
				table.insert(limits, limit)
				return vim.deepcopy(COMMITS)
			end,
		})
		session.start(nil)
		assert.same({ session.COMMIT_LIST_LIMIT }, limits)
		assert.equals(100, session.COMMIT_LIST_LIMIT)
	end)

	it("does not cap a commit list that has a range", function()
		local limits = {}
		mock_commit_git({
			get_commit_log = function(_, _, _, limit)
				table.insert(limits, limit == nil and "none" or limit)
				return vim.deepcopy(COMMITS)
			end,
		})
		session.start(nil)
		assert.same({ "none" }, limits)
	end)

	it("re-enters the commit when the target scope cannot be resolved", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- No upstream in the temp repo → unpushed is unavailable. HEAD was
		-- already moved back to the branch, so it has to move again.
		assert.is_false(session.set_scope("unpushed"))
		local s = config.state.local_session
		assert.same({ "c1sha", "feat/x", "c1sha" }, calls.checkout)
		assert.equals("commit", s.scope)
		assert.equals("c1sha", s.scope_commit_sha)
		assert.equals(1, s.scope_commit_index)
		assert.equals("feat/x", s.original_branch)
	end)

	it("lands on uncommitted when the commit cannot be re-entered after a failed switch", function()
		local calls = { checkout = {} }
		mock_commit_git({
			checkout = function(ref)
				table.insert(calls.checkout, ref)
				-- The branch comes back fine; checking the commit out again fails
				if #calls.checkout == 3 then
					return false, "object store hiccup"
				end
				return true
			end,
		})
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- HEAD is back on the branch, the target scope is unavailable and the
		-- commit cannot be re-entered: the session must not keep claiming a
		-- scope it no longer shows.
		assert.is_false(session.set_scope("unpushed"))
		local s = config.state.local_session
		assert.same({ "c1sha", "feat/x", "c1sha" }, calls.checkout)
		assert.equals("uncommitted", s.scope)
		assert.equals("HEAD", s.base_sha)
		assert.is_nil(s.scope_commit_sha)
		assert.is_false(session.in_commit_scope())
	end)

	it("a failed checkout leaves the scope, the return branch and the pointer untouched", function()
		local checkouts = 0
		mock_commit_git({
			checkout = function()
				checkouts = checkouts + 1
				return false, "conflict"
			end,
		})
		helpers.mock(vim, "notify", function() end)
		session.start(nil)

		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		local s = config.state.local_session
		assert.equals("base", s.scope)
		assert.is_nil(s.scope_commit_sha)
		assert.equals("basesha", s.base_sha)
		-- No return branch is left behind, so later restores run no checkout
		-- (one that could fail and then block stop()).
		assert.is_nil(s.original_branch)
		-- The pending pointer written before the checkout is rolled back
		local pointer = store.read_current(tmp_repo, "feat/x")
		assert.equals("base", pointer.scope)
		assert.is_nil(pointer.scope_commit_sha)
		assert.is_nil(pointer.original_branch)

		assert.equals(1, checkouts)
		session.stop()
		assert.is_false(config.state.active)
		assert.equals(1, checkouts) -- stop did not try a restore
	end)

	it("does not move HEAD when the pending pointer cannot be written", function()
		local calls = mock_commit_git()
		helpers.mock(vim, "notify", function() end)
		session.start(nil)
		helpers.mock(store, "write_current", function()
			return false, "read-only"
		end)

		-- Without the pointer a crash could never find the way back, so the
		-- checkout must not happen at all.
		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({}, calls.checkout)
		assert.equals("base", config.state.local_session.scope)
		assert.is_nil(config.state.local_session.original_branch)
	end)

	it("refuses the commit scope while a comment input holds unsent text", function()
		local calls = mock_commit_git()
		session.start(nil)

		-- A single-pane comment input float with text typed into it
		local buf = vim.api.nvim_create_buf(false, true)
		vim.b[buf].fude_comment = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "half-written thought" })
		local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })

		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({}, calls.checkout)

		-- An empty input does not block; the teardown just closes it
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		assert.is_true(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({ "c1sha" }, calls.checkout)

		pcall(vim.api.nvim_win_close, win, true)
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end)

	it("refuses the commit scope while the reply window holds unsent text", function()
		local calls = mock_commit_git()
		session.start(nil)
		local lower = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(lower, 0, -1, false, { "reply in progress" })
		config.state.reply_window = { upper_win = 1, lower_buf = lower }

		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		assert.same({}, calls.checkout)

		config.state.reply_window = nil
		pcall(vim.api.nvim_buf_delete, lower, { force = true })
	end)

	it("a pending commit-to-commit switch records the commit HEAD is still on", function()
		local during = {}
		mock_commit_git({
			checkout = function()
				table.insert(during, store.read_current(tmp_repo, "feat/x"))
				return true
			end,
		})
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		session.set_scope("commit", { commit_sha = "c2sha" })

		-- First entry: nothing to come from. Second: HEAD is on c1sha until
		-- the checkout lands, so a crash there must still be recognised.
		assert.is_nil(during[1].pending_from_sha)
		assert.equals("c2sha", during[2].scope_commit_sha)
		assert.equals("c1sha", during[2].pending_from_sha)
		assert.equals(
			"sb",
			(store.find_stranded_commit_session(
				{ ["feat/x"] = vim.tbl_extend("force", during[2], { id = "sb" }) },
				tmp_repo,
				"c1sha"
			) or {}).id
		)
		-- Once the switch completed the pending marker is gone
		assert.is_nil(store.read_current(tmp_repo, "feat/x").pending_from_sha)
	end)

	it("persists the pending commit before HEAD moves", function()
		local during = nil
		mock_commit_git({
			checkout = function()
				-- What a crash right here would leave on disk
				during = store.read_current(tmp_repo, "feat/x")
				return true
			end,
		})
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		assert.is_not_nil(during)
		assert.equals("commit", during.scope)
		assert.equals("c1sha", during.scope_commit_sha)
		assert.equals("feat/x", during.original_branch)
		-- The resume path would find it by HEAD
		assert.equals(during.id, store.find_stranded_commit_session({ ["feat/x"] = during }, tmp_repo, "c1sha").id)
	end)

	it("entering the commit scope clears every buffer's comment marks and closes comment UIs", function()
		mock_commit_git()
		session.start(nil)
		local ui = require("fude.ui")
		local cleared, closed, refreshed = 0, 0, 0
		helpers.mock(ui, "clear_all_extmarks", function()
			cleared = cleared + 1
		end)
		helpers.mock(ui, "close_comment_ui", function()
			closed = closed + 1
		end)
		helpers.mock(ui, "refresh_visible_extmarks", function()
			refreshed = refreshed + 1
		end)

		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.equals(1, cleared)
		assert.equals(1, closed)
		assert.equals(1, refreshed)

		-- Leaving re-renders every visible window, without another teardown
		session.set_scope("uncommitted")
		assert.equals(1, cleared)
		assert.equals(1, closed)
		assert.equals(2, refreshed)
	end)

	it("does not move HEAD when the commit's base cannot be resolved", function()
		local calls = mock_commit_git({
			-- Shallow clone boundary: the parent is recorded but not in the clone
			get_parent = function()
				return nil, "missing"
			end,
		})
		helpers.mock(vim, "notify", function() end)
		session.start(nil)

		-- Resolving `<sha>^` / the empty tree needs no checkout, so a failure
		-- must leave HEAD on the branch and the session on its previous scope.
		assert.is_false(session.set_scope("commit", { commit_sha = "c1sha" }))
		local s = config.state.local_session
		assert.same({}, calls.checkout)
		assert.equals("base", s.scope)
		assert.is_nil(s.original_branch)
		assert.is_false(session.in_commit_scope())
	end)

	it("exposes no comments while a commit is checked out and brings them back after", function()
		mock_commit_git()
		session.start(nil)
		store.append_event(
			config.state.local_session.file,
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 1, end_line = 1, body = "root" })
		)
		session.reload(true)
		assert.equals(1, #config.state.comments)

		-- Side panel and picker counts read state.comments, so it must be empty,
		-- not merely un-rendered.
		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.same({}, config.state.comments)
		assert.same({}, config.state.comment_map)

		session.set_scope("uncommitted")
		assert.equals(1, #config.state.comments)
		assert.equals("root", config.state.comments[1].body)
	end)

	it("returns to the branch a crashed commit-scope session left detached, then resumes it", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		local pointer = store.read_current(tmp_repo, "feat/x")
		assert.equals("c1sha", pointer.scope_commit_sha)
		assert.equals("feat/x", pointer.original_branch)
		local session_id = config.state.local_session.id

		-- Crash: the pointer survives, HEAD stays on c1sha, git reports no branch.
		config.state.active = false
		config.state.review_mode = nil
		local on_branch = false
		local diff = require("fude.diff")
		helpers.mock(diff, "get_current_branch", function()
			return on_branch and "feat/x" or nil
		end)
		helpers.mock(diff, "get_head_sha", function()
			return on_branch and "headsha" or "c1sha"
		end)
		helpers.mock(diff, "checkout", function(ref)
			table.insert(calls.checkout, ref)
			on_branch = (ref == "feat/x")
			return true
		end)

		session.start(nil)
		assert.same({ "c1sha", "feat/x" }, calls.checkout)
		local s = config.state.local_session
		assert.is_true(config.state.active)
		assert.equals(session_id, s.id) -- the branch session, not a new detached one
		assert.equals("feat/x", s.branch)
		assert.equals("base", s.scope)
		assert.is_nil(s.original_branch)
	end)

	it("refuses to start on a stranded detached HEAD when the tree is not clean", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		config.state.active = false
		config.state.review_mode = nil
		local diff = require("fude.diff")
		helpers.mock(diff, "get_current_branch", function()
			return nil
		end)
		helpers.mock(diff, "get_head_sha", function()
			return "c1sha"
		end)
		helpers.mock(diff, "is_worktree_dirty", function()
			return true
		end)
		local errors = {}
		helpers.mock(vim, "notify", function(msg, level)
			if level == vim.log.levels.ERROR then
				table.insert(errors, msg)
			end
		end)

		session.start(nil)
		assert.is_false(config.state.active)
		assert.same({ "c1sha" }, calls.checkout) -- no second checkout
		assert.equals(1, #errors)
		assert.truthy(errors[1]:find("git checkout feat/x", 1, true))
	end)

	it("leaves a detached HEAD alone when it is not the stranded commit", function()
		local calls = mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		config.state.active = false
		config.state.review_mode = nil
		local diff = require("fude.diff")
		helpers.mock(diff, "get_current_branch", function()
			return nil
		end)
		helpers.mock(diff, "get_head_sha", function()
			return "somewhere-else"
		end)

		session.start(nil)
		assert.is_true(config.state.active)
		assert.same({ "c1sha" }, calls.checkout)
		assert.is_nil(config.state.local_session.branch)
	end)

	it("does not resume into a persisted commit scope", function()
		mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })
		assert.equals("commit", store.read_current(tmp_repo, "feat/x").scope)

		-- Simulate a crash: the pointer outlives the checkout and stop() never
		-- ran. Resuming must land on a branch scope, never a detached commit.
		config.state.active = false
		config.state.review_mode = nil
		session.start(nil)
		assert.equals("base", config.state.local_session.scope)
		assert.is_nil(config.state.local_session.scope_commit_sha)
	end)

	-- === commit scope: comment layer is read-only ===

	it("the local backend refuses mutations in the commit scope", function()
		mock_commit_git()
		session.start(nil)
		store.append_event(
			config.state.local_session.file,
			store.build_comment_event({ id = "c1", path = "f.lua", start_line = 1, end_line = 1, body = "root" })
		)
		session.set_scope("commit", { commit_sha = "c1sha" })

		local local_sync = require("fude.comments.local_sync")
		local errs = {}
		local function collect(err)
			table.insert(errs, err)
		end
		-- The comment browser calls these directly, so the facade guard alone
		-- would not stop them.
		local_sync.create_comment("f.lua", 1, 1, "new", nil, collect)
		local_sync.reply_to_comment("c1", "reply", collect)
		local_sync.edit_comment("c1", "edited", collect)
		local_sync.delete_comment("c1", collect)
		local_sync.move_comments({ { id = "c1", path = "f.lua", start_line = 2, end_line = 2 } }, collect)
		local_sync.toggle_resolved("c1", false, collect)
		assert.equals(6, #errs)
		for _, err in ipairs(errs) do
			assert.equals(local_sync.COMMIT_SCOPE_ERROR, err)
		end

		-- Nothing reached the JSONL
		local events = store.read_events(config.state.local_session.file)
		assert.equals(2, #events) -- session header + the seeded comment

		-- Mutations work again once the branch is back
		session.set_scope("uncommitted")
		local reply_err = "unset"
		local_sync.reply_to_comment("c1", "reply", function(err)
			reply_err = err
		end)
		assert.is_nil(reply_err)
	end)

	it("the comment facade refuses the browser and navigation in the commit scope", function()
		mock_commit_git()
		session.start(nil)
		session.set_scope("commit", { commit_sha = "c1sha" })

		local opened = false
		helpers.mock(require("fude.ui.comment_browser"), "open", function()
			opened = true
		end)
		local warned = {}
		helpers.mock(vim, "notify", function(msg)
			table.insert(warned, msg)
		end)
		local comments = require("fude.comments")
		comments.list_comments()
		comments.view_comments()
		comments.next_comment()
		comments.prev_comment()
		assert.is_false(opened)
		assert.equals(4, #warned)
		for _, msg in ipairs(warned) do
			assert.truthy(msg:find("read-only in the commit scope", 1, true))
		end
	end)

	-- === commit list ===

	it("lists the unpushed commits when reviewing the base branch itself", function()
		local ranges = {}
		mock_commit_git({
			get_current_branch = function()
				return "main"
			end,
			get_upstream_ref = function()
				return "origin/main"
			end,
			get_commit_log = function(base, tip)
				table.insert(ranges, { base = base, tip = tip })
				return vim.deepcopy(COMMITS)
			end,
		})
		session.start(nil)
		assert.same({ { base = "origin/main", tip = "main" } }, ranges)
		assert.equals(2, #config.state.local_session.commits)
	end)

	it("lists every commit when there is neither a base nor an upstream", function()
		local ranges = {}
		mock_commit_git({
			get_default_branch = function()
				return nil
			end,
			get_upstream_ref = function()
				return nil
			end,
			get_commit_log = function(base, tip)
				table.insert(ranges, { base = base, tip = tip })
				return vim.deepcopy(COMMITS)
			end,
		})
		session.start(nil)
		assert.equals(1, #ranges)
		assert.is_nil(ranges[1].base)
		assert.equals("feat/x", ranges[1].tip)
	end)

	it("keeps the cached commit list while a commit is checked out", function()
		local log_calls = 0
		mock_commit_git({
			get_commit_log = function()
				log_calls = log_calls + 1
				return vim.deepcopy(COMMITS)
			end,
		})
		session.start(nil)
		assert.equals(1, log_calls)
		session.set_scope("commit", { commit_sha = "c1sha" })

		-- @{upstream} does not resolve on a detached HEAD, so re-reading here
		-- would silently change the range under the user.
		session.reload(true)
		assert.equals(1, log_calls)
		assert.equals(2, #config.state.local_session.commits)
		assert.equals("Local: 1/2", require("fude.scope").statusline())
	end)
end)

describe("session.resolve_commit_range_base", function()
	it("uses the base branch on a feature branch", function()
		assert.equals("main", session.resolve_commit_range_base("main", "feat/x", "origin/feat/x"))
	end)

	it("uses the upstream on the base branch itself", function()
		assert.equals("origin/main", session.resolve_commit_range_base("main", "main", "origin/main"))
	end)

	it("uses the upstream when there is no base", function()
		assert.equals("origin/main", session.resolve_commit_range_base(nil, "main", "origin/main"))
	end)

	it("lists everything when there is neither", function()
		assert.is_nil(session.resolve_commit_range_base(nil, "main", nil))
		assert.is_nil(session.resolve_commit_range_base("main", "main", nil))
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

	it("base resolves both the diff base and the content ref to the merge-base sha", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_merge_base", function(ref)
			assert.equals("main", ref)
			return "mergesha"
		end)
		local diff_base, content_ref = session.resolve_scope_base("base", "main")
		assert.equals("mergesha", diff_base)
		-- Returning the base branch ("main") here would make the preview pane show the
		-- base branch tip while the changed-files list stays on the merge-base.
		assert.equals("mergesha", content_ref)
	end)

	it("returns nil when the merge-base cannot be resolved", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_merge_base", function()
			return nil
		end)
		local diff_base = session.resolve_scope_base("base", "main")
		assert.is_nil(diff_base)
	end)

	it("returns nil for base scope when there is no base ref (no crash)", function()
		local diff_base, content_ref = session.resolve_scope_base("base", nil)
		assert.is_nil(diff_base)
		assert.is_nil(content_ref)
	end)

	it("unpushed resolves to the upstream ref", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_upstream_ref", function()
			return "origin/feat/a"
		end)
		local diff_base, content_ref = session.resolve_scope_base("unpushed", "main", "/repo")
		assert.equals("origin/feat/a", diff_base)
		assert.equals("origin/feat/a", content_ref)
	end)

	it("unpushed returns nil when there is no upstream", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_upstream_ref", function()
			return nil
		end)
		local diff_base = session.resolve_scope_base("unpushed", "main", "/repo")
		assert.is_nil(diff_base)
	end)

	it("commit resolves to the commit's parent", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_parent", function(sha, cwd)
			assert.equals("abc123", sha)
			assert.equals("/repo", cwd)
			return "parent1", "parent"
		end)
		local diff_base, content_ref = session.resolve_scope_base("commit", "main", "/repo", "abc123")
		-- Both refs must be the parent: the caller checks abc123 out, so
		-- `git diff <parent>` against the working tree is that commit's own diff.
		assert.equals("parent1", diff_base)
		assert.equals("parent1", content_ref)
	end)

	it("commit falls back to the empty tree for a root commit", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_parent", function()
			return nil, "root"
		end)
		helpers.mock(diff, "get_empty_tree", function()
			return "emptyhash"
		end)
		local diff_base, content_ref = session.resolve_scope_base("commit", "main", "/repo", "root1")
		assert.equals("emptyhash", diff_base)
		assert.equals("emptyhash", content_ref)
	end)

	it("commit refuses when the parent is recorded but unreachable (shallow clone)", function()
		local diff = require("fude.diff")
		helpers.mock(diff, "get_parent", function()
			return nil, "missing"
		end)
		local empty_tree_asked = false
		helpers.mock(diff, "get_empty_tree", function()
			empty_tree_asked = true
			return "emptyhash"
		end)
		local diff_base, content_ref = session.resolve_scope_base("commit", "main", "/repo", "edge1")
		-- The empty tree would show the whole snapshot as added — not that commit
		assert.is_nil(diff_base)
		assert.is_nil(content_ref)
		assert.is_false(empty_tree_asked)
	end)

	it("commit returns nil without a commit sha", function()
		local diff_base, content_ref = session.resolve_scope_base("commit", "main", "/repo", nil)
		assert.is_nil(diff_base)
		assert.is_nil(content_ref)
	end)
end)

describe("session.build_commit_specs", function()
	it("labels each commit with its position, short sha and subject", function()
		local specs = session.build_commit_specs({
			{ sha = "aaa1", short_sha = "aaa1111", subject = "feat: first" },
			{ sha = "bbb2", short_sha = "bbb2222", subject = "fix: second" },
		})
		assert.equals(2, #specs)
		assert.equals("commit", specs[1].scope)
		assert.equals("aaa1", specs[1].commit_sha)
		assert.equals(1, specs[1].commit_index)
		assert.equals("Commit [1/2] aaa1111 feat: first", specs[1].label)
		assert.equals("Commit [2/2] bbb2222 fix: second", specs[2].label)
	end)

	it("returns an empty list for no commits", function()
		assert.same({}, session.build_commit_specs(nil))
		assert.same({}, session.build_commit_specs({}))
	end)
end)

describe("session.scope_specs", function()
	local diff = require("fude.diff")

	after_each(function()
		helpers.cleanup()
	end)

	local function session_of(fields)
		return vim.tbl_extend("force", { worktree_root = "/repo", scope = "base" }, fields)
	end

	it("offers base + unpushed + uncommitted on a pushed feature branch", function()
		helpers.mock(diff, "get_upstream_ref", function()
			return "origin/feat/x"
		end)
		local specs = session.scope_specs(session_of({ base_ref = "main", branch = "feat/x", scope = "unpushed" }))
		assert.equals(3, #specs)
		assert.equals("base", specs[1].scope)
		assert.equals("Base branch (main)", specs[1].label)
		assert.equals("unpushed", specs[2].scope)
		assert.equals("Unpushed (origin/feat/x)", specs[2].label)
		assert.is_true(specs[2].is_current)
		assert.equals("uncommitted", specs[3].scope)
	end)

	it("hides base when the branch is the base branch", function()
		helpers.mock(diff, "get_upstream_ref", function()
			return "origin/main"
		end)
		local specs = session.scope_specs(session_of({ base_ref = "main", branch = "main" }))
		local scopes = vim.tbl_map(function(s)
			return s.scope
		end, specs)
		assert.same({ "unpushed", "uncommitted" }, scopes)
	end)

	it("hides unpushed when there is no upstream", function()
		helpers.mock(diff, "get_upstream_ref", function()
			return nil
		end)
		local specs = session.scope_specs(session_of({ base_ref = "main", branch = "feat/x" }))
		local scopes = vim.tbl_map(function(s)
			return s.scope
		end, specs)
		assert.same({ "base", "uncommitted" }, scopes)
	end)

	it("appends one entry per cached commit", function()
		helpers.mock(diff, "get_upstream_ref", function()
			return nil
		end)
		local specs = session.scope_specs(session_of({
			base_ref = "main",
			branch = "feat/x",
			commits = {
				{ sha = "aaa1", short_sha = "aaa1111", subject = "feat: first" },
				{ sha = "bbb2", short_sha = "bbb2222", subject = "fix: second" },
			},
		}))
		local scopes = vim.tbl_map(function(s)
			return s.scope
		end, specs)
		assert.same({ "base", "uncommitted", "commit", "commit" }, scopes)
		assert.equals("aaa1", specs[3].commit_sha)
	end)

	it("marks the current commit by sha, not by scope name", function()
		helpers.mock(diff, "get_upstream_ref", function()
			return nil
		end)
		local specs = session.scope_specs(session_of({
			base_ref = "main",
			branch = "feat/x",
			scope = "commit",
			scope_commit_sha = "bbb2",
			commits = {
				{ sha = "aaa1", short_sha = "aaa1111", subject = "feat: first" },
				{ sha = "bbb2", short_sha = "bbb2222", subject = "fix: second" },
			},
		}))
		assert.is_falsy(specs[3].is_current)
		assert.is_true(specs[4].is_current)
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

	it("shows the commit position for commit scope", function()
		assert.equals("Local: 2/5", scope.format_local_scope_label("main", "commit", 2, 5))
		-- A commit scope with no cached list must still render something.
		assert.equals("Local: ?/?", scope.format_local_scope_label("main", "commit"))
	end)
end)
