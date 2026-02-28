local files = require("reviewit.files")

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
