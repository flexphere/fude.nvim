local helpers = require("tests.helpers")
local format = require("fude.ui.format")

describe("overview metadata", function()
	after_each(helpers.cleanup)

	local function render(overrides)
		local pr = vim.tbl_extend("force", {
			number = 42,
			title = "Fix bug",
			state = "OPEN",
			author = { login = "alice" },
			baseRefName = "main",
			headRefName = "feat/example",
			url = "https://example.com/pull/42",
			additions = 340,
			deletions = 28,
			changedFiles = 10,
			body = "First paragraph\n\n## Details\nBody",
		}, overrides or {})
		return format.build_overview_left_lines(pr, {}, function(s)
			return s
		end)
	end

	it("places frontmatter, title, then unmodified body before comments", function()
		local result = render()
		assert.are.same({
			"---",
			'state: "OPEN"',
			'author: "@alice"',
			'base: "main"',
			'head: "feat/example"',
			'url: "https://example.com/pull/42"',
			"file_changed: 10",
			'line_changed: "+340 -28"',
			"---",
			"",
			"# #42 Fix bug",
			"",
			"First paragraph",
			"",
			"## Details",
			"Body",
			"",
			"## COMMENTS (0)",
		}, vim.list_slice(result.lines, 1, 18))
		assert.are.equal(13, result.sections.description)
		assert.are.equal(18, result.sections.comments)
		assert.are.same({ line = 6, col_start = 14, col_end = 16, hl = "ReviewFileCount" }, result.hl_ranges[1])
		assert.are.same({ line = 7, col_start = 15, col_end = 19, hl = "DiagnosticOk" }, result.hl_ranges[2])
		assert.are.same({ line = 7, col_start = 20, col_end = 23, hl = "DiagnosticError" }, result.hl_ranges[3])
	end)

	it("quotes YAML special characters and keeps metadata on one line", function()
		local result = render({ baseRefName = 'a: # "quoted" \\ path\n---\r\nnext\tvalue' })
		assert.are.equal('base: "a: # \\"quoted\\" \\\\ path\\n---\\r\\nnext\\tvalue"', result.lines[4])
		assert.are.equal(13, result.sections.description)
	end)

	it("handles null and missing strings without interpreting them as YAML values", function()
		local result = render({ author = vim.NIL, baseRefName = vim.NIL, headRefName = "true", url = vim.NIL })
		assert.are.equal('author: "@unknown"', result.lines[3])
		assert.are.equal('base: ""', result.lines[4])
		assert.are.equal('head: "true"', result.lines[5])
		assert.are.equal('url: ""', result.lines[6])
		assert.are.equal('author: "@unknown"', render({ author = {} }).lines[3])
	end)

	it("normalizes legacy JSON slash escaping without losing literal backslashes", function()
		assert.are.equal('head: "feat\\\\/example"', render({ headRefName = "feat\\/example" }).lines[5])
		local encode = vim.json.encode
		helpers.mock(vim.json, "encode", function(value)
			if value == "feat\\/example" then
				return [["feat\\\/example"]]
			elseif value == "https://example.com/pull/42" then
				return [["https:\/\/example.com\/pull\/42"]]
			end
			return encode(value)
		end)
		local result = render({ headRefName = "feat\\/example" })
		assert.are.equal('head: "feat\\\\/example"', result.lines[5])
		assert.are.equal('url: "https://example.com/pull/42"', result.lines[6])
		assert.are.equal("feat\\/example", vim.json.decode(result.lines[5]:sub(7)))
	end)

	it("retains zero counts", function()
		local result = render({ additions = 0, deletions = 0, changedFiles = 0 })
		assert.are.equal("file_changed: 0", result.lines[7])
		assert.are.equal('line_changed: "+0 -0"', result.lines[8])
	end)

	it("omits unknown or invalid counts rather than displaying zero", function()
		for _, value in ipairs({ vim.NIL, "12", -1, 1.5, math.huge, 0 / 0 }) do
			local result = render({ additions = value, deletions = value, changedFiles = value })
			assert.are.equal("---", result.lines[7])
			assert.are.equal(11, result.sections.description)
			assert.are.equal(1, #result.hl_ranges) -- footer only
		end
		local result = format.build_overview_left_lines({}, {}, function(s)
			return s
		end)
		assert.are.equal("---", result.lines[7])
	end)

	it("omits only the unavailable count or incomplete pair", function()
		for _, key in ipairs({ "additions", "deletions" }) do
			local result = render({ [key] = vim.NIL })
			assert.are.equal("file_changed: 10", result.lines[7])
			assert.are.equal("---", result.lines[8])
		end
		local result = render({ changedFiles = vim.NIL })
		assert.are.equal('line_changed: "+340 -28"', result.lines[7])
		assert.are.equal(6, result.hl_ranges[1].line)
		assert.are.equal(6, result.hl_ranges[2].line)
	end)

	it("requests PR-wide counts from GitHub", function()
		local gh = require("fude.gh")
		local captured
		helpers.mock(gh, "run_json", function(args, cb)
			captured = args
			cb(nil, { additions = 340, deletions = 28, changedFiles = 10 })
		end)
		local response
		gh.get_pr_overview(function(err, data)
			assert.is_nil(err)
			response = data
		end)
		assert.are.same({ "pr", "view", "--json" }, vim.list_slice(captured, 1, 3))
		local fields = vim.split(captured[4], ",")
		assert.is_true(vim.tbl_contains(fields, "additions"))
		assert.is_true(vim.tbl_contains(fields, "deletions"))
		assert.is_true(vim.tbl_contains(fields, "changedFiles"))
		assert.are.same({ additions = 340, deletions = 28, changedFiles = 10 }, response)
	end)

	it("connects generated positions to marks, navigation, and highlights in the float", function()
		local config = require("fude.config")
		config.setup({})
		local pr = { number = 1, title = "Title", body = "Body", additions = 70, deletions = 6, changedFiles = 10 }
		local comments = { { user = { login = "alice" }, created_at = "2026-01-01", body = "Comment" } }
		local expected = format.build_overview_left_lines(pr, comments, function(s)
			return s
		end)
		require("fude.ui").show_overview_float(pr, comments, {})
		local buf = vim.api.nvim_get_current_buf()
		local win = vim.api.nvim_get_current_win()
		assert.are.equal("markdown", vim.bo[buf].filetype)
		assert.are.same({ expected.sections.description, 0 }, vim.api.nvim_buf_get_mark(buf, "d"))
		assert.are.same({ expected.sections.comments, 0 }, vim.api.nvim_buf_get_mark(buf, "c"))
		local maps = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			maps[map.lhs] = map.callback
		end
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		maps["]s"]()
		assert.are.equal(expected.sections.description, vim.api.nvim_win_get_cursor(win)[1])
		maps["]s"]()
		assert.are.equal(expected.sections.comments, vim.api.nvim_win_get_cursor(win)[1])
		maps["[s"]()
		assert.are.equal(expected.sections.description, vim.api.nvim_win_get_cursor(win)[1])
		maps[config.opts.keymaps.next_comment]()
		assert.are.equal(expected.comment_positions[1], vim.api.nvim_win_get_cursor(win)[1])
		local colors = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, config.state.ns_id, 0, -1, { details = true })) do
			colors[mark[4].hl_group] = { mark[2], mark[3], mark[4].end_col }
		end
		assert.are.same({ 6, 14, 16 }, colors.ReviewFileCount)
		assert.are.same({ 7, 15, 18 }, colors.DiagnosticOk)
		assert.are.same({ 7, 19, 21 }, colors.DiagnosticError)
		assert.are.same({ 7, 21, 22 }, colors.Normal)
		maps.q()
		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)
end)
