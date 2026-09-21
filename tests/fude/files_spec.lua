local files = require("fude.files")

describe("build_file_entries", function()
	local icons = files.status_icons

	it("builds entries from changed files", function()
		local changed = {
			{ path = "a.lua", status = "added", additions = 10, deletions = 0, patch = "@@ diff" },
			{ path = "b.lua", status = "modified", additions = 5, deletions = 3, patch = "@@ diff2" },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal(2, #entries)
		assert.are.equal("/repo/a.lua", entries[1].filename)
		assert.are.equal("+", entries[1].status_icon)
		assert.are.equal("DiffAdd", entries[1].status_hl)
		assert.are.equal(10, entries[1].additions)
		assert.are.equal("~", entries[2].status_icon)
		assert.are.equal("DiffChange", entries[2].status_hl)
	end)

	it("handles removed files", function()
		local changed = {
			{ path = "f.lua", status = "removed", additions = 0, deletions = 20 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal("-", entries[1].status_icon)
		assert.are.equal("DiffDelete", entries[1].status_hl)
		-- The raw status must survive normalization: the sidepanel's post-switch
		-- auto-open skips entries with status == "removed"
		assert.are.equal("removed", entries[1].status)
	end)

	it("keeps the raw status on entries for non-removed files", function()
		local changed = {
			{ path = "m.lua", status = "modified", additions = 1, deletions = 1 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal("modified", entries[1].status)
	end)

	it("uses ? for unknown status", function()
		local changed = {
			{ path = "c.lua", status = "unknown_status", additions = 0, deletions = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal("?", entries[1].status_icon)
		assert.are.equal("DiffChange", entries[1].status_hl)
	end)

	it("defaults additions and deletions to 0", function()
		local changed = {
			{ path = "d.lua", status = "modified" },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal(0, entries[1].additions)
		assert.are.equal(0, entries[1].deletions)
	end)

	it("defaults patch to empty string", function()
		local changed = {
			{ path = "e.lua", status = "added", additions = 1, deletions = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal("", entries[1].patch)
	end)

	it("returns empty for empty input", function()
		local entries = files.build_file_entries({}, "/repo", icons)
		assert.are.same({}, entries)
	end)

	it("handles renamed and copied statuses", function()
		local changed = {
			{ path = "r.lua", status = "renamed", additions = 0, deletions = 0 },
			{ path = "c.lua", status = "copied", additions = 0, deletions = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal("R", entries[1].status_icon)
		assert.are.equal("C", entries[2].status_icon)
	end)

	it("includes viewed icon for VIEWED files", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local viewed = { ["a.lua"] = "VIEWED" }
		local entries = files.build_file_entries(changed, "/repo", icons, viewed, "✓")
		assert.are.equal("✓", entries[1].viewed_icon)
		assert.are.equal("DiagnosticOk", entries[1].viewed_hl)
	end)

	it("shows space for UNVIEWED files", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local viewed = { ["a.lua"] = "UNVIEWED" }
		local entries = files.build_file_entries(changed, "/repo", icons, viewed, "✓")
		assert.are.equal(" ", entries[1].viewed_icon)
		assert.are.equal("Comment", entries[1].viewed_hl)
	end)

	it("shows space for DISMISSED files", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local viewed = { ["a.lua"] = "DISMISSED" }
		local entries = files.build_file_entries(changed, "/repo", icons, viewed, "✓")
		assert.are.equal(" ", entries[1].viewed_icon)
		assert.are.equal("Comment", entries[1].viewed_hl)
	end)

	it("defaults viewed to space when viewed_files is nil", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons, nil, "✓")
		assert.are.equal(" ", entries[1].viewed_icon)
	end)

	it("uses custom viewed sign", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local viewed = { ["a.lua"] = "VIEWED" }
		local entries = files.build_file_entries(changed, "/repo", icons, viewed, "V")
		assert.are.equal("V", entries[1].viewed_icon)
	end)
end)

describe("viewed_icon", function()
	it("returns viewed sign for VIEWED state", function()
		local icon, hl = files.viewed_icon("VIEWED", "✓")
		assert.are.equal("✓", icon)
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns space for UNVIEWED state", function()
		local icon, hl = files.viewed_icon("UNVIEWED", "✓")
		assert.are.equal(" ", icon)
		assert.are.equal("Comment", hl)
	end)

	it("returns space for DISMISSED state", function()
		local icon, hl = files.viewed_icon("DISMISSED", "✓")
		assert.are.equal(" ", icon)
		assert.are.equal("Comment", hl)
	end)

	it("returns space for nil state", function()
		local icon, hl = files.viewed_icon(nil, "✓")
		assert.are.equal(" ", icon)
		assert.are.equal("Comment", hl)
	end)
end)

describe("status_icons", function()
	it("has all expected statuses", function()
		assert.are.equal("+", files.status_icons.added)
		assert.are.equal("~", files.status_icons.modified)
		assert.are.equal("-", files.status_icons.removed)
		assert.are.equal("R", files.status_icons.renamed)
		assert.are.equal("C", files.status_icons.copied)
	end)
end)

describe("picker_title", function()
	it("uses the PR number when present", function()
		assert.equals("PR #42 Changed Files", files.picker_title(42))
	end)

	it("falls back to a neutral label for local review (no PR)", function()
		assert.equals("Local Review: Changed Files", files.picker_title(nil))
	end)
end)

describe("resolve_patch", function()
	local config = require("fude.config")
	local diff = require("fude.diff")
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("returns the entry's own patch when it has one", function()
		assert.equals("@@ diff @@", files.resolve_patch({ path = "f.lua", patch = "@@ diff @@" }))
	end)

	it("generates the patch on demand in local review mode", function()
		config.state.review_mode = "local"
		config.state.local_session = { base_sha = "basesha" }
		helpers.mock(diff, "get_review_patch", function(base, path)
			assert.equals("basesha", base)
			assert.equals("f.lua", path)
			return "generated diff"
		end)
		assert.equals("generated diff", files.resolve_patch({ path = "f.lua", patch = "" }))
	end)

	it("returns empty string when local generation finds no diff", function()
		config.state.review_mode = "local"
		config.state.local_session = { base_sha = "basesha" }
		helpers.mock(diff, "get_review_patch", function()
			return nil
		end)
		assert.equals("", files.resolve_patch({ path = "f.lua", patch = "" }))
	end)

	it("does not generate a patch in GitHub review mode", function()
		config.state.review_mode = "github"
		local called = false
		helpers.mock(diff, "get_review_patch", function()
			called = true
			return "x"
		end)
		assert.equals("", files.resolve_patch({ path = "f.lua", patch = "" }))
		assert.is_false(called)
	end)
end)

describe("comment_count_display", function()
	it("returns empty string for zero comments", function()
		local display, hl = files.comment_count_display(0, 0, 0)
		assert.are.equal("", display)
		assert.are.equal("Comment", hl)
	end)

	it("returns display with DiagnosticInfo for submitted only", function()
		local display, hl = files.comment_count_display(3, 0, 0)
		assert.are.equal("💬3", display)
		assert.are.equal("DiagnosticInfo", hl)
	end)

	it("returns display with DiagnosticHint for pending comments", function()
		local display, hl = files.comment_count_display(2, 1, 0)
		assert.are.equal("💬3", display)
		assert.are.equal("DiagnosticHint", hl)
	end)

	it("handles pending only (no submitted)", function()
		local display, hl = files.comment_count_display(0, 2, 0)
		assert.are.equal("💬2", display)
		assert.are.equal("DiagnosticHint", hl)
	end)

	it("handles nil values", function()
		local display, hl = files.comment_count_display(nil, nil, nil)
		assert.are.equal("", display)
		assert.are.equal("Comment", hl)
	end)

	it("handles double digit counts", function()
		local display, hl = files.comment_count_display(10, 5, 0)
		assert.are.equal("💬15", display)
		assert.are.equal("DiagnosticHint", hl)
	end)

	it("shows outdated count when present", function()
		local display, hl = files.comment_count_display(5, 0, 2)
		assert.are.equal("💬5(outdated:2)", display)
		assert.are.equal("DiagnosticInfo", hl)
	end)

	it("shows outdated with pending", function()
		local display, hl = files.comment_count_display(3, 1, 1)
		assert.are.equal("💬4(outdated:1)", display)
		assert.are.equal("DiagnosticHint", hl)
	end)

	it("does not show outdated when zero", function()
		local display, hl = files.comment_count_display(3, 0, 0)
		assert.are.equal("💬3", display)
		assert.are.equal("DiagnosticInfo", hl)
	end)
end)

describe("build_file_entries with comment_counts", function()
	local icons = files.status_icons

	it("includes comment_count and display fields", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local comment_counts = {
			["a.lua"] = { submitted = 2, pending = 1, outdated = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons, nil, "✓", comment_counts)
		assert.are.equal(3, entries[1].comment_count)
		assert.are.equal("💬3", entries[1].comment_display)
		assert.are.equal("DiagnosticHint", entries[1].comment_hl)
	end)

	it("shows outdated count in display", function()
		local changed = {
			{ path = "a.lua", status = "modified", additions = 1, deletions = 0 },
		}
		local comment_counts = {
			["a.lua"] = { submitted = 3, pending = 0, outdated = 1 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons, nil, "✓", comment_counts)
		assert.are.equal(3, entries[1].comment_count)
		assert.are.equal("💬3(outdated:1)", entries[1].comment_display)
		assert.are.equal("DiagnosticInfo", entries[1].comment_hl)
	end)

	it("defaults to zero counts when comment_counts missing file", function()
		local changed = {
			{ path = "b.lua", status = "added", additions = 10, deletions = 0 },
		}
		local comment_counts = {
			["a.lua"] = { submitted = 2, pending = 0, outdated = 0 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons, nil, "✓", comment_counts)
		assert.are.equal(0, entries[1].comment_count)
		assert.are.equal("", entries[1].comment_display)
	end)

	it("defaults to zero counts when comment_counts is nil", function()
		local changed = {
			{ path = "c.lua", status = "modified", additions = 1, deletions = 1 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons, nil, "✓", nil)
		assert.are.equal(0, entries[1].comment_count)
		assert.are.equal("", entries[1].comment_display)
	end)

	it("backward compatible - works without comment_counts parameter", function()
		local changed = {
			{ path = "d.lua", status = "modified", additions = 5, deletions = 2 },
		}
		local entries = files.build_file_entries(changed, "/repo", icons)
		assert.are.equal(0, entries[1].comment_count)
		assert.are.equal("", entries[1].comment_display)
	end)
end)

describe("count_viewed", function()
	it("counts all VIEWED files", function()
		local viewed = { ["a.lua"] = "VIEWED", ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED" }
		local changed = { { path = "a.lua" }, { path = "b.lua" }, { path = "c.lua" } }
		assert.are.equal(3, files.count_viewed(viewed, changed))
	end)

	it("counts only VIEWED, not UNVIEWED or DISMISSED", function()
		local viewed = { ["a.lua"] = "VIEWED", ["b.lua"] = "UNVIEWED", ["c.lua"] = "DISMISSED" }
		local changed = { { path = "a.lua" }, { path = "b.lua" }, { path = "c.lua" } }
		assert.are.equal(1, files.count_viewed(viewed, changed))
	end)

	it("returns 0 when no files are VIEWED", function()
		local viewed = { ["a.lua"] = "UNVIEWED", ["b.lua"] = "UNVIEWED" }
		local changed = { { path = "a.lua" }, { path = "b.lua" } }
		assert.are.equal(0, files.count_viewed(viewed, changed))
	end)

	it("returns 0 for empty changed_files", function()
		local viewed = { ["a.lua"] = "VIEWED" }
		assert.are.equal(0, files.count_viewed(viewed, {}))
	end)

	it("returns 0 when viewed_files is nil", function()
		local changed = { { path = "a.lua" }, { path = "b.lua" } }
		assert.are.equal(0, files.count_viewed(nil, changed))
	end)

	it("ignores paths in viewed_files not in changed_files", function()
		local viewed = { ["a.lua"] = "VIEWED", ["x.lua"] = "VIEWED" }
		local changed = { { path = "a.lua" }, { path = "b.lua" } }
		assert.are.equal(1, files.count_viewed(viewed, changed))
	end)
end)

describe("apply_viewed_toggle", function()
	local config = require("fude.config")
	local helpers = require("tests.helpers")
	local gh

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.pr_node_id = "PR_node_1"
		config.state.viewed_files = {}
		gh = require("fude.gh")
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("transitions UNVIEWED to VIEWED via mark_file_viewed and emits updated fields", function()
		local mark_calls = {}
		helpers.mock(gh, "mark_file_viewed", function(pr_id, path, cb)
			table.insert(mark_calls, { pr_id = pr_id, path = path })
			vim.schedule(function()
				cb(nil)
			end)
		end)
		helpers.mock(gh, "unmark_file_viewed", function(_, _, _)
			error("unmark_file_viewed should not be called")
		end)

		local received
		files.apply_viewed_toggle("src/foo.lua", function(updated)
			received = updated
		end)

		assert.is_true(helpers.wait_for(function()
			return received ~= nil
		end, 500))
		assert.are.equal(1, #mark_calls)
		assert.are.equal("PR_node_1", mark_calls[1].pr_id)
		assert.are.equal("src/foo.lua", mark_calls[1].path)
		assert.are.equal("VIEWED", config.state.viewed_files["src/foo.lua"])
		assert.are.equal("src/foo.lua", received.path)
		assert.are.equal("VIEWED", received.viewed_state)
		assert.are.equal("✓", received.viewed_icon)
		assert.are.equal("DiagnosticOk", received.viewed_hl)
	end)

	it("transitions VIEWED to UNVIEWED via unmark_file_viewed", function()
		config.state.viewed_files["src/bar.lua"] = "VIEWED"
		local unmark_calls = {}
		helpers.mock(gh, "unmark_file_viewed", function(_, path, cb)
			table.insert(unmark_calls, path)
			vim.schedule(function()
				cb(nil)
			end)
		end)
		helpers.mock(gh, "mark_file_viewed", function(_, _, _)
			error("mark_file_viewed should not be called")
		end)

		local received
		files.apply_viewed_toggle("src/bar.lua", function(updated)
			received = updated
		end)

		assert.is_true(helpers.wait_for(function()
			return received ~= nil
		end, 500))
		assert.are.equal("src/bar.lua", unmark_calls[1])
		assert.are.equal("UNVIEWED", config.state.viewed_files["src/bar.lua"])
		assert.are.equal("UNVIEWED", received.viewed_state)
		assert.are.equal(" ", received.viewed_icon)
		assert.are.equal("Comment", received.viewed_hl)
	end)

	it("does not invoke on_done and does not mutate state when gh returns an error", function()
		helpers.mock(gh, "mark_file_viewed", function(_, _, cb)
			vim.schedule(function()
				cb("network error")
			end)
		end)

		local invoked = false
		files.apply_viewed_toggle("src/baz.lua", function(_)
			invoked = true
		end)

		-- vim.wait returns true iff the condition became true before timeout.
		-- We expect the callback to NEVER fire, so fired must stay false.
		local fired = vim.wait(100, function()
			return invoked
		end)
		assert.is_false(fired)
		assert.is_nil(config.state.viewed_files["src/baz.lua"])
	end)

	it("returns early without calling gh when pr_node_id is nil", function()
		config.state.pr_node_id = nil
		local gh_called = false
		helpers.mock(gh, "mark_file_viewed", function(_, _, _)
			gh_called = true
		end)

		local invoked = false
		files.apply_viewed_toggle("src/qux.lua", function(_)
			invoked = true
		end)

		-- Neither gh nor on_done should fire; vim.wait only returns true if one of them does.
		local fired = vim.wait(50, function()
			return gh_called or invoked
		end)
		assert.is_false(fired)
	end)
end)

describe("find_adjacent_file_index", function()
	local changed = {
		{ path = "a.lua" },
		{ path = "b.lua" },
		{ path = "c.lua" },
	}

	it("returns nil for empty list", function()
		assert.is_nil(files.find_adjacent_file_index({}, "a.lua", "next"))
		assert.is_nil(files.find_adjacent_file_index({}, "a.lua", "prev"))
	end)

	it("returns next index", function()
		assert.are.equal(2, files.find_adjacent_file_index(changed, "a.lua", "next"))
		assert.are.equal(3, files.find_adjacent_file_index(changed, "b.lua", "next"))
	end)

	it("returns prev index", function()
		assert.are.equal(1, files.find_adjacent_file_index(changed, "b.lua", "prev"))
		assert.are.equal(2, files.find_adjacent_file_index(changed, "c.lua", "prev"))
	end)

	it("wraps around forward at the last entry", function()
		assert.are.equal(1, files.find_adjacent_file_index(changed, "c.lua", "next"))
	end)

	it("wraps around backward at the first entry", function()
		assert.are.equal(3, files.find_adjacent_file_index(changed, "a.lua", "prev"))
	end)

	it("starts from first entry on next when current is not in list", function()
		assert.are.equal(1, files.find_adjacent_file_index(changed, "x.lua", "next"))
		assert.are.equal(1, files.find_adjacent_file_index(changed, nil, "next"))
	end)

	it("starts from last entry on prev when current is not in list", function()
		assert.are.equal(3, files.find_adjacent_file_index(changed, "x.lua", "prev"))
		assert.are.equal(3, files.find_adjacent_file_index(changed, nil, "prev"))
	end)

	it("handles single-entry list (next/prev both return 1)", function()
		local single = { { path = "only.lua" } }
		assert.are.equal(1, files.find_adjacent_file_index(single, "only.lua", "next"))
		assert.are.equal(1, files.find_adjacent_file_index(single, "only.lua", "prev"))
	end)
end)

describe("find_adjacent_unviewed_index", function()
	local changed = {
		{ path = "a.lua" },
		{ path = "b.lua" },
		{ path = "c.lua" },
		{ path = "d.lua" },
	}

	it("returns nil for empty list", function()
		assert.is_nil(files.find_adjacent_unviewed_index({}, "a.lua", "next", {}))
		assert.is_nil(files.find_adjacent_unviewed_index({}, "a.lua", "prev", {}))
	end)

	it("skips viewed files going forward", function()
		local viewed = { ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED" }
		assert.are.equal(4, files.find_adjacent_unviewed_index(changed, "a.lua", "next", viewed))
	end)

	it("skips viewed files going backward", function()
		local viewed = { ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED" }
		assert.are.equal(1, files.find_adjacent_unviewed_index(changed, "d.lua", "prev", viewed))
	end)

	it("treats UNVIEWED and DISMISSED as not viewed", function()
		local viewed = { ["b.lua"] = "UNVIEWED", ["c.lua"] = "DISMISSED" }
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "a.lua", "next", viewed))
		assert.are.equal(3, files.find_adjacent_unviewed_index(changed, "d.lua", "prev", viewed))
	end)

	it("wraps around forward past the end", function()
		local viewed = { ["a.lua"] = "VIEWED" }
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "d.lua", "next", viewed))
	end)

	it("wraps around backward past the start", function()
		local viewed = { ["d.lua"] = "VIEWED" }
		assert.are.equal(3, files.find_adjacent_unviewed_index(changed, "a.lua", "prev", viewed))
	end)

	it("starts from the first unviewed entry when the current file is not in the list", function()
		local viewed = { ["a.lua"] = "VIEWED" }
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "x.lua", "next", viewed))
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, nil, "next", viewed))
	end)

	it("starts from the last unviewed entry on prev when the current file is not in the list", function()
		local viewed = { ["d.lua"] = "VIEWED" }
		assert.are.equal(3, files.find_adjacent_unviewed_index(changed, "x.lua", "prev", viewed))
		assert.are.equal(3, files.find_adjacent_unviewed_index(changed, nil, "prev", viewed))
	end)

	it("returns nil when every file has been viewed", function()
		local viewed = { ["a.lua"] = "VIEWED", ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED", ["d.lua"] = "VIEWED" }
		assert.is_nil(files.find_adjacent_unviewed_index(changed, "a.lua", "next", viewed))
		assert.is_nil(files.find_adjacent_unviewed_index(changed, "a.lua", "prev", viewed))
	end)

	it("returns the current file when it is the only unviewed one", function()
		local viewed = { ["a.lua"] = "VIEWED", ["c.lua"] = "VIEWED", ["d.lua"] = "VIEWED" }
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "b.lua", "next", viewed))
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "b.lua", "prev", viewed))
	end)

	it("treats a nil viewed map as nothing viewed", function()
		assert.are.equal(2, files.find_adjacent_unviewed_index(changed, "a.lua", "next", nil))
		assert.are.equal(4, files.find_adjacent_unviewed_index(changed, "a.lua", "prev", nil))
	end)

	it("skips files removed by the PR, which cannot be opened", function()
		local with_removed = {
			{ path = "a.lua", status = "modified" },
			{ path = "gone.lua", status = "removed" },
			{ path = "c.lua", status = "modified" },
		}
		assert.are.equal(3, files.find_adjacent_unviewed_index(with_removed, "a.lua", "next", {}))
		assert.are.equal(1, files.find_adjacent_unviewed_index(with_removed, "c.lua", "prev", {}))
	end)

	it("returns nil when the only unviewed files were removed by the PR", function()
		local with_removed = {
			{ path = "a.lua", status = "modified" },
			{ path = "gone.lua", status = "removed" },
		}
		assert.is_nil(files.find_adjacent_unviewed_index(with_removed, "a.lua", "next", { ["a.lua"] = "VIEWED" }))
	end)
end)

describe("has_unviewed_target", function()
	it("is true while any file is neither viewed nor removed", function()
		local changed = { { path = "a.lua" }, { path = "b.lua" } }
		assert.is_true(files.has_unviewed_target(changed, { ["a.lua"] = "VIEWED" }))
	end)

	it("is false once every file has been viewed", function()
		local changed = { { path = "a.lua" }, { path = "b.lua" } }
		assert.is_false(files.has_unviewed_target(changed, { ["a.lua"] = "VIEWED", ["b.lua"] = "VIEWED" }))
	end)

	it("does not count files removed by the PR as targets", function()
		local changed = { { path = "a.lua", status = "modified" }, { path = "gone.lua", status = "removed" } }
		assert.is_false(files.has_unviewed_target(changed, { ["a.lua"] = "VIEWED" }))
	end)

	it("is false for an empty list and treats a nil viewed map as nothing viewed", function()
		assert.is_false(files.has_unviewed_target({}, nil))
		assert.is_true(files.has_unviewed_target({ { path = "a.lua" } }, nil))
	end)
end)

describe("build_navigation_order", function()
	local function paths(entries)
		local out = {}
		for _, e in ipairs(entries) do
			table.insert(out, e.path)
		end
		return out
	end

	local changed = {
		{ path = "lua/z.lua", status = "modified" },
		{ path = "lua/fude/b.lua", status = "modified" },
		{ path = "README.md", status = "modified" },
		{ path = "lua/fude/a.lua", status = "added" },
	}

	it("returns changed_files unchanged in flat mode", function()
		local result = files.build_navigation_order(changed, false)
		assert.are.same(changed, result)
	end)

	it("reorders to match the sidepanel tree render order in tree mode", function()
		-- Tree order: directories then files, each alphabetical, depth-first.
		-- lua/ before README.md (directory precedes file); within lua/, the
		-- fude/ subdir precedes lua/z.lua; within fude/, a.lua before b.lua.
		local result = files.build_navigation_order(changed, true)
		assert.are.same({
			"lua/fude/a.lua",
			"lua/fude/b.lua",
			"lua/z.lua",
			"README.md",
		}, paths(result))
	end)

	it("preserves the original file entry fields in tree mode", function()
		local result = files.build_navigation_order(changed, true)
		assert.are.equal("added", result[1].status)
		assert.are.equal("lua/fude/a.lua", result[1].path)
	end)

	it("returns every file exactly once in tree mode", function()
		local result = files.build_navigation_order(changed, true)
		assert.are.equal(#changed, #result)
	end)

	it("returns an empty list for empty input in tree mode", function()
		assert.are.same({}, files.build_navigation_order({}, true))
	end)
end)

describe("next_file / prev_file", function()
	local config = require("fude.config")
	local diff = require("fude.diff")
	local helpers = require("tests.helpers")

	local last_cmd

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.changed_files = {
			{ path = "a.lua" },
			{ path = "b.lua" },
			{ path = "c.lua" },
		}
		helpers.mock(diff, "get_repo_root", function()
			return "/repo"
		end)
		last_cmd = nil
		helpers.mock(vim, "cmd", function(c)
			last_cmd = c
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	-- Stub make_relative so the "current buffer" can be controlled per-test
	-- without depending on the actual current buffer name or filesystem.
	local function set_current_path(rel)
		helpers.mock(diff, "make_relative", function(_, _)
			return rel
		end)
	end

	it("notifies and does nothing when not active", function()
		config.state.active = false
		local notified = false
		helpers.mock(vim, "notify", function(msg, _)
			if msg:find("Not active", 1, true) then
				notified = true
			end
		end)
		files.next_file()
		assert.is_true(notified)
		assert.is_nil(last_cmd)
	end)

	it("notifies and does nothing when changed_files is empty", function()
		config.state.changed_files = {}
		local notified = false
		helpers.mock(vim, "notify", function(msg, _)
			if msg:find("No changed files", 1, true) then
				notified = true
			end
		end)
		files.next_file()
		assert.is_true(notified)
		assert.is_nil(last_cmd)
	end)

	it("opens the next file relative to the current buffer", function()
		set_current_path("a.lua")
		files.next_file()
		assert.are.equal("edit /repo/b.lua", last_cmd)
	end)

	it("wraps from the last file to the first on next", function()
		set_current_path("c.lua")
		files.next_file()
		assert.are.equal("edit /repo/a.lua", last_cmd)
	end)

	it("opens the previous file relative to the current buffer", function()
		set_current_path("b.lua")
		files.prev_file()
		assert.are.equal("edit /repo/a.lua", last_cmd)
	end)

	it("wraps from the first file to the last on prev", function()
		set_current_path("a.lua")
		files.prev_file()
		assert.are.equal("edit /repo/c.lua", last_cmd)
	end)

	it("opens the first file when current buffer is not in changed_files (next)", function()
		set_current_path(nil)
		files.next_file()
		assert.are.equal("edit /repo/a.lua", last_cmd)
	end)

	it("opens the last file when current buffer is not in changed_files (prev)", function()
		set_current_path(nil)
		files.prev_file()
		assert.are.equal("edit /repo/c.lua", last_cmd)
	end)

	it("opens from the source window when invoked in the sidepanel", function()
		local sidepanel = require("fude.ui.sidepanel")
		config.state.sidepanel = { win = 10 }
		set_current_path("a.lua")
		helpers.mock(vim.api, "nvim_get_current_win", function()
			return 10
		end)
		helpers.mock(sidepanel, "find_target_window", function(panel_win)
			assert.are.equal(10, panel_win)
			return 20
		end)
		local focused_win
		helpers.mock(vim.api, "nvim_set_current_win", function(win)
			focused_win = win
		end)

		files.next_file()

		assert.are.equal(20, focused_win)
		assert.are.equal("edit /repo/b.lua", last_cmd)
	end)

	it("keeps the sidepanel when no source window is available", function()
		local sidepanel = require("fude.ui.sidepanel")
		config.state.sidepanel = { win = 10 }
		helpers.mock(vim.api, "nvim_get_current_win", function()
			return 10
		end)
		helpers.mock(sidepanel, "find_target_window", function()
			return nil
		end)
		local notification
		helpers.mock(vim, "notify", function(msg)
			notification = msg
		end)

		files.next_file()

		assert.is_nil(last_cmd)
		assert.are.equal("fude.nvim: No source window available", notification)
	end)

	describe("tree mode order", function()
		before_each(function()
			-- Flat (changed_files) order differs from the tree render order:
			-- the tree groups by directory and sorts, so z/a.lua comes before
			-- the root-level m.lua even though it is listed last.
			config.state.changed_files = {
				{ path = "m.lua" },
				{ path = "z/b.lua" },
				{ path = "z/a.lua" },
			}
		end)

		it("follows the panel's tree order when the panel is in tree mode", function()
			config.state.sidepanel = { win = 10, file_tree_mode = "tree" }
			helpers.mock(vim.api, "nvim_get_current_win", function()
				return 1 -- not the panel window
			end)

			set_current_path("z/a.lua")
			files.next_file()
			assert.are.equal("edit /repo/z/b.lua", last_cmd)

			set_current_path("z/b.lua")
			files.next_file()
			assert.are.equal("edit /repo/m.lua", last_cmd)
		end)

		it("follows the configured tree default when the panel is closed", function()
			config.setup({ sidepanel = { file_tree = "tree" } })
			config.state.active = true
			config.state.changed_files = {
				{ path = "m.lua" },
				{ path = "z/b.lua" },
				{ path = "z/a.lua" },
			}
			config.state.sidepanel = nil

			set_current_path("z/a.lua")
			files.next_file()
			assert.are.equal("edit /repo/z/b.lua", last_cmd)
		end)

		it("keeps the flat order when the panel is in flat mode", function()
			config.state.sidepanel = { win = 10, file_tree_mode = "flat" }
			helpers.mock(vim.api, "nvim_get_current_win", function()
				return 1
			end)

			set_current_path("m.lua")
			files.next_file()
			assert.are.equal("edit /repo/z/b.lua", last_cmd)
		end)
	end)
end)

describe("next_unviewed_file / prev_unviewed_file", function()
	local config = require("fude.config")
	local diff = require("fude.diff")
	local helpers = require("tests.helpers")

	local last_cmd

	before_each(function()
		config.setup({})
		config.state.active = true
		config.state.changed_files = {
			{ path = "a.lua" },
			{ path = "b.lua" },
			{ path = "c.lua" },
		}
		helpers.mock(diff, "get_repo_root", function()
			return "/repo"
		end)
		last_cmd = nil
		helpers.mock(vim, "cmd", function(c)
			last_cmd = c
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	local function set_current_path(rel)
		helpers.mock(diff, "make_relative", function(_, _)
			return rel
		end)
	end

	it("skips viewed files when moving forward", function()
		config.state.viewed_files = { ["b.lua"] = "VIEWED" }
		set_current_path("a.lua")
		files.next_unviewed_file()
		assert.are.equal("edit /repo/c.lua", last_cmd)
	end)

	it("skips viewed files when moving backward", function()
		config.state.viewed_files = { ["b.lua"] = "VIEWED" }
		set_current_path("c.lua")
		files.prev_unviewed_file()
		assert.are.equal("edit /repo/a.lua", last_cmd)
	end)

	it("notifies and stays put when every file has been viewed", function()
		config.state.viewed_files = { ["a.lua"] = "VIEWED", ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED" }
		set_current_path("a.lua")
		local notification
		helpers.mock(vim, "notify", function(msg)
			notification = msg
		end)

		files.next_unviewed_file()

		assert.is_nil(last_cmd)
		assert.are.equal("fude.nvim: No unviewed files", notification)
	end)

	it("follows the sidepanel tree order", function()
		-- Tree order is z/a.lua -> z/b.lua -> m.lua, which differs from the flat
		-- changed_files order, so this fails if navigation ignores the tree.
		config.state.changed_files = {
			{ path = "m.lua" },
			{ path = "z/b.lua" },
			{ path = "z/a.lua" },
		}
		config.state.viewed_files = { ["z/b.lua"] = "VIEWED" }
		config.state.sidepanel = { win = 10, file_tree_mode = "tree" }
		helpers.mock(vim.api, "nvim_get_current_win", function()
			return 1
		end)

		set_current_path("z/a.lua")
		files.next_unviewed_file()
		assert.are.equal("edit /repo/m.lua", last_cmd)
	end)

	it("skips files removed by the PR", function()
		config.state.changed_files = {
			{ path = "a.lua", status = "modified" },
			{ path = "gone.lua", status = "removed" },
			{ path = "c.lua", status = "modified" },
		}
		set_current_path("a.lua")
		files.next_unviewed_file()
		assert.are.equal("edit /repo/c.lua", last_cmd)
	end)

	it("keeps the cursor in the sidepanel when there is nowhere to go", function()
		-- Bailing out after the window switch would drag the user out of the panel
		-- only to report that every file has been viewed.
		local sidepanel = require("fude.ui.sidepanel")
		config.state.viewed_files = { ["a.lua"] = "VIEWED", ["b.lua"] = "VIEWED", ["c.lua"] = "VIEWED" }
		config.state.sidepanel = { win = 10 }
		helpers.mock(vim.api, "nvim_get_current_win", function()
			return 10
		end)
		helpers.mock(sidepanel, "find_target_window", function()
			return 20
		end)
		local focused_win
		helpers.mock(vim.api, "nvim_set_current_win", function(win)
			focused_win = win
		end)
		local notification
		helpers.mock(vim, "notify", function(msg)
			notification = msg
		end)

		files.next_unviewed_file()

		assert.is_nil(focused_win)
		assert.is_nil(last_cmd)
		assert.are.equal("fude.nvim: No unviewed files", notification)
	end)
end)
