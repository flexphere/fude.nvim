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
