local sidepanel = require("fude.ui.sidepanel")
local config = require("fude.config")

describe("file row layout", function()
	local tree = require("fude.ui.sidepanel.tree")
	local function render(mode, entries, width, current, opts)
		if mode == "flat" then
			return sidepanel.format_files_section(entries, width, nil, 0, current, opts)
		end
		local viewed = {}
		for _, entry in ipairs(entries) do
			if entry.viewed_icon and entry.viewed_icon ~= " " then
				viewed[entry.path] = "VIEWED"
			end
		end
		return sidepanel.format_files_section_tree(
			tree.flatten_tree(tree.build_tree(entries), viewed),
			#entries,
			width,
			0,
			current,
			opts
		)
	end
	local function find_line(lines, name)
		for index, line in ipairs(lines) do
			if line:find(name, 1, true) then
				return line, index
			end
		end
		error("Missing row: " .. name)
	end
	local function column(line, value)
		return vim.fn.strdisplaywidth(line:sub(1, assert(line:find(value, 1, true)) - 1))
	end

	for _, mode in ipairs({ "flat", "tree" }) do
		describe(mode, function()
			it("right-aligns diff counts after the name, including zeros and large counts", function()
				local entries = {
					{ path = "src/one.lua", additions = 12345, deletions = 678, status_icon = "~", viewed_icon = "✓" },
					{ path = "two.lua", additions = 1, deletions = 0, status_icon = "+" },
				}
				local lines = render(mode, entries, 48, "src/one.lua")
				local one = find_line(lines, "one.lua")
				local two = find_line(lines, "two.lua")
				assert.are.equal(48, vim.fn.strdisplaywidth(one))
				assert.are.equal(48, vim.fn.strdisplaywidth(two))
				assert.truthy(one:match("one%.lua%s+%+12345%s+%-678$"))
				assert.truthy(two:match("two%.lua%s+%+1%s+%-0$"))
				-- The ends of the additions columns agree despite different digit counts.
				assert.are.equal(column(one, "+12345") + 6, column(two, "+1") + 2)
			end)

			it("keeps current, viewed and status columns fixed across depths and wide signs", function()
				local entries = {
					{ path = "root.lua", status_icon = "~", viewed_icon = "完" },
					{ path = "deep/nested/leaf.lua", status_icon = "~", viewed_icon = "完" },
					{ path = "deep/other.lua", status_icon = "~", viewed_icon = " " },
				}
				local lines = render(mode, entries, 70, "deep/nested/leaf.lua", { viewed_icon = "完" })
				local root = find_line(lines, "root.lua")
				local leaf = find_line(lines, "leaf.lua")
				local other = find_line(lines, "other.lua")
				assert.are.equal(2, column(root, "完"))
				assert.are.equal(2, column(leaf, "完"))
				assert.are.equal(0, column(leaf, "▶"))
				assert.are.equal(5, column(root, "~"))
				assert.are.equal(5, column(leaf, "~"))
				assert.are.equal(5, column(other, "~"))
				if mode == "tree" then
					local directory = find_line(lines, "nested")
					assert.is_falsy(directory:find("完", 1, true))
					assert.is_falsy(find_line(lines, "deep"):find("完", 1, true))
				end
			end)

			it("aligns names with different icon widths and highlights the actual UTF-8 bytes", function()
				local entries = {
					{ path = "日本語.lua", file_icon = "界", file_icon_hl = "TestIcon", additions = 7, deletions = 2 },
					{ path = "other.lua", file_icon = "L", file_icon_hl = "TestIcon", additions = 0, deletions = 0 },
				}
				local lines, hls = render(mode, entries, 40, "日本語.lua")
				local japanese, line_index = find_line(lines, "日本語.lua")
				local other = find_line(lines, "other.lua")
				assert.are.equal(column(japanese, "日本語.lua"), column(other, "other.lua"))
				assert.are.equal(40, vim.fn.strdisplaywidth(japanese))
				local selected = {}
				for _, hl in ipairs(hls) do
					if hl[1] == line_index - 1 then
						selected[hl[4]] = japanese:sub(hl[2] + 1, hl[3])
					end
				end
				assert.are.equal("▶", selected.DiagnosticInfo)
				assert.are.equal("界", selected.TestIcon)
				assert.are.equal("+7", selected.DiffAdd)
				assert.are.equal("-2", selected.DiffDelete)
			end)

			it("truncates Japanese names without breaking UTF-8 or overwriting stats", function()
				local lines = render(mode, {
					{ path = "日本語のとても長い名前.lua", additions = 5, deletions = 0 },
				}, 20)
				local line = lines[3]
				assert.are.equal(20, vim.fn.strdisplaywidth(line))
				assert.truthy(line:find(mode == "tree" and "日本…" or "日本語…", 1, true))
				assert.truthy(line:match("%+5 %-0$"))
			end)

			it("keeps combining characters with their base when truncating", function()
				local lines = render(mode, { { path = "ééééééééé.lua" } }, 20)
				assert.truthy(lines[3]:find(mode == "tree" and "ééééé…" or "ééééééé…", 1, true))
				assert.are.equal(20, vim.fn.strdisplaywidth(lines[3]))
			end)

			it("keeps deep rows within very narrow widths and never emits partial counts", function()
				local entries = {
					{
						path = "a/b/c/d/e/f/leaf.lua",
						viewed_icon = "✓",
						file_icon = "界",
						additions = 123456,
						deletions = 987654,
					},
				}
				for _, width in ipairs({ 0, 1, 7, 20, 40 }) do
					local lines, hls = render(mode, entries, width, entries[1].path)
					for i = 3, #lines do
						assert.is_true(vim.fn.strdisplaywidth(lines[i]) <= width)
						assert.is_falsy(lines[i]:match("%+[0-9]+…"))
					end
					for _, hl in ipairs(hls) do
						if hl[1] >= 2 then
							assert.is_true(hl[2] >= 0 and hl[3] > hl[2] and hl[3] <= #lines[hl[1] + 1])
						end
					end
					if width == 20 then
						local row = lines[#lines]
						assert.truthy(row:find(mode == "tree" and "lea…" or "a/b/", 1, true))
						assert.is_falsy(row:find("+123456", 1, true))
					end
				end
			end)

			it("does not mutate file entries while formatting", function()
				local entries = { { path = "folder/file.lua", viewed_icon = "✓", additions = 1 } }
				local original = vim.deepcopy(entries)
				render(mode, entries, 20, entries[1].path)
				assert.are.same(original, entries)
			end)
		end)
	end

	it("renders a directory icon without a current-file marker or diff counts", function()
		local lines, hls = render("tree", {
			{ path = "src/one.lua", viewed_icon = "✓", additions = 1 },
		}, 40, "src/one.lua", { directory_icon = "D" })
		assert.are.equal("      ▾ D src", lines[3])
		local directory_hls = {}
		for _, hl in ipairs(hls) do
			if hl[1] == 2 and hl[4] == "Directory" then
				table.insert(directory_hls, lines[3]:sub(hl[2] + 1, hl[3]))
			end
		end
		assert.are.same({ "▾", "D", "src" }, directory_hls)
	end)
end)

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

	it("creates header with viewed and total file count", function()
		local lines = sidepanel.format_files_section(file_entries, 40, nil, 1)
		assert.truthy(lines[1]:find("Files %(Reviewed: 1/2%)"))
	end)

	it("creates separator as second line", function()
		local lines = sidepanel.format_files_section(file_entries, 40, nil, 1)
		assert.truthy(lines[2]:find("─"))
	end)

	it("creates one line per file entry after header", function()
		local lines, _, count = sidepanel.format_files_section(file_entries, 60, nil, 1)
		assert.are.equal(2, count)
		assert.are.equal(4, #lines) -- header + separator + 2 entries
	end)

	it("shows viewed icon", function()
		local lines = sidepanel.format_files_section(file_entries, 60, nil, 1)
		assert.truthy(lines[3]:find("✓"))
	end)

	it("shows status icon", function()
		local lines = sidepanel.format_files_section(file_entries, 60, nil, 1)
		assert.truthy(lines[3]:find("~"))
		assert.truthy(lines[4]:find("%+"))
	end)

	it("shows additions and deletions", function()
		local lines = sidepanel.format_files_section(file_entries, 60, nil, 1)
		assert.truthy(lines[3]:find("+10"))
		assert.truthy(lines[3]:find("-5"))
	end)

	it("shows file path", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("applies format_path_fn", function()
		local fn = function(p)
			return p:match("[^/]+$")
		end
		local lines = sidepanel.format_files_section(file_entries, 80, fn, 1)
		assert.truthy(lines[3]:find("scope.lua"))
		assert.is_falsy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("uses identity when format_path_fn is nil", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("falls back to original path when format_path_fn returns nil", function()
		local fn = function()
			return nil
		end
		local lines = sidepanel.format_files_section(file_entries, 80, fn, 1)
		assert.truthy(lines[3]:find("lua/fude/scope.lua"))
	end)

	it("returns highlights for each file entry", function()
		local _, file_hls = sidepanel.format_files_section(file_entries, 60, nil, 1)
		-- header (1) + 4 highlights per file (viewed, status, adds, dels) × 2 files = 9
		assert.are.equal(9, #file_hls)
	end)

	it("handles empty entries", function()
		local lines, _, count = sidepanel.format_files_section({}, 40, nil, 0)
		assert.are.equal(2, #lines) -- header + separator
		assert.are.equal(0, count)
		assert.truthy(lines[1]:find("Files %(Reviewed: 0/0%)"))
	end)

	it("shows all-viewed count in header", function()
		local lines = sidepanel.format_files_section(file_entries, 40, nil, 2)
		assert.truthy(lines[1]:find("Files %(Reviewed: 2/2%)"))
	end)

	it("shows current file marker for matching path", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1, "lua/fude/scope.lua")
		assert.truthy(lines[3]:find("▶"))
	end)

	it("does not show marker for non-current files", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1, "lua/fude/scope.lua")
		assert.is_falsy(lines[4]:find("▶"))
	end)

	it("returns DiagnosticInfo highlight for current file", function()
		local _, hls = sidepanel.format_files_section(file_entries, 60, nil, 1, "lua/fude/scope.lua")
		local found = false
		for _, hl in ipairs(hls) do
			if hl[4] == "DiagnosticInfo" then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("no marker when current_path is nil", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1, nil)
		assert.is_falsy(lines[3]:find("▶"))
		assert.is_falsy(lines[4]:find("▶"))
	end)

	it("no marker when current_path does not match any file", function()
		local lines = sidepanel.format_files_section(file_entries, 80, nil, 1, "lua/fude/nonexistent.lua")
		assert.is_falsy(lines[3]:find("▶"))
		assert.is_falsy(lines[4]:find("▶"))
	end)
end)

describe("format_files_section_tree", function()
	it("does not mark an empty collapsed directory as done or undone", function()
		local lines = sidepanel.format_files_section_tree({
			{ type = "directory", name = "empty", depth = 0, collapsed = true, total_files = 0, viewed_files = 0 },
		}, 0, 40, 0)
		assert.are.equal("      ▸ empty", lines[3])
	end)

	local tree = require("fude.ui.sidepanel.tree")

	after_each(function()
		config.setup({})
	end)

	local function make_file_entry(path, opts)
		opts = opts or {}
		return {
			path = path,
			additions = opts.additions or 0,
			deletions = opts.deletions or 0,
			status_icon = opts.status_icon or "~",
			status_hl = "DiffChange",
			viewed_icon = opts.viewed_icon or " ",
			viewed_hl = "Comment",
		}
	end

	it("renders header with viewed and total file count", function()
		local file_entries = {
			make_file_entry("a/b.md"),
			make_file_entry("a/c.md"),
			make_file_entry("d.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0)
		assert.are.equal(" Files (Reviewed: 0/3)", lines[1])
	end)

	it("renders directories as indented labels", function()
		local file_entries = { make_file_entry("a/b/c.md") }
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, 1, 40, 0)
		assert.are.equal("      ▾ a", lines[3])
		assert.are.equal("        ▾ b", lines[4])
		assert.is_truthy(lines[5]:find("    "))
		assert.truthy(lines[5]:find("c.md"))
	end)

	it("does not render directory aggregate totals", function()
		local file_entries = {
			make_file_entry("a/b.md", { additions = 7, deletions = 2 }),
			make_file_entry("a/c.md", { additions = 3, deletions = 1 }),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0)

		assert.are.equal("      ▾ a", lines[3])
	end)

	it("omits even a configured viewed sign for fully viewed directories", function()
		config.setup({ signs = { viewed = "●" } })
		local file_entries = {
			make_file_entry("a/b.md"),
			make_file_entry("a/c.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, { ["a/b.md"] = "VIEWED", ["a/c.md"] = "VIEWED" })
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 2, nil, {
			viewed_icon = config.opts.signs.viewed,
		})

		assert.are.equal("      ▾ a", lines[3])
	end)

	it("keeps flat row diff columns on file entries", function()
		local file_entries = { make_file_entry("a/foo.md", { additions = 7, deletions = 2 }) }
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, 1, 40, 0)
		assert.truthy(lines[4]:find("~"))
		assert.truthy(lines[4]:find("%+7"))
		assert.truthy(lines[4]:find("%-2"))
		assert.truthy(lines[4]:find("foo.md"))
	end)

	it("returns rendered tree-entry count", function()
		local file_entries = {
			make_file_entry("a/b.md"),
			make_file_entry("c.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local _, _, count = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0)
		assert.are.equal(3, count)
	end)

	it("shows viewed count in header", function()
		local file_entries = {
			make_file_entry("a/b.md"),
			make_file_entry("a/c.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 1)
		assert.are.equal(" Files (Reviewed: 1/2)", lines[1])
	end)

	it("shows current file marker for matching file in tree", function()
		local file_entries = {
			make_file_entry("a/b.md"),
			make_file_entry("a/c.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0, "a/b.md")
		local found_marker = false
		local found_no_marker = false
		for i = 3, #lines do
			if lines[i]:find("b.md") and lines[i]:find("▶") then
				found_marker = true
			end
			if lines[i]:find("c.md") and not lines[i]:find("▶") then
				found_no_marker = true
			end
		end
		assert.is_true(found_marker)
		assert.is_true(found_no_marker)
	end)

	it("does not show marker on directory entries", function()
		local file_entries = {
			make_file_entry("a/b.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0, "a/b.md")
		-- Line 3 is the directory "a", should not have ▶
		assert.is_falsy(lines[3]:find("▶"))
	end)

	it("no marker when current_path is nil", function()
		local file_entries = {
			make_file_entry("a/b.md"),
		}
		local root = tree.build_tree(file_entries)
		local entries = tree.flatten_tree(root, {})
		local lines = sidepanel.format_files_section_tree(entries, #file_entries, 40, 0, nil)
		for i = 3, #lines do
			assert.is_falsy(lines[i]:find("▶"))
		end
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

describe("find_first_file_entry", function()
	it("returns the first flat entry", function()
		local file_entries = {
			{ path = "a.lua", filename = "/repo/a.lua" },
			{ path = "b.lua", filename = "/repo/b.lua" },
		}
		local entry = sidepanel.find_first_file_entry(file_entries, nil)
		assert.are.equal("/repo/a.lua", entry.filename)
	end)

	it("returns nil for empty flat entries", function()
		assert.is_nil(sidepanel.find_first_file_entry({}, nil))
	end)

	it("returns nil when flat entries are nil", function()
		assert.is_nil(sidepanel.find_first_file_entry(nil, nil))
	end)

	it("skips a removed file at the top of the flat list", function()
		local file_entries = {
			{ path = "gone.lua", filename = "/repo/gone.lua", status = "removed" },
			{ path = "b.lua", filename = "/repo/b.lua", status = "modified" },
		}
		local entry = sidepanel.find_first_file_entry(file_entries, nil)
		assert.are.equal("/repo/b.lua", entry.filename)
	end)

	it("returns nil when every flat entry is removed", function()
		local file_entries = {
			{ path = "gone.lua", filename = "/repo/gone.lua", status = "removed" },
		}
		assert.is_nil(sidepanel.find_first_file_entry(file_entries, nil))
	end)

	it("skips leading directory rows in tree mode", function()
		local tree_entries = {
			{ type = "directory", path = "lua" },
			{ type = "directory", path = "lua/fude" },
			{ type = "file", path = "lua/fude/a.lua", file = { path = "lua/fude/a.lua", filename = "/repo/lua/fude/a.lua" } },
			{ type = "file", path = "lua/fude/b.lua", file = { path = "lua/fude/b.lua", filename = "/repo/lua/fude/b.lua" } },
		}
		local entry = sidepanel.find_first_file_entry({}, tree_entries)
		assert.are.equal("/repo/lua/fude/a.lua", entry.filename)
	end)

	it("skips a removed file at the top of the tree", function()
		local tree_entries = {
			{
				type = "file",
				path = "gone.lua",
				file = { path = "gone.lua", filename = "/repo/gone.lua", status = "removed" },
			},
			{ type = "file", path = "b.lua", file = { path = "b.lua", filename = "/repo/b.lua", status = "modified" } },
		}
		local entry = sidepanel.find_first_file_entry({}, tree_entries)
		assert.are.equal("/repo/b.lua", entry.filename)
	end)

	it("returns nil when tree mode has only directory rows", function()
		local tree_entries = {
			{ type = "directory", path = "lua" },
		}
		assert.is_nil(sidepanel.find_first_file_entry({}, tree_entries))
	end)

	it("parse_first_hunk_line reads the first hunk of a GitHub-style patch", function()
		local patch = "@@ -10,3 +12,4 @@ local x\n line\n+new\n line\n@@ -30,2 +33,2 @@\n line"
		assert.are.equal(12, sidepanel.parse_first_hunk_line(patch))
	end)

	it("parse_first_hunk_line skips git-diff headers before the first hunk", function()
		local patch = "diff --git a/f.lua b/f.lua\nindex 111..222 100644\n--- a/f.lua\n+++ b/f.lua\n@@ -1 +5,2 @@\n+x"
		assert.are.equal(5, sidepanel.parse_first_hunk_line(patch))
	end)

	it("parse_first_hunk_line returns 0 for a leading pure-deletion hunk", function()
		assert.are.equal(0, sidepanel.parse_first_hunk_line("@@ -1,3 +0,0 @@\n-a\n-b\n-c"))
	end)

	it("parse_first_hunk_line ignores hunk-like text in diff content lines", function()
		local patch = " @@ -1 +9 @@ inside content\n+@@ -1 +9 @@ added line"
		assert.is_nil(sidepanel.parse_first_hunk_line(patch))
	end)

	it("parse_first_hunk_line returns nil for empty or non-string patches", function()
		assert.is_nil(sidepanel.parse_first_hunk_line(""))
		assert.is_nil(sidepanel.parse_first_hunk_line(nil))
		assert.is_nil(sidepanel.parse_first_hunk_line("no hunks here"))
	end)

	it("prefers tree entries over flat entries when both are given", function()
		local file_entries = { { path = "flat.lua", filename = "/repo/flat.lua" } }
		local tree_entries = {
			{ type = "file", path = "tree.lua", file = { path = "tree.lua", filename = "/repo/tree.lua" } },
		}
		local entry = sidepanel.find_first_file_entry(file_entries, tree_entries)
		assert.are.equal("/repo/tree.lua", entry.filename)
	end)
end)

describe("selectable line navigation", function()
	-- Same layout as the resolve_entry_at_cursor scenario:
	-- 3 scope entries (1-based lines 3-5), 2 file entries (lines 9-10),
	-- everything else is header/separator/blank.
	local section_map = {
		scope_start = 2,
		scope_end = 4,
		files_start = 8,
		files_end = 9,
	}

	describe("build_selectable_lines", function()
		it("lists scope and file entry lines only (flat mode)", function()
			assert.are.same({ 3, 4, 5, 9, 10 }, sidepanel.build_selectable_lines(section_map))
		end)

		it("handles empty sections", function()
			local empty_map = { scope_start = 2, scope_end = 1, files_start = 5, files_end = 4 }
			assert.are.same({}, sidepanel.build_selectable_lines(empty_map))
		end)
	end)

	describe("find_adjacent_selectable_line", function()
		local lines = { 3, 4, 5, 9, 10 }

		it("jumps from a header line to the first entry below", function()
			assert.are.equal(3, sidepanel.find_adjacent_selectable_line(1, lines, 1))
		end)

		it("moves to the next entry within a section", function()
			assert.are.equal(4, sidepanel.find_adjacent_selectable_line(3, lines, 1))
		end)

		it("skips the section boundary going down", function()
			assert.are.equal(9, sidepanel.find_adjacent_selectable_line(5, lines, 1))
		end)

		it("skips the section boundary going up", function()
			assert.are.equal(5, sidepanel.find_adjacent_selectable_line(9, lines, -1))
		end)

		it("returns nil at the bottom edge", function()
			assert.is_nil(sidepanel.find_adjacent_selectable_line(10, lines, 1))
		end)

		it("returns nil at the top edge", function()
			assert.is_nil(sidepanel.find_adjacent_selectable_line(3, lines, -1))
		end)

		it("returns nil when there are no selectable lines", function()
			assert.is_nil(sidepanel.find_adjacent_selectable_line(1, {}, 1))
		end)

		it("moves count entries in one call", function()
			assert.are.equal(4, sidepanel.find_adjacent_selectable_line(1, lines, 1, 2))
			assert.are.equal(5, sidepanel.find_adjacent_selectable_line(10, lines, -1, 2))
		end)

		it("clamps a count past the edge to the last entry that way", function()
			assert.are.equal(10, sidepanel.find_adjacent_selectable_line(1, lines, 1, 9999))
			assert.are.equal(3, sidepanel.find_adjacent_selectable_line(10, lines, -1, 9999))
		end)
	end)
end)
