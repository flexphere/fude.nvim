local scope = require("fude.scope")

describe("build_local_scope_entries", function()
	it("maps scope specs to sidepanel entries preserving order and current flag", function()
		local entries = scope.build_local_scope_entries({
			{ scope = "base", label = "Base branch (main)", is_current = false },
			{ scope = "unpushed", label = "Unpushed (origin/feat/a)", is_current = true },
			{ scope = "uncommitted", label = "Uncommitted (staged + unstaged)", is_current = false },
		})
		assert.equals(3, #entries)
		assert.equals("base", entries[1].local_scope)
		assert.equals("Base branch (main)", entries[1].display_text)
		assert.is_false(entries[1].is_current)
		assert.equals("unpushed", entries[2].local_scope)
		assert.is_true(entries[2].is_current)
		assert.equals("uncommitted", entries[3].value)
	end)

	it("returns no entries for an empty spec list", function()
		assert.same({}, scope.build_local_scope_entries({}))
		assert.same({}, scope.build_local_scope_entries(nil))
	end)
end)

describe("format_local_scope_label", function()
	it("labels each scope", function()
		assert.equals("Local: main", scope.format_local_scope_label("main", "base"))
		assert.equals("Local: unpushed", scope.format_local_scope_label("main", "unpushed"))
		assert.equals("Local: uncommitted", scope.format_local_scope_label("main", "uncommitted"))
		assert.equals("Local: ?", scope.format_local_scope_label(nil, "base"))
	end)
end)

describe("build_scope_entries", function()
	it("returns full PR entry first followed by commits", function()
		local commits = {
			{
				sha = "abc1234567890",
				short_sha = "abc1234",
				message = "feat: add login",
				author_name = "Alice",
				date = "2026-03-01T10:00:00Z",
			},
			{
				sha = "def5678901234",
				short_sha = "def5678",
				message = "fix: typo",
				author_name = "Bob",
				date = "2026-03-02T12:00:00Z",
			},
		}
		local entries = scope.build_scope_entries(commits, "main", "feat/login")
		assert.are.equal(3, #entries)

		-- First entry is Full PR
		assert.is_true(entries[1].is_full_pr)
		assert.are.equal("full_pr", entries[1].value)
		assert.is_nil(entries[1].sha)
		assert.truthy(entries[1].display_text:find("main"))
		assert.truthy(entries[1].display_text:find("feat/login"))

		-- Subsequent entries are commits with index
		assert.is_false(entries[2].is_full_pr)
		assert.are.equal("abc1234567890", entries[2].sha)
		assert.truthy(entries[2].display_text:find("%[1/2%]"))
		assert.truthy(entries[2].display_text:find("abc1234"))
		assert.truthy(entries[2].display_text:find("feat: add login"))
		assert.truthy(entries[2].display_text:find("Alice"))

		assert.is_false(entries[3].is_full_pr)
		assert.are.equal("def5678901234", entries[3].sha)
		assert.truthy(entries[3].display_text:find("%[2/2%]"))
	end)

	it("returns only full PR entry when no commits", function()
		local entries = scope.build_scope_entries({}, "main", "feat/x")
		assert.are.equal(1, #entries)
		assert.is_true(entries[1].is_full_pr)
	end)

	it("includes branch names in full PR display text", function()
		local entries = scope.build_scope_entries({}, "develop", "feature/auth")
		assert.truthy(entries[1].display_text:find("develop"))
		assert.truthy(entries[1].display_text:find("feature/auth"))
	end)

	it("marks reviewed commits with reviewed = true", function()
		local commits = {
			{ sha = "aaa111", short_sha = "aaa111", message = "first", author_name = "A", date = "" },
			{ sha = "bbb222", short_sha = "bbb222", message = "second", author_name = "B", date = "" },
		}
		local reviewed = { ["aaa111"] = true }
		local entries = scope.build_scope_entries(commits, "main", "dev", reviewed)

		assert.is_true(entries[2].reviewed)
		assert.is_false(entries[3].reviewed)
	end)

	it("full PR entry is always not reviewed", function()
		local reviewed = { ["abc"] = true }
		local entries = scope.build_scope_entries({}, "main", "dev", reviewed)

		assert.is_false(entries[1].reviewed)
		assert.are.equal(" ", entries[1].reviewed_icon)
	end)

	it("handles commit with nil sha without error", function()
		local commits = {
			{ sha = nil, short_sha = "", message = "broken", author_name = "C", date = "" },
		}
		local reviewed = { ["aaa"] = true }
		local entries = scope.build_scope_entries(commits, "main", "dev", reviewed)

		assert.is_false(entries[2].reviewed)
		assert.are.equal(" ", entries[2].reviewed_icon)
	end)

	it("defaults reviewed to false when reviewed_commits is nil", function()
		local commits = {
			{ sha = "aaa111", short_sha = "aaa111", message = "first", author_name = "A", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev")

		assert.is_false(entries[2].reviewed)
		assert.are.equal(" ", entries[2].reviewed_icon)
	end)

	it("includes index and total on commit entries", function()
		local commits = {
			{ sha = "aaa", short_sha = "aaa", message = "first", author_name = "A", date = "" },
			{ sha = "bbb", short_sha = "bbb", message = "second", author_name = "B", date = "" },
			{ sha = "ccc", short_sha = "ccc", message = "third", author_name = "C", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev")

		-- Full PR has no index
		assert.is_nil(entries[1].index)
		assert.are.equal(3, entries[1].total)

		-- Commits have 1-based index
		assert.are.equal(1, entries[2].index)
		assert.are.equal(3, entries[2].total)
		assert.are.equal(2, entries[3].index)
		assert.are.equal(3, entries[3].total)
		assert.are.equal(3, entries[4].index)
		assert.are.equal(3, entries[4].total)
	end)

	it("marks current scope as is_current for full_pr", function()
		local commits = {
			{ sha = "aaa", short_sha = "aaa", message = "first", author_name = "A", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev", {}, "full_pr", nil)

		assert.is_true(entries[1].is_current)
		assert.is_false(entries[2].is_current)
	end)

	it("marks current scope as is_current for commit", function()
		local commits = {
			{ sha = "aaa", short_sha = "aaa", message = "first", author_name = "A", date = "" },
			{ sha = "bbb", short_sha = "bbb", message = "second", author_name = "B", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev", {}, "commit", "bbb")

		assert.is_false(entries[1].is_current)
		assert.is_false(entries[2].is_current)
		assert.is_true(entries[3].is_current)
	end)

	it("defaults is_current to full_pr when current_scope is nil", function()
		local commits = {
			{ sha = "aaa", short_sha = "aaa", message = "first", author_name = "A", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev")

		assert.is_true(entries[1].is_current)
		assert.is_false(entries[2].is_current)
	end)
end)

describe("reviewed_icon", function()
	it("returns viewed sign for reviewed commit", function()
		local icon, hl = scope.reviewed_icon(true)
		assert.truthy(icon ~= " ")
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns space for non-reviewed commit", function()
		local icon, hl = scope.reviewed_icon(false)
		assert.are.equal(" ", icon)
		assert.are.equal("Comment", hl)
	end)
end)

describe("format_scope_label", function()
	it("returns 'Scope: PR' for full_pr scope", function()
		assert.are.equal("Scope: PR", scope.format_scope_label("full_pr", nil, 10))
	end)

	it("returns 'Scope: PR' for full_pr scope with index", function()
		assert.are.equal("Scope: PR", scope.format_scope_label("full_pr", 3, 10))
	end)

	it("returns 'Scope: 3/10' for commit scope", function()
		assert.are.equal("Scope: 3/10", scope.format_scope_label("commit", 3, 10))
	end)

	it("returns 'Scope: 1/1' for single commit", function()
		assert.are.equal("Scope: 1/1", scope.format_scope_label("commit", 1, 1))
	end)

	it("returns 'Scope: PR' when commit scope has nil index", function()
		assert.are.equal("Scope: PR", scope.format_scope_label("commit", nil, 10))
	end)
end)

describe("find_next_scope_index", function()
	it("moves from full_pr to first commit", function()
		assert.are.equal(1, scope.find_next_scope_index("full_pr", nil, 5))
	end)

	it("moves from commit 1 to commit 2", function()
		assert.are.equal(2, scope.find_next_scope_index("commit", 1, 5))
	end)

	it("wraps from last commit to full_pr", function()
		assert.are.equal(0, scope.find_next_scope_index("commit", 5, 5))
	end)

	it("stays at full_pr when no commits", function()
		assert.are.equal(0, scope.find_next_scope_index("full_pr", nil, 0))
	end)

	it("handles nil current_index as 0", function()
		assert.are.equal(1, scope.find_next_scope_index("commit", nil, 3))
	end)
end)

describe("find_prev_scope_index", function()
	it("moves from full_pr to last commit", function()
		assert.are.equal(5, scope.find_prev_scope_index("full_pr", nil, 5))
	end)

	it("moves from commit 3 to commit 2", function()
		assert.are.equal(2, scope.find_prev_scope_index("commit", 3, 5))
	end)

	it("wraps from first commit to full_pr", function()
		assert.are.equal(0, scope.find_prev_scope_index("commit", 1, 5))
	end)

	it("stays at full_pr when no commits", function()
		assert.are.equal(0, scope.find_prev_scope_index("full_pr", nil, 0))
	end)

	it("handles nil current_index as 0", function()
		assert.are.equal(0, scope.find_prev_scope_index("commit", nil, 3))
	end)
end)

describe("find_commit_index", function()
	it("finds commit by sha", function()
		local commits = { { sha = "aaa" }, { sha = "bbb" }, { sha = "ccc" } }
		assert.are.equal(2, scope.find_commit_index(commits, "bbb"))
	end)

	it("returns nil when sha not found", function()
		local commits = { { sha = "aaa" }, { sha = "bbb" } }
		assert.is_nil(scope.find_commit_index(commits, "zzz"))
	end)

	it("returns nil for empty commits", function()
		assert.is_nil(scope.find_commit_index({}, "aaa"))
	end)

	it("finds first commit", function()
		local commits = { { sha = "aaa" }, { sha = "bbb" } }
		assert.are.equal(1, scope.find_commit_index(commits, "aaa"))
	end)

	it("finds last commit", function()
		local commits = { { sha = "aaa" }, { sha = "bbb" }, { sha = "ccc" } }
		assert.are.equal(3, scope.find_commit_index(commits, "ccc"))
	end)
end)

describe("format_scope_preview_lines", function()
	local icons = { added = "+", modified = "~", removed = "-", renamed = "R", copied = "C" }

	it("formats multiple files with status icons and diff stats", function()
		local files = {
			{ filename = "lua/fude/scope.lua", status = "modified", additions = 10, deletions = 5 },
			{ filename = "lua/fude/preview.lua", status = "added", additions = 50, deletions = 0 },
			{ filename = "lua/fude/old.lua", status = "removed", additions = 0, deletions = 30 },
		}
		local lines = scope.format_scope_preview_lines(files, icons)

		assert.are.equal("Changed files: 3", lines[1])
		assert.are.equal("", lines[2])
		assert.truthy(lines[3]:find("~"))
		assert.truthy(lines[3]:find("+10"))
		assert.truthy(lines[3]:find("-5"))
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
		assert.truthy(lines[4]:find("%+"))
		assert.truthy(lines[4]:find("+50"))
		assert.truthy(lines[5]:find("%-"))
		assert.truthy(lines[5]:find("-30"))
	end)

	it("returns placeholder for empty file list", function()
		local lines, hls = scope.format_scope_preview_lines({}, icons)
		assert.are.equal(1, #lines)
		assert.are.equal("No changed files", lines[1])
		assert.are.equal(0, #hls)
	end)

	it("formats single file", function()
		local files = {
			{ filename = "README.md", status = "modified", additions = 3, deletions = 1 },
		}
		local lines = scope.format_scope_preview_lines(files, icons)
		assert.are.equal("Changed files: 1", lines[1])
		assert.are.equal(3, #lines)
		assert.truthy(lines[3]:find("README.md"))
	end)

	it("uses ? for unknown status", function()
		local files = {
			{ filename = "test.lua", status = "unknown_status", additions = 1, deletions = 0 },
		}
		local lines = scope.format_scope_preview_lines(files, icons)
		assert.truthy(lines[3]:find("?"))
	end)

	it("defaults additions and deletions to 0", function()
		local files = {
			{ filename = "test.lua", status = "added" },
		}
		local lines = scope.format_scope_preview_lines(files, icons)
		assert.truthy(lines[3]:find("+0"))
		assert.truthy(lines[3]:find("-0"))
	end)

	it("returns highlights for status icon, additions, and deletions", function()
		local files = {
			{ filename = "foo.lua", status = "modified", additions = 10, deletions = 5 },
		}
		local _, hls = scope.format_scope_preview_lines(files, icons)

		-- 3 highlights per file line: status icon, additions, deletions
		assert.are.equal(3, #hls)

		-- Status icon highlight (DiffChange for modified)
		assert.are.equal(2, hls[1][1]) -- line index (0-based, file lines start at line 2)
		assert.are.equal(2, hls[1][2]) -- col start
		assert.are.equal(3, hls[1][3]) -- col end
		assert.are.equal("DiffChange", hls[1][4])

		-- Additions highlight (DiffAdd)
		assert.are.equal("DiffAdd", hls[2][4])

		-- Deletions highlight (DiffDelete)
		assert.are.equal("DiffDelete", hls[3][4])
	end)

	it("uses DiffAdd for added status and DiffDelete for removed status", function()
		local files = {
			{ filename = "new.lua", status = "added", additions = 1, deletions = 0 },
			{ filename = "old.lua", status = "removed", additions = 0, deletions = 1 },
		}
		local _, hls = scope.format_scope_preview_lines(files, icons)

		-- First file: added → DiffAdd for icon
		assert.are.equal("DiffAdd", hls[1][4])
		-- Second file: removed → DiffDelete for icon
		assert.are.equal("DiffDelete", hls[4][4])
	end)

	it("returns 3 highlights per file", function()
		local files = {
			{ filename = "a.lua", status = "modified", additions = 1, deletions = 0 },
			{ filename = "b.lua", status = "added", additions = 2, deletions = 0 },
			{ filename = "c.lua", status = "removed", additions = 0, deletions = 3 },
		}
		local _, hls = scope.format_scope_preview_lines(files, icons)
		assert.are.equal(9, #hls)
	end)

	it("applies format_path_fn to file paths", function()
		local files = {
			{ filename = "lua/fude/scope.lua", status = "modified", additions = 10, deletions = 5 },
		}
		local tail_fn = function(p)
			return p:match("[^/]+$")
		end
		local lines = scope.format_scope_preview_lines(files, icons, tail_fn)
		assert.is_truthy(lines[3]:find("scope.lua"))
		assert.is_falsy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("uses identity when format_path_fn is nil", function()
		local files = {
			{ filename = "lua/fude/scope.lua", status = "modified", additions = 10, deletions = 5 },
		}
		local lines = scope.format_scope_preview_lines(files, icons, nil)
		assert.is_truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("falls back to original path when format_path_fn returns nil", function()
		local files = {
			{ filename = "lua/fude/scope.lua", status = "modified", additions = 10, deletions = 5 },
		}
		local nil_fn = function()
			return nil
		end
		local lines = scope.format_scope_preview_lines(files, icons, nil_fn)
		assert.is_truthy(lines[3]:find("lua/fude/scope.lua"))
	end)
end)

describe("apply_reviewed_toggle", function()
	local config = require("fude.config")
	local helpers = require("tests.helpers")

	before_each(function()
		config.setup({})
		config.state.reviewed_commits = {}
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("toggles false to true and returns reviewed display fields", function()
		local result = scope.apply_reviewed_toggle("sha1")
		assert.is_true(config.state.reviewed_commits["sha1"])
		assert.is_true(result.is_reviewed)
		assert.are.equal("✓", result.reviewed_icon)
		assert.are.equal("DiagnosticOk", result.reviewed_hl)
	end)

	it("toggles true to false and clears the reviewed_commits entry", function()
		config.state.reviewed_commits["sha2"] = true
		local result = scope.apply_reviewed_toggle("sha2")
		assert.is_nil(config.state.reviewed_commits["sha2"])
		assert.is_false(result.is_reviewed)
		assert.are.equal(" ", result.reviewed_icon)
		assert.are.equal("Comment", result.reviewed_hl)
	end)

	it("returns nil when sha is nil without touching state", function()
		config.state.reviewed_commits["other"] = true
		local result = scope.apply_reviewed_toggle(nil)
		assert.is_nil(result)
		assert.is_true(config.state.reviewed_commits["other"])
	end)
end)

describe("apply_scope on_done callback", function()
	local config = require("fude.config")
	local helpers = require("tests.helpers")
	local gh = require("fude.gh")

	local function fake_git_ok()
		-- Fake all direct git calls (rev-parse / status / checkout) as clean successes
		helpers.mock(vim, "system", function()
			return {
				wait = function()
					return { code = 0, stdout = "", stderr = "" }
				end,
			}
		end)
	end

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.pr_number = 1
		config.state.base_ref = "main"
		config.state.head_ref = "feat/x"
		config.state.merge_base_sha = "cachedbase" -- skip the real git merge-base call
		config.state.pr_commits = {}
		helpers.mock(vim, "notify", function() end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("apply_full_pr_scope calls on_done after a successful switch", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "abc1234"
		fake_git_ok()
		helpers.mock(gh, "get_pr_files", function(_, callback)
			vim.schedule(function()
				callback(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })
			end)
		end)

		local done = false
		scope.apply_full_pr_scope(function()
			done = true
		end)

		assert.is_true(helpers.wait_for(function()
			return done
		end))
		assert.are.equal("full_pr", config.state.scope)
		assert.are.equal("a.lua", config.state.changed_files[1].path)
	end)

	it("apply_full_pr_scope does not call on_done on a gh error", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "abc1234"
		fake_git_ok() -- keep the rollback checkout from touching the real repo
		helpers.mock(gh, "get_pr_files", function(_, callback)
			vim.schedule(function()
				callback("API error", nil)
			end)
		end)

		local done = false
		scope.apply_full_pr_scope(function()
			done = true
		end)

		vim.wait(100, function()
			return done
		end)
		assert.is_false(done)
		assert.are.equal("commit", config.state.scope)
	end)

	it("apply_full_pr_scope does not call on_done when already on full PR scope", function()
		config.state.scope = "full_pr"

		local done = false
		scope.apply_full_pr_scope(function()
			done = true
		end)

		vim.wait(100, function()
			return done
		end)
		assert.is_false(done)
	end)

	it("apply_commit_scope calls on_done after a successful switch", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		helpers.mock(gh, "get_commit_files", function(_, callback)
			vim.schedule(function()
				callback(nil, { { filename = "b.lua", status = "modified", additions = 2, deletions = 0 } })
			end)
		end)

		local done = false
		scope.apply_commit_scope("abc1234", function()
			done = true
		end)

		assert.is_true(helpers.wait_for(function()
			return done
		end))
		assert.are.equal("commit", config.state.scope)
		assert.are.equal("b.lua", config.state.changed_files[1].path)
	end)

	it("apply_commit_scope does not call on_done when the commit is already selected", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "abc1234"

		local done = false
		scope.apply_commit_scope("abc1234", function()
			done = true
		end)

		vim.wait(100, function()
			return done
		end)
		assert.is_false(done)
		assert.are.equal("commit", config.state.scope)
	end)

	it("apply_full_pr_scope ignores a stale callback after the session was reset", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "abc1234"
		fake_git_ok()
		helpers.mock(gh, "get_pr_files", function(_, callback)
			vim.schedule(function()
				-- The review was stopped (and possibly restarted) while the
				-- request was in flight: config.state is a different table now.
				config.reset_state()
				callback(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })
			end)
		end)

		local done = false
		scope.apply_full_pr_scope(function()
			done = true
		end)

		vim.wait(100, function()
			return done
		end)
		assert.is_false(done)
		-- The new session's state must not be touched by the stale response
		-- (reset_state defaults scope to "full_pr", so changed_files — which the
		-- stale callback would have populated — is the discriminating field)
		assert.are.equal(0, #config.state.changed_files)
	end)

	it("apply_commit_scope lets only the newest of two in-flight requests win", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		local callbacks = {}
		helpers.mock(gh, "get_commit_files", function(sha, callback)
			callbacks[sha] = callback
		end)

		local done = {}
		scope.apply_commit_scope("aaa1111", function()
			done.aaa = true
		end)
		scope.apply_commit_scope("bbb2222", function()
			done.bbb = true
		end)

		-- Responses arrive out of order: the newer request first, then the stale one
		callbacks["bbb2222"](nil, { { filename = "b.lua", status = "modified", additions = 1, deletions = 0 } })
		callbacks["aaa1111"](nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })

		assert.are.equal("bbb2222", config.state.scope_commit_sha)
		assert.are.equal("b.lua", config.state.changed_files[1].path)
		assert.is_true(done.bbb)
		assert.is_nil(done.aaa)
	end)

	it("selecting full PR during an in-flight commit switch supersedes it", function()
		-- state.scope is still "full_pr" while the commit fetch is in flight, so
		-- the full-PR no-op guard must key off the pending target, not state
		config.state.scope = "full_pr"
		fake_git_ok()
		local commit_cb, pr_cb
		helpers.mock(gh, "get_commit_files", function(_, callback)
			commit_cb = callback
		end)
		helpers.mock(gh, "get_pr_files", function(_, callback)
			pr_cb = callback
		end)

		local done = {}
		scope.apply_commit_scope("aaa1111", function()
			done.commit = true
		end)
		scope.apply_full_pr_scope(function()
			done.full_pr = true
		end)
		assert.is_not_nil(pr_cb) -- the full-PR request must not be treated as a no-op

		commit_cb(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })
		pr_cb(nil, { { filename = "p.lua", status = "modified", additions = 1, deletions = 0 } })

		assert.are.equal("full_pr", config.state.scope)
		assert.are.equal("p.lua", config.state.changed_files[1].path)
		assert.is_nil(done.commit)
		assert.is_true(done.full_pr)
	end)

	it("selecting the previous commit during an in-flight full-PR switch supersedes it", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "aaa1111"
		fake_git_ok()
		local commit_cb, pr_cb
		helpers.mock(gh, "get_commit_files", function(_, callback)
			commit_cb = callback
		end)
		helpers.mock(gh, "get_pr_files", function(_, callback)
			pr_cb = callback
		end)

		local done = {}
		scope.apply_full_pr_scope(function()
			done.full_pr = true
		end)
		scope.apply_commit_scope("aaa1111", function()
			done.commit = true
		end)
		assert.is_not_nil(commit_cb) -- re-selecting the settled commit must supersede the pending full-PR switch

		pr_cb(nil, { { filename = "p.lua", status = "modified", additions = 1, deletions = 0 } })
		commit_cb(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })

		assert.are.equal("commit", config.state.scope)
		assert.are.equal("aaa1111", config.state.scope_commit_sha)
		assert.is_nil(done.full_pr)
		assert.is_true(done.commit)
	end)

	it("re-selecting the in-flight commit dedupes into the pending request", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		local requests = 0
		local commit_cb
		helpers.mock(gh, "get_commit_files", function(_, callback)
			requests = requests + 1
			commit_cb = callback
		end)

		local done = {}
		scope.apply_commit_scope("aaa1111", function()
			done.first = true
		end)
		scope.apply_commit_scope("aaa1111", function()
			done.second = true
		end)

		assert.are.equal(1, requests) -- the second press is a no-op, not a new request
		commit_cb(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })
		assert.is_true(done.first) -- the pending request stays current and completes
		assert.is_nil(done.second)
	end)

	it("re-selecting full PR during an in-flight full-PR switch is a no-op", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "aaa1111"
		fake_git_ok()
		local requests = 0
		local pr_cb
		helpers.mock(gh, "get_pr_files", function(_, callback)
			requests = requests + 1
			pr_cb = callback
		end)

		local done = {}
		scope.apply_full_pr_scope(function()
			done.first = true
		end)
		scope.apply_full_pr_scope(function()
			done.second = true
		end)

		assert.are.equal(1, requests)
		pr_cb(nil, { { filename = "p.lua", status = "modified", additions = 1, deletions = 0 } })
		assert.is_true(done.first)
		assert.is_nil(done.second)
	end)

	it("has_pending_commit_checkout tracks an in-flight commit switch", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		local commit_cb
		helpers.mock(gh, "get_commit_files", function(_, callback)
			commit_cb = callback
		end)

		assert.is_false(scope.has_pending_commit_checkout())
		scope.apply_commit_scope("aaa1111", nil)
		assert.is_true(scope.has_pending_commit_checkout())
		commit_cb(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })
		assert.is_false(scope.has_pending_commit_checkout())
	end)

	it("cancel_pending_switch makes the in-flight callback a no-op", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		local commit_cb
		helpers.mock(gh, "get_commit_files", function(_, callback)
			commit_cb = callback
		end)

		local done = false
		scope.apply_commit_scope("aaa1111", function()
			done = true
		end)
		scope.cancel_pending_switch()
		assert.is_false(scope.has_pending_commit_checkout())

		commit_cb(nil, { { filename = "a.lua", status = "modified", additions = 1, deletions = 0 } })

		assert.is_false(done)
		assert.are.equal("full_pr", config.state.scope)
	end)

	it("refresh_preview restores the caller's focused window", function()
		local preview = require("fude.preview")
		local caller_win = vim.api.nvim_get_current_win()
		vim.cmd("vsplit")
		local source_win = vim.api.nvim_get_current_win()
		vim.cmd("vsplit")
		local preview_win = vim.api.nvim_get_current_win()
		config.state.source_win = source_win
		config.state.preview_win = preview_win
		helpers.mock(preview, "close_preview", function() end)
		helpers.mock(preview, "open_preview", function(win)
			-- The real open_preview ends focused on the source window
			vim.api.nvim_set_current_win(win)
		end)
		vim.api.nvim_set_current_win(caller_win)

		scope.refresh_preview()

		local focused = vim.api.nvim_get_current_win()
		vim.api.nvim_win_close(preview_win, true)
		vim.api.nvim_win_close(source_win, true)
		assert.are.equal(caller_win, focused)
	end)

	it("apply_commit_scope does not call on_done on a gh error", function()
		config.state.scope = "full_pr"
		fake_git_ok()
		helpers.mock(gh, "get_commit_files", function(_, callback)
			vim.schedule(function()
				callback("API error", nil)
			end)
		end)

		local done = false
		scope.apply_commit_scope("abc1234", function()
			done = true
		end)

		vim.wait(100, function()
			return done
		end)
		assert.is_false(done)
		assert.are.equal("full_pr", config.state.scope)
	end)
end)
