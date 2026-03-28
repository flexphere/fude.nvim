local sidepanel = require("fude.ui.sidepanel")

describe("format_scope_section", function()
	local scope_entries = {
		{
			is_current = true,
			is_full_pr = true,
			reviewed_icon = " ",
			reviewed_hl = "Comment",
			display_text = "PR全体 (main...feat/x)",
		},
		{
			is_current = false,
			is_full_pr = false,
			reviewed_icon = "✓",
			reviewed_hl = "DiagnosticOk",
			display_text = "[1/2] abc1234 feat: add feature (Alice)",
			sha = "abc1234567890",
		},
		{
			is_current = false,
			is_full_pr = false,
			reviewed_icon = " ",
			reviewed_hl = "Comment",
			display_text = "[2/2] def5678 fix: typo (Bob)",
			sha = "def5678901234",
		},
	}

	it("creates header and separator as first two lines", function()
		local lines = sidepanel.format_scope_section(scope_entries, 40)
		assert.are.equal(" Review Scope", lines[1])
		assert.truthy(lines[2]:find("─"))
	end)

	it("creates one line per scope entry after header", function()
		local lines, _, count = sidepanel.format_scope_section(scope_entries, 60)
		assert.are.equal(3, count)
		assert.are.equal(5, #lines) -- header + separator + 3 entries
	end)

	it("shows current scope marker for active entry", function()
		local lines = sidepanel.format_scope_section(scope_entries, 60)
		assert.truthy(lines[3]:find("▶"))
	end)

	it("shows space for non-current entries", function()
		local lines = sidepanel.format_scope_section(scope_entries, 60)
		-- Lines 4 and 5 should not have ▶
		assert.is_falsy(lines[4]:find("▶"))
		assert.is_falsy(lines[5]:find("▶"))
	end)

	it("includes reviewed icon in entry lines", function()
		local lines = sidepanel.format_scope_section(scope_entries, 60)
		-- Second scope entry (line 4) has ✓
		assert.truthy(lines[4]:find("✓"))
	end)

	it("includes display text in entry lines", function()
		local lines = sidepanel.format_scope_section(scope_entries, 80)
		assert.truthy(lines[3]:find("PR全体"))
		assert.truthy(lines[4]:find("abc1234"))
		assert.truthy(lines[5]:find("def5678"))
	end)

	it("returns highlights for header", function()
		local _, hls = sidepanel.format_scope_section(scope_entries, 40)
		-- First highlight is the header Title
		assert.are.equal(0, hls[1][1])
		assert.are.equal("Title", hls[1][4])
	end)

	it("returns DiagnosticInfo highlight for current scope", function()
		local _, hls = sidepanel.format_scope_section(scope_entries, 60)
		local found = false
		for _, hl in ipairs(hls) do
			if hl[4] == "DiagnosticInfo" then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("handles empty entries", function()
		local lines, hls, count = sidepanel.format_scope_section({}, 40)
		assert.are.equal(2, #lines) -- header + separator only
		assert.are.equal(0, count)
		assert.are.equal(1, #hls) -- just header highlight
	end)
end)

describe("format_files_section", function()
	local file_entries = {
		{
			path = "lua/fude/scope.lua",
			viewed_icon = "✓",
			viewed_hl = "DiagnosticOk",
			status_icon = "~",
			status_hl = "DiffChange",
			additions = 10,
			deletions = 5,
		},
		{
			path = "lua/fude/new.lua",
			viewed_icon = " ",
			viewed_hl = "Comment",
			status_icon = "+",
			status_hl = "DiffAdd",
			additions = 50,
			deletions = 0,
		},
	}

	it("creates header with file count", function()
		local lines = sidepanel.format_files_section(file_entries, 40)
		assert.truthy(lines[1]:find("Files %(2%)"))
	end)

	it("creates separator as second line", function()
		local lines = sidepanel.format_files_section(file_entries, 40)
		assert.truthy(lines[2]:find("─"))
	end)

	it("creates one line per file entry after header", function()
		local lines, _, count = sidepanel.format_files_section(file_entries, 60)
		assert.are.equal(2, count)
		assert.are.equal(4, #lines) -- header + separator + 2 entries
	end)

	it("shows viewed icon", function()
		local lines = sidepanel.format_files_section(file_entries, 60)
		assert.truthy(lines[3]:find("✓"))
	end)

	it("shows status icon", function()
		local lines = sidepanel.format_files_section(file_entries, 60)
		assert.truthy(lines[3]:find("~"))
		assert.truthy(lines[4]:find("%+"))
	end)

	it("shows additions and deletions", function()
		local lines = sidepanel.format_files_section(file_entries, 60)
		assert.truthy(lines[3]:find("+10"))
		assert.truthy(lines[3]:find("-5"))
	end)

	it("shows file path", function()
		local lines = sidepanel.format_files_section(file_entries, 80)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("applies format_path_fn", function()
		local fn = function(p)
			return p:match("[^/]+$")
		end
		local lines = sidepanel.format_files_section(file_entries, 80, fn)
		assert.truthy(lines[3]:find("scope.lua"))
		assert.is_falsy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("uses identity when format_path_fn is nil", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("falls back to original path when format_path_fn returns nil", function()
		local fn = function()
			return nil
		end
		local lines = sidepanel.format_files_section(file_entries, 80, fn)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("returns highlights for each file entry", function()
		local _, file_hls = sidepanel.format_files_section(file_entries, 60)
		-- header (1) + 4 highlights per file (viewed, status, adds, dels) × 2 files = 9
		assert.are.equal(9, #file_hls)
	end)

	it("handles empty entries", function()
		local lines, _, count = sidepanel.format_files_section({}, 40)
		assert.are.equal(2, #lines) -- header + separator
		assert.are.equal(0, count)
		assert.truthy(lines[1]:find("Files %(0%)"))
	end)
end)

describe("build_sidepanel_content", function()
	it("combines scope and file sections with blank separator", function()
		local scope_lines = { "Header S", "---", "Entry S1" }
		local scope_hls = { { 0, 0, -1, "Title" } }
		local file_lines = { "Header F", "---", "Entry F1" }
		local file_hls = { { 0, 0, -1, "Title" } }

		local lines, hls, section_map =
			sidepanel.build_sidepanel_content(scope_lines, scope_hls, 1, file_lines, file_hls, 1)

		-- 3 scope + 1 blank + 3 files = 7 lines
		assert.are.equal(7, #lines)
		assert.are.equal("", lines[4]) -- blank separator
		assert.are.equal("Header F", lines[5])

		-- scope_hls line 0 stays at 0, file_hls line 0 is offset to 4
		assert.are.equal(0, hls[1][1])
		assert.are.equal(4, hls[2][1])

		-- Section map
		assert.are.equal(2, section_map.scope_start) -- 0-indexed
		assert.are.equal(2, section_map.scope_end)
		assert.are.equal(6, section_map.files_start) -- 4 (blank+header offset) + 2
		assert.are.equal(6, section_map.files_end)
	end)

	it("handles multiple entries in each section", function()
		local scope_lines = { "H", "---", "S1", "S2", "S3" }
		local scope_hls = {}
		local file_lines = { "H", "---", "F1", "F2" }
		local file_hls = {}

		local lines, _, section_map = sidepanel.build_sidepanel_content(scope_lines, scope_hls, 3, file_lines, file_hls, 2)

		-- 5 scope + 1 blank + 4 files = 10 lines
		assert.are.equal(10, #lines)
		assert.are.equal(2, section_map.scope_start)
		assert.are.equal(4, section_map.scope_end)
		assert.are.equal(8, section_map.files_start)
		assert.are.equal(9, section_map.files_end)
	end)

	it("handles empty scope section", function()
		local scope_lines = { "H", "---" }
		local file_lines = { "H", "---", "F1" }

		local lines, _, section_map = sidepanel.build_sidepanel_content(scope_lines, {}, 0, file_lines, {}, 1)

		assert.are.equal(6, #lines)
		-- scope_end < scope_start means no entries
		assert.are.equal(2, section_map.scope_start)
		assert.are.equal(1, section_map.scope_end)
	end)

	it("handles empty files section", function()
		local scope_lines = { "H", "---", "S1" }
		local file_lines = { "H", "---" }

		local lines, _, section_map = sidepanel.build_sidepanel_content(scope_lines, {}, 1, file_lines, {}, 0)

		assert.are.equal(6, #lines)
		assert.are.equal(2, section_map.scope_start)
		assert.are.equal(2, section_map.scope_end)
		-- files_end < files_start means no entries
		assert.are.equal(6, section_map.files_start)
		assert.are.equal(5, section_map.files_end)
	end)
end)

describe("resolve_entry_at_cursor", function()
	-- Scenario: scope has 3 entries, files has 2 entries
	-- Lines (0-indexed):
	-- 0: scope header
	-- 1: scope separator
	-- 2: scope entry 1
	-- 3: scope entry 2
	-- 4: scope entry 3
	-- 5: blank
	-- 6: files header
	-- 7: files separator
	-- 8: file entry 1
	-- 9: file entry 2
	local section_map = {
		scope_start = 2,
		scope_end = 4,
		files_start = 8,
		files_end = 9,
	}

	it("returns scope entry for cursor on scope lines", function()
		local result = sidepanel.resolve_entry_at_cursor(3, section_map) -- 1-based line 3 = 0-indexed 2
		assert.are.same({ type = "scope", index = 1 }, result)

		result = sidepanel.resolve_entry_at_cursor(4, section_map) -- 0-indexed 3
		assert.are.same({ type = "scope", index = 2 }, result)

		result = sidepanel.resolve_entry_at_cursor(5, section_map) -- 0-indexed 4
		assert.are.same({ type = "scope", index = 3 }, result)
	end)

	it("returns file entry for cursor on file lines", function()
		local result = sidepanel.resolve_entry_at_cursor(9, section_map) -- 0-indexed 8
		assert.are.same({ type = "file", index = 1 }, result)

		result = sidepanel.resolve_entry_at_cursor(10, section_map) -- 0-indexed 9
		assert.are.same({ type = "file", index = 2 }, result)
	end)

	it("returns nil for header lines", function()
		assert.is_nil(sidepanel.resolve_entry_at_cursor(1, section_map)) -- scope header
		assert.is_nil(sidepanel.resolve_entry_at_cursor(2, section_map)) -- scope separator
		assert.is_nil(sidepanel.resolve_entry_at_cursor(7, section_map)) -- files header
		assert.is_nil(sidepanel.resolve_entry_at_cursor(8, section_map)) -- files separator
	end)

	it("returns nil for blank separator line", function()
		assert.is_nil(sidepanel.resolve_entry_at_cursor(6, section_map)) -- blank line
	end)

	it("returns nil for line beyond content", function()
		assert.is_nil(sidepanel.resolve_entry_at_cursor(11, section_map))
		assert.is_nil(sidepanel.resolve_entry_at_cursor(100, section_map))
	end)

	it("returns nil for line 0 (out of range)", function()
		assert.is_nil(sidepanel.resolve_entry_at_cursor(0, section_map))
	end)
end)
