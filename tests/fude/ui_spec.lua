local ui = require("fude.ui")

describe("calculate_float_dimensions", function()
	it("calculates centered dimensions at 50%", function()
		local dim = ui.calculate_float_dimensions(200, 50, 50, 50)
		assert.are.equal(100, dim.width)
		assert.are.equal(25, dim.height)
		assert.are.equal(12, dim.row)
		assert.are.equal(50, dim.col)
	end)

	it("calculates full screen at 100%", function()
		local dim = ui.calculate_float_dimensions(200, 50, 100, 100)
		assert.are.equal(200, dim.width)
		assert.are.equal(50, dim.height)
		assert.are.equal(0, dim.row)
		assert.are.equal(0, dim.col)
	end)

	it("floors fractional values", function()
		local dim = ui.calculate_float_dimensions(101, 51, 50, 50)
		assert.are.equal(50, dim.width)
		assert.are.equal(25, dim.height)
		assert.are.equal(13, dim.row)
		assert.are.equal(25, dim.col)
	end)

	it("handles small percentages", function()
		local dim = ui.calculate_float_dimensions(200, 50, 10, 10)
		assert.are.equal(20, dim.width)
		assert.are.equal(5, dim.height)
		assert.are.equal(22, dim.row)
		assert.are.equal(90, dim.col)
	end)
end)

describe("format_comments_for_display", function()
	local identity = function(s)
		return s or ""
	end

	it("formats a single comment", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "looks good" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal("@alice  2024-01-01", result.lines[1])
		assert.are.equal("looks good", result.lines[2])
		assert.are.equal(1, #result.hl_ranges)
		assert.are.equal(0, result.hl_ranges[1].line)
	end)

	it("adds separator between multiple comments", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		-- alice header, body, empty, separator, empty, bob header, body
		assert.are.equal(7, #result.lines)
		assert.are.equal(string.rep("-", 40), result.lines[4])
		assert.are.equal(2, #result.hl_ranges)
	end)

	it("uses 'unknown' for missing user", function()
		local comments = {
			{ user = nil, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.truthy(result.lines[1]:find("unknown"))
	end)

	it("handles nil body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = nil },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal(2, #result.lines) -- header + empty body line
	end)

	it("splits multiline body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\nline2\nline3" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal("line1", result.lines[2])
		assert.are.equal("line2", result.lines[3])
		assert.are.equal("line3", result.lines[4])
	end)

	it("strips CRLF from body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\r\nline2\r\nline3" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal("line1", result.lines[2])
		assert.are.equal("line2", result.lines[3])
		assert.are.equal("line3", result.lines[4])
		for _, line in ipairs(result.lines) do
			assert.is_nil(line:find("\r"), "Line should not contain CR")
		end
	end)

	it("applies format_date_fn", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01T00:00:00Z", body = "test" },
		}
		local result = ui.format_comments_for_display(comments, function()
			return "FORMATTED"
		end)
		assert.truthy(result.lines[1]:find("FORMATTED"))
	end)

	it("returns comment_ranges for single comment", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "hello" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal(1, #result.comment_ranges)
		assert.are.equal(0, result.comment_ranges[1].start_line)
		assert.are.equal(1, result.comment_ranges[1].end_line)
		assert.are.equal(1, result.comment_ranges[1].index)
	end)

	it("returns comment_ranges for multiple comments", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal(2, #result.comment_ranges)
		-- First comment: header (0) + body (1)
		assert.are.equal(0, result.comment_ranges[1].start_line)
		assert.are.equal(1, result.comment_ranges[1].end_line)
		assert.are.equal(1, result.comment_ranges[1].index)
		-- Second comment: after separator (empty + --- + empty = lines 2,3,4), header (5) + body (6)
		assert.are.equal(5, result.comment_ranges[2].start_line)
		assert.are.equal(6, result.comment_ranges[2].end_line)
		assert.are.equal(2, result.comment_ranges[2].index)
	end)

	it("returns comment_ranges for multiline body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\nline2\nline3" },
		}
		local result = ui.format_comments_for_display(comments, identity)
		assert.are.equal(1, #result.comment_ranges)
		assert.are.equal(0, result.comment_ranges[1].start_line)
		assert.are.equal(3, result.comment_ranges[1].end_line) -- header + 3 body lines
	end)
end)

describe("format_check_status", function()
	it("returns check mark for SUCCESS", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "SUCCESS" })
		assert.are.equal("✓", symbol)
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns x for FAILURE", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "FAILURE" })
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns x for TIMED_OUT", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "TIMED_OUT" })
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns x for STARTUP_FAILURE", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "STARTUP_FAILURE" })
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns dash for NEUTRAL", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "NEUTRAL" })
		assert.are.equal("-", symbol)
		assert.are.equal("Comment", hl)
	end)

	it("returns dash for SKIPPED", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "SKIPPED" })
		assert.are.equal("-", symbol)
		assert.are.equal("Comment", hl)
	end)

	it("returns bang for CANCELLED", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "CANCELLED" })
		assert.are.equal("!", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns bang for ACTION_REQUIRED", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "ACTION_REQUIRED" })
		assert.are.equal("!", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns circle for IN_PROGRESS", function()
		local symbol, hl = ui.format_check_status({ status = "IN_PROGRESS" })
		assert.are.equal("●", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns circle for QUEUED", function()
		local symbol, hl = ui.format_check_status({ status = "QUEUED" })
		assert.are.equal("●", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns circle for PENDING", function()
		local symbol, hl = ui.format_check_status({ status = "PENDING" })
		assert.are.equal("●", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns question mark for unknown conclusion", function()
		local symbol, hl = ui.format_check_status({ status = "COMPLETED", conclusion = "SOMETHING_NEW" })
		assert.are.equal("?", symbol)
		assert.are.equal("Comment", hl)
	end)

	-- StatusContext (commit status API) tests
	it("returns check mark for StatusContext SUCCESS", function()
		local symbol, hl = ui.format_check_status({ context = "ci/check", state = "SUCCESS" })
		assert.are.equal("✓", symbol)
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns x for StatusContext FAILURE", function()
		local symbol, hl = ui.format_check_status({ context = "ci/check", state = "FAILURE" })
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns x for StatusContext ERROR", function()
		local symbol, hl = ui.format_check_status({ context = "ci/check", state = "ERROR" })
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns circle for StatusContext PENDING", function()
		local symbol, hl = ui.format_check_status({ context = "ci/check", state = "PENDING" })
		assert.are.equal("●", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)
end)

describe("normalize_check", function()
	it("passes through CheckRun status and conclusion", function()
		local status, conclusion = ui.normalize_check({ status = "COMPLETED", conclusion = "SUCCESS" })
		assert.are.equal("COMPLETED", status)
		assert.are.equal("SUCCESS", conclusion)
	end)

	it("normalizes StatusContext SUCCESS", function()
		local status, conclusion = ui.normalize_check({ context = "ci/check", state = "SUCCESS" })
		assert.are.equal("COMPLETED", status)
		assert.are.equal("SUCCESS", conclusion)
	end)

	it("normalizes StatusContext FAILURE", function()
		local status, conclusion = ui.normalize_check({ context = "ci/check", state = "FAILURE" })
		assert.are.equal("COMPLETED", status)
		assert.are.equal("FAILURE", conclusion)
	end)

	it("normalizes StatusContext ERROR to FAILURE", function()
		local status, conclusion = ui.normalize_check({ context = "ci/check", state = "ERROR" })
		assert.are.equal("COMPLETED", status)
		assert.are.equal("FAILURE", conclusion)
	end)

	it("normalizes StatusContext PENDING", function()
		local status, conclusion = ui.normalize_check({ context = "ci/check", state = "PENDING" })
		assert.are.equal("PENDING", status)
		assert.are.equal("", conclusion)
	end)

	it("normalizes StatusContext EXPECTED to PENDING", function()
		local status, conclusion = ui.normalize_check({ context = "ci/check", state = "EXPECTED" })
		assert.are.equal("PENDING", status)
		assert.are.equal("", conclusion)
	end)

	it("returns empty strings for unknown object", function()
		local status, conclusion = ui.normalize_check({})
		assert.are.equal("", status)
		assert.are.equal("", conclusion)
	end)

	it("prefers status/conclusion over state when both present", function()
		local status, conclusion = ui.normalize_check({ status = "COMPLETED", conclusion = "SUCCESS", state = "FAILURE" })
		assert.are.equal("COMPLETED", status)
		assert.are.equal("SUCCESS", conclusion)
	end)
end)

describe("deduplicate_checks", function()
	it("keeps latest entry for duplicate names", function()
		local checks = {
			{ name = "lint", status = "COMPLETED", conclusion = "FAILURE" },
			{ name = "test", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
		}
		local result = ui.deduplicate_checks(checks)
		assert.are.equal(2, #result)
		-- lint should be the latest (SUCCESS), test stays
		local lint_found = false
		for _, check in ipairs(result) do
			if check.name == "lint" then
				assert.are.equal("SUCCESS", check.conclusion)
				lint_found = true
			end
		end
		assert.is_true(lint_found)
	end)

	it("preserves order of first appearance", function()
		local checks = {
			{ name = "build", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "lint", status = "COMPLETED", conclusion = "FAILURE" },
			{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
		}
		local result = ui.deduplicate_checks(checks)
		assert.are.equal("build", result[1].name)
		assert.are.equal("lint", result[2].name)
	end)

	it("returns empty table for empty input", function()
		assert.are.equal(0, #ui.deduplicate_checks({}))
	end)

	it("handles checks with no duplicates", function()
		local checks = {
			{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "test", status = "COMPLETED", conclusion = "SUCCESS" },
		}
		local result = ui.deduplicate_checks(checks)
		assert.are.equal(2, #result)
	end)

	it("uses context field for StatusContext type", function()
		local checks = {
			{ context = "ci/check", status = "COMPLETED", conclusion = "FAILURE" },
			{ context = "ci/check", status = "COMPLETED", conclusion = "SUCCESS" },
		}
		local result = ui.deduplicate_checks(checks)
		assert.are.equal(1, #result)
		assert.are.equal("SUCCESS", result[1].conclusion)
	end)
end)

describe("build_checks_summary", function()
	it("returns correct count for all success", function()
		local checks = {
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "lint" },
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "test" },
		}
		assert.are.equal("2/2 passed", ui.build_checks_summary(checks))
	end)

	it("returns correct count for mixed results", function()
		local checks = {
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "lint" },
			{ status = "COMPLETED", conclusion = "FAILURE", name = "test" },
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "build" },
		}
		assert.are.equal("2/3 passed", ui.build_checks_summary(checks))
	end)

	it("returns correct count for all failures", function()
		local checks = {
			{ status = "COMPLETED", conclusion = "FAILURE", name = "lint" },
		}
		assert.are.equal("0/1 passed", ui.build_checks_summary(checks))
	end)

	it("counts NEUTRAL and SKIPPED as passed", function()
		local checks = {
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "lint" },
			{ status = "COMPLETED", conclusion = "SKIPPED", name = "optional" },
			{ status = "COMPLETED", conclusion = "NEUTRAL", name = "info" },
		}
		assert.are.equal("3/3 passed", ui.build_checks_summary(checks))
	end)

	it("handles in-progress checks", function()
		local checks = {
			{ status = "COMPLETED", conclusion = "SUCCESS", name = "lint" },
			{ status = "IN_PROGRESS", name = "test" },
		}
		assert.are.equal("1/2 passed", ui.build_checks_summary(checks))
	end)

	it("returns empty string for empty list", function()
		assert.are.equal("", ui.build_checks_summary({}))
	end)

	it("counts StatusContext SUCCESS as passed", function()
		local checks = {
			{ context = "ci/check", state = "SUCCESS" },
			{ context = "ci/build", state = "FAILURE" },
		}
		assert.are.equal("1/2 passed", ui.build_checks_summary(checks))
	end)
end)

describe("sort_checks", function()
	it("sorts failures before successes", function()
		local checks = {
			{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "test", status = "COMPLETED", conclusion = "FAILURE" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("test", result[1].name)
		assert.are.equal("lint", result[2].name)
	end)

	it("sorts by priority: failure > cancelled > skipped > in_progress > success", function()
		local checks = {
			{ name = "e-success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "d-pending", status = "IN_PROGRESS" },
			{ name = "c-skipped", status = "COMPLETED", conclusion = "SKIPPED" },
			{ name = "b-cancelled", status = "COMPLETED", conclusion = "CANCELLED" },
			{ name = "a-failure", status = "COMPLETED", conclusion = "FAILURE" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("a-failure", result[1].name)
		assert.are.equal("b-cancelled", result[2].name)
		assert.are.equal("c-skipped", result[3].name)
		assert.are.equal("d-pending", result[4].name)
		assert.are.equal("e-success", result[5].name)
	end)

	it("sorts alphabetically within the same priority", function()
		local checks = {
			{ name = "zebra", status = "COMPLETED", conclusion = "FAILURE" },
			{ name = "alpha", status = "COMPLETED", conclusion = "FAILURE" },
			{ name = "middle", status = "COMPLETED", conclusion = "FAILURE" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("alpha", result[1].name)
		assert.are.equal("middle", result[2].name)
		assert.are.equal("zebra", result[3].name)
	end)

	it("does not modify the original table", function()
		local checks = {
			{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "test", status = "COMPLETED", conclusion = "FAILURE" },
		}
		ui.sort_checks(checks)
		assert.are.equal("lint", checks[1].name)
		assert.are.equal("test", checks[2].name)
	end)

	it("returns empty table for empty input", function()
		assert.are.equal(0, #ui.sort_checks({}))
	end)

	it("groups TIMED_OUT and STARTUP_FAILURE with failures", function()
		local checks = {
			{ name = "success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "startup", status = "COMPLETED", conclusion = "STARTUP_FAILURE" },
			{ name = "timeout", status = "COMPLETED", conclusion = "TIMED_OUT" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("startup", result[1].name)
		assert.are.equal("timeout", result[2].name)
		assert.are.equal("success", result[3].name)
	end)

	it("groups NEUTRAL with SKIPPED", function()
		local checks = {
			{ name = "success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "neutral", status = "COMPLETED", conclusion = "NEUTRAL" },
			{ name = "skipped", status = "COMPLETED", conclusion = "SKIPPED" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("neutral", result[1].name)
		assert.are.equal("skipped", result[2].name)
		assert.are.equal("success", result[3].name)
	end)

	it("groups QUEUED and PENDING with IN_PROGRESS", function()
		local checks = {
			{ name = "success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "queued", status = "QUEUED" },
			{ name = "pending", status = "PENDING" },
			{ name = "progress", status = "IN_PROGRESS" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("pending", result[1].name)
		assert.are.equal("progress", result[2].name)
		assert.are.equal("queued", result[3].name)
		assert.are.equal("success", result[4].name)
	end)

	it("places unknown conclusions last", function()
		local checks = {
			{ name = "unknown", status = "COMPLETED", conclusion = "SOMETHING_NEW" },
			{ name = "success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "failure", status = "COMPLETED", conclusion = "FAILURE" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("failure", result[1].name)
		assert.are.equal("success", result[2].name)
		assert.are.equal("unknown", result[3].name)
	end)

	it("sorts StatusContext checks alongside CheckRun checks", function()
		local checks = {
			{ name = "action-success", status = "COMPLETED", conclusion = "SUCCESS" },
			{ context = "status-failure", state = "FAILURE" },
			{ context = "status-success", state = "SUCCESS" },
			{ name = "action-failure", status = "COMPLETED", conclusion = "FAILURE" },
		}
		local result = ui.sort_checks(checks)
		assert.are.equal("action-failure", result[1].name or result[1].context)
		assert.are.equal("status-failure", result[2].name or result[2].context)
		assert.are.equal("action-success", result[3].name or result[3].context)
		assert.are.equal("status-success", result[4].name or result[4].context)
	end)
end)

describe("calculate_overview_layout", function()
	it("calculates correct split dimensions", function()
		local layout = ui.calculate_overview_layout(200, 50, 80, 80, 30)
		-- total_width = 160, inner = 156, right = 46, left = 110
		assert.are.equal(110, layout.left.width)
		assert.are.equal(46, layout.right.width)
		assert.are.equal(layout.left.height, layout.right.height)
		assert.are.equal(layout.left.row, layout.right.row)
	end)

	it("positions right pane after left pane", function()
		local layout = ui.calculate_overview_layout(200, 50, 80, 80, 30)
		-- right col = left col + left width + 2 (for left window borders)
		assert.are.equal(layout.left.col + layout.left.width + 2, layout.right.col)
	end)

	it("enforces minimum right width of 15", function()
		-- Very small right_pct that would result in < 15
		local layout = ui.calculate_overview_layout(100, 50, 50, 50, 1)
		assert.are.equal(15, layout.right.width)
	end)

	it("enforces minimum left width of 20 when right_pct is very large", function()
		local layout = ui.calculate_overview_layout(100, 50, 50, 50, 99)
		assert.is_true(layout.left.width >= 20)
		assert.is_true(layout.right.width >= 15)
	end)

	it("clamps total_width to ensure minimum inner space", function()
		-- Very small screen or pct_w that would make inner < 35
		local layout = ui.calculate_overview_layout(40, 50, 10, 50, 30)
		assert.is_true(layout.left.width >= 20)
		assert.is_true(layout.right.width >= 15)
	end)

	it("clamps right_pct to valid range", function()
		-- right_pct > 100 should be clamped
		local layout = ui.calculate_overview_layout(200, 50, 80, 80, 150)
		assert.is_true(layout.left.width >= 20)
		assert.is_true(layout.right.width >= 15)
		-- right_pct < 0 should be clamped
		local layout2 = ui.calculate_overview_layout(200, 50, 80, 80, -10)
		assert.is_true(layout2.left.width >= 20)
		assert.is_true(layout2.right.width >= 15)
	end)

	it("centers the layout horizontally", function()
		local layout = ui.calculate_overview_layout(200, 50, 50, 50, 30)
		-- total_width = 100, start_col = 50
		assert.are.equal(50, layout.left.col)
	end)

	it("centers the layout vertically", function()
		local layout = ui.calculate_overview_layout(200, 50, 50, 80, 30)
		-- height = 40, row = 5
		assert.are.equal(5, layout.left.row)
		assert.are.equal(5, layout.right.row)
	end)
end)

describe("build_overview_left_lines", function()
	local identity = function(s)
		return s or ""
	end

	it("includes PR title and number", function()
		local pr = { number = 42, title = "Fix bug", state = "OPEN", url = "https://example.com" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.truthy(result.lines[1]:find("PR #42: Fix bug"))
	end)

	it("includes author", function()
		local pr = { number = 1, title = "T", state = "OPEN", author = { login = "alice" }, url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.truthy(result.lines[2]:find("@alice"))
	end)

	it("uses 'unknown' for missing author", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.truthy(result.lines[2]:find("unknown"))
	end)

	it("does not include labels (moved to right pane)", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			labels = { { name = "bug" }, { name = "urgent" } },
		}
		local result = ui.build_overview_left_lines(pr, {}, identity)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:find("^Labels:"))
		end
	end)

	it("shows no description placeholder", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no description%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows description body", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "Hello world" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line == "Hello world" then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("strips CRLF from description body", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "Line1\r\nLine2\r\nLine3" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		for _, line in ipairs(result.lines) do
			assert.is_nil(line:find("\r"), "Line should not contain CR: " .. vim.inspect(line))
		end
		local found_line1 = false
		local found_line2 = false
		for _, line in ipairs(result.lines) do
			if line == "Line1" then
				found_line1 = true
			end
			if line == "Line2" then
				found_line2 = true
			end
		end
		assert.is_true(found_line1)
		assert.is_true(found_line2)
	end)

	it("shows no comments placeholder", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no comments%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("includes issue comments", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local issue_comments = {
			{ user = { login = "bob" }, created_at = "2024-01-01", body = "looks good" },
		}
		local result = ui.build_overview_left_lines(pr, issue_comments, identity)
		local found_author = false
		local found_body = false
		for _, line in ipairs(result.lines) do
			if line:find("@bob") then
				found_author = true
			end
			if line == "looks good" then
				found_body = true
			end
		end
		assert.is_true(found_author)
		assert.is_true(found_body)
	end)

	it("strips CRLF from issue comment body", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local issue_comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "First\r\nSecond" },
		}
		local result = ui.build_overview_left_lines(pr, issue_comments, identity)
		for _, line in ipairs(result.lines) do
			assert.is_nil(line:find("\r"), "Line should not contain CR: " .. vim.inspect(line))
		end
		local found_first = false
		local found_second = false
		for _, line in ipairs(result.lines) do
			if line == "First" then
				found_first = true
			end
			if line == "Second" then
				found_second = true
			end
		end
		assert.is_true(found_first)
		assert.is_true(found_second)
	end)

	it("includes footer with keybind hints", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local last_content = result.lines[#result.lines]
		assert.truthy(last_content:find("sections"))
		assert.truthy(last_content:find("comment"))
		assert.truthy(last_content:find("refresh"))
		assert.truthy(last_content:find("close"))
		assert.truthy(last_content:find("switch"))
	end)

	it("produces correct highlight ranges", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		-- At minimum: footer (section headers use markdown syntax highlighting via treesitter)
		assert.is_true(#result.hl_ranges >= 1)
	end)

	it("does not include CI STATUS (moved to right pane)", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			},
		}
		local result = ui.build_overview_left_lines(pr, {}, identity)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:find("^CI STATUS"))
		end
		assert.is_nil(result.sections.ci_status)
	end)

	it("returns sections with 1-indexed line numbers", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.is_table(result.sections)
		assert.is_number(result.sections.description)
		assert.is_number(result.sections.comments)
		-- Each section line should contain the section header text
		assert.truthy(result.lines[result.sections.description]:find("DESCRIPTION"))
		assert.truthy(result.lines[result.sections.comments]:find("COMMENTS"))
	end)

	it("returns sections in correct order", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "text" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.is_true(result.sections.description < result.sections.comments)
	end)

	it("does not include reviewers (moved to right pane)", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			reviewRequests = { { login = "alice" } },
		}
		local result = ui.build_overview_left_lines(pr, {}, identity)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:find("^REVIEWERS"))
		end
		assert.is_nil(result.sections.reviewers)
	end)

	it("returns empty comment_positions when no issue comments", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.is_table(result.comment_positions)
		assert.are.equal(0, #result.comment_positions)
	end)

	it("returns comment_positions pointing to comment header lines", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local issue_comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
		}
		local result = ui.build_overview_left_lines(pr, issue_comments, identity)
		assert.are.equal(2, #result.comment_positions)
		-- Each position should point to a line containing the comment author
		assert.truthy(result.lines[result.comment_positions[1]]:find("@alice"))
		assert.truthy(result.lines[result.comment_positions[2]]:find("@bob"))
	end)

	it("returns comment_positions in ascending order", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local issue_comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
			{ user = { login = "carol" }, created_at = "2024-01-03", body = "third" },
		}
		local result = ui.build_overview_left_lines(pr, issue_comments, identity)
		assert.are.equal(3, #result.comment_positions)
		assert.is_true(result.comment_positions[1] < result.comment_positions[2])
		assert.is_true(result.comment_positions[2] < result.comment_positions[3])
	end)

	it("uses markdown # heading for PR title", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		assert.truthy(result.lines[1]:match("^# "))
	end)

	it("uses markdown ## headings for sections", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "text" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local heading_count = 0
		for _, line in ipairs(result.lines) do
			if line:match("^## ") then
				heading_count = heading_count + 1
			end
		end
		assert.are.equal(2, heading_count) -- DESCRIPTION, COMMENTS
	end)

	it("uses markdown ### headings for individual comments", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
		}
		local result = ui.build_overview_left_lines(pr, comments, identity)
		local h3_count = 0
		for _, line in ipairs(result.lines) do
			if line:match("^### ") then
				h3_count = h3_count + 1
			end
		end
		assert.are.equal(2, h3_count)
	end)

	it("does not contain separator lines", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "text" }
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
		}
		local result = ui.build_overview_left_lines(pr, comments, identity)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:match("^%-%-%-%-%-%-%-%-%-%-"), "Should not contain separator: " .. line)
		end
	end)

	it("includes fold hint in footer", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_left_lines(pr, {}, identity)
		local last = result.lines[#result.lines]
		assert.truthy(last:find("fold"))
	end)
end)

describe("build_overview_right_lines", function()
	it("shows REVIEWERS section with reviewers", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			reviewRequests = { { login = "bob" } },
			latestReviews = { { author = { login = "alice" }, state = "APPROVED" } },
		}
		local result = ui.build_overview_right_lines(pr)
		local found_header = false
		local found_alice = false
		local found_bob = false
		for _, line in ipairs(result.lines) do
			if line:find("REVIEWERS") and line:find("1/2 approved") then
				found_header = true
			end
			if line:find("✓") and line:find("@alice") and line:find("approved") then
				found_alice = true
			end
			if line:find("●") and line:find("@bob") and line:find("pending") then
				found_bob = true
			end
		end
		assert.is_true(found_header)
		assert.is_true(found_alice)
		assert.is_true(found_bob)
	end)

	it("shows no reviewers placeholder when no reviewers", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_right_lines(pr)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no reviewers%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows ASSIGNEES section", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			assignees = { { login = "alice" }, { login = "bob" } },
		}
		local result = ui.build_overview_right_lines(pr)
		local found_header = false
		local found_alice = false
		local found_bob = false
		for _, line in ipairs(result.lines) do
			if line == "## ASSIGNEES" then
				found_header = true
			end
			if line == "@alice" then
				found_alice = true
			end
			if line == "@bob" then
				found_bob = true
			end
		end
		assert.is_true(found_header)
		assert.is_true(found_alice)
		assert.is_true(found_bob)
	end)

	it("shows no assignees placeholder when empty", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_right_lines(pr)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no assignees%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows LABELS section", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			labels = { { name = "bug" }, { name = "urgent" } },
		}
		local result = ui.build_overview_right_lines(pr)
		local found_header = false
		local found_bug = false
		local found_urgent = false
		for _, line in ipairs(result.lines) do
			if line == "## LABELS" then
				found_header = true
			end
			if line == "bug" then
				found_bug = true
			end
			if line == "urgent" then
				found_urgent = true
			end
		end
		assert.is_true(found_header)
		assert.is_true(found_bug)
		assert.is_true(found_urgent)
	end)

	it("shows no labels placeholder when empty", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_right_lines(pr)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no labels%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows CI STATUS section with checks", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
				{ name = "test", status = "COMPLETED", conclusion = "FAILURE" },
			},
		}
		local result = ui.build_overview_right_lines(pr)
		local found_header = false
		local found_lint = false
		local found_test = false
		for _, line in ipairs(result.lines) do
			if line:find("CI STATUS") and line:find("1/2 passed") then
				found_header = true
			end
			if line:find("✓") and line:find("lint") then
				found_lint = true
			end
			if line:find("✗") and line:find("test") then
				found_test = true
			end
		end
		assert.is_true(found_header)
		assert.is_true(found_lint)
		assert.is_true(found_test)
	end)

	it("shows no checks placeholder when statusCheckRollup is empty", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", statusCheckRollup = {} }
		local result = ui.build_overview_right_lines(pr)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no checks%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows no checks placeholder when statusCheckRollup is nil", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_right_lines(pr)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no checks%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("highlights check lines with correct groups", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
				{ name = "test", status = "IN_PROGRESS" },
			},
		}
		local result = ui.build_overview_right_lines(pr)
		local ok_found = false
		local warn_found = false
		for _, hl in ipairs(result.hl_ranges) do
			if hl.hl == "DiagnosticOk" then
				ok_found = true
			end
			if hl.hl == "DiagnosticWarn" then
				warn_found = true
			end
		end
		assert.is_true(ok_found)
		assert.is_true(warn_found)
	end)

	it("deduplicates checks keeping latest", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "FAILURE" },
				{ name = "test", status = "COMPLETED", conclusion = "SUCCESS" },
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			},
		}
		local result = ui.build_overview_right_lines(pr)
		local found_header = false
		for _, line in ipairs(result.lines) do
			if line:find("CI STATUS") and line:find("2/2 passed") then
				found_header = true
			end
		end
		assert.is_true(found_header)
	end)

	it("returns check_urls mapping for detailsUrl", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS", detailsUrl = "https://example.com/lint" },
				{ name = "test", status = "COMPLETED", conclusion = "FAILURE" },
			},
		}
		local result = ui.build_overview_right_lines(pr)
		assert.is_table(result.check_urls)
		local has_url = false
		for _, url in pairs(result.check_urls) do
			if url == "https://example.com/lint" then
				has_url = true
			end
		end
		assert.is_true(has_url)
	end)

	it("uses markdown headings for sections", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_right_lines(pr)
		-- Section headers use markdown ## syntax (highlighted by treesitter, not manual hl_ranges)
		local heading_count = 0
		for _, line in ipairs(result.lines) do
			if line:match("^## ") then
				heading_count = heading_count + 1
			end
		end
		assert.are.equal(4, heading_count)
	end)

	it("highlights reviewer lines with correct groups", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			latestReviews = { { author = { login = "alice" }, state = "APPROVED" } },
		}
		local result = ui.build_overview_right_lines(pr)
		local ok_found = false
		for _, hl in ipairs(result.hl_ranges) do
			if hl.hl == "DiagnosticOk" then
				ok_found = true
			end
		end
		assert.is_true(ok_found)
	end)

	it("does not contain separator lines", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			assignees = { { login = "alice" } },
			labels = { { name = "bug" } },
			statusCheckRollup = {
				{ name = "lint", status = "COMPLETED", conclusion = "SUCCESS" },
			},
		}
		local result = ui.build_overview_right_lines(pr)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:match("^%-%-%-%-%-%-%-%-%-%-"), "Should not contain separator: " .. line)
		end
	end)
end)

describe("format_review_status", function()
	it("returns check mark for APPROVED", function()
		local symbol, hl = ui.format_review_status("APPROVED")
		assert.are.equal("✓", symbol)
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns x for CHANGES_REQUESTED", function()
		local symbol, hl = ui.format_review_status("CHANGES_REQUESTED")
		assert.are.equal("✗", symbol)
		assert.are.equal("DiagnosticError", hl)
	end)

	it("returns comment icon for COMMENTED", function()
		local symbol, hl = ui.format_review_status("COMMENTED")
		assert.are.equal("💬", symbol)
		assert.are.equal("DiagnosticInfo", hl)
	end)

	it("returns dash for DISMISSED", function()
		local symbol, hl = ui.format_review_status("DISMISSED")
		assert.are.equal("-", symbol)
		assert.are.equal("Comment", hl)
	end)

	it("returns circle for PENDING", function()
		local symbol, hl = ui.format_review_status("PENDING")
		assert.are.equal("●", symbol)
		assert.are.equal("DiagnosticWarn", hl)
	end)

	it("returns question mark for unknown state", function()
		local symbol, hl = ui.format_review_status("SOMETHING_NEW")
		assert.are.equal("?", symbol)
		assert.are.equal("Comment", hl)
	end)
end)

describe("build_reviewers_list", function()
	it("combines review requests and latest reviews", function()
		local requests = { { login = "bob" } }
		local reviews = { { author = { login = "alice" }, state = "APPROVED" } }
		local result = ui.build_reviewers_list(requests, reviews)
		assert.are.equal(2, #result)
		-- Sorted by login
		assert.are.equal("alice", result[1].login)
		assert.are.equal("APPROVED", result[1].state)
		assert.are.equal("bob", result[2].login)
		assert.are.equal("PENDING", result[2].state)
	end)

	it("uses latestReviews state over reviewRequests", function()
		local requests = { { login = "alice" } }
		local reviews = { { author = { login = "alice" }, state = "APPROVED" } }
		local result = ui.build_reviewers_list(requests, reviews)
		assert.are.equal(1, #result)
		assert.are.equal("APPROVED", result[1].state)
	end)

	it("returns empty list when no reviewers", function()
		assert.are.equal(0, #ui.build_reviewers_list({}, {}))
	end)

	it("handles reviewers only in reviewRequests", function()
		local requests = { { login = "alice" }, { login = "bob" } }
		local result = ui.build_reviewers_list(requests, {})
		assert.are.equal(2, #result)
		assert.are.equal("PENDING", result[1].state)
		assert.are.equal("PENDING", result[2].state)
	end)

	it("handles reviewers only in latestReviews", function()
		local reviews = { { author = { login = "alice" }, state = "CHANGES_REQUESTED" } }
		local result = ui.build_reviewers_list({}, reviews)
		assert.are.equal(1, #result)
		assert.are.equal("CHANGES_REQUESTED", result[1].state)
	end)

	it("skips reviews with nil author", function()
		local reviews = { { author = nil, state = "COMMENTED" } }
		local result = ui.build_reviewers_list({}, reviews)
		assert.are.equal(0, #result)
	end)

	it("sorts reviewers alphabetically by login", function()
		local requests = { { login = "charlie" }, { login = "alice" } }
		local reviews = { { author = { login = "bob" }, state = "APPROVED" } }
		local result = ui.build_reviewers_list(requests, reviews)
		assert.are.equal("alice", result[1].login)
		assert.are.equal("bob", result[2].login)
		assert.are.equal("charlie", result[3].login)
	end)
end)

describe("build_reviewers_summary", function()
	it("returns correct count for all approved", function()
		local reviewers = {
			{ login = "alice", state = "APPROVED" },
			{ login = "bob", state = "APPROVED" },
		}
		assert.are.equal("2/2 approved", ui.build_reviewers_summary(reviewers))
	end)

	it("returns correct count for mixed states", function()
		local reviewers = {
			{ login = "alice", state = "APPROVED" },
			{ login = "bob", state = "PENDING" },
			{ login = "charlie", state = "CHANGES_REQUESTED" },
		}
		assert.are.equal("1/3 approved", ui.build_reviewers_summary(reviewers))
	end)

	it("returns correct count for none approved", function()
		local reviewers = {
			{ login = "alice", state = "PENDING" },
		}
		assert.are.equal("0/1 approved", ui.build_reviewers_summary(reviewers))
	end)

	it("returns empty string for empty list", function()
		assert.are.equal("", ui.build_reviewers_summary({}))
	end)
end)

describe("calculate_comments_height", function()
	it("returns min_height when line_count is smaller", function()
		assert.are.equal(5, ui.calculate_comments_height(2, 5, 20))
	end)

	it("returns line_count when within range", function()
		assert.are.equal(10, ui.calculate_comments_height(10, 5, 20))
	end)

	it("returns max_height when line_count exceeds it", function()
		assert.are.equal(20, ui.calculate_comments_height(30, 5, 20))
	end)
end)

describe("calculate_reply_window_dimensions", function()
	it("calculates dimensions with defaults", function()
		local dim = ui.calculate_reply_window_dimensions(100, 50, 10)
		assert.are.equal(60, dim.width) -- 100 * 0.6
		assert.are.equal(10, dim.upper_height)
		assert.are.equal(5, dim.lower_height)
	end)

	it("clamps upper_height to max_upper_pct", function()
		local dim = ui.calculate_reply_window_dimensions(100, 50, 100)
		assert.are.equal(25, dim.upper_height) -- 50 * 0.5
	end)

	it("respects custom options", function()
		local dim = ui.calculate_reply_window_dimensions(100, 50, 10, {
			width_pct = 0.8,
			lower_height = 10,
		})
		assert.are.equal(80, dim.width)
		assert.are.equal(10, dim.lower_height)
	end)
end)

describe("format_reply_comments_for_display", function()
	local identity = function(s)
		return s or ""
	end

	it("formats single comment with header", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_reply_comments_for_display(comments, identity)
		assert.are.equal("@alice (2024-01-01):", result.lines[1])
		assert.are.equal("test", result.lines[2])
	end)

	it("includes author highlight range", function()
		local comments = {
			{ user = { login = "bob" }, created_at = "2024-01-01", body = "x" },
		}
		local result = ui.format_reply_comments_for_display(comments, identity)
		local author_hl = result.hl_ranges[1]
		assert.are.equal(0, author_hl.line)
		assert.are.equal(0, author_hl.col_start)
		assert.are.equal(4, author_hl.col_end) -- "@bob"
		assert.are.equal("ReviewCommentAuthor", author_hl.hl)
	end)

	it("includes timestamp highlight range", function()
		local comments = {
			{ user = { login = "bob" }, created_at = "2024-01-01", body = "x" },
		}
		local result = ui.format_reply_comments_for_display(comments, identity)
		local ts_hl = result.hl_ranges[2]
		assert.are.equal("ReviewCommentTimestamp", ts_hl.hl)
	end)

	it("adds separator between multiple comments", function()
		local comments = {
			{ user = { login = "a" }, created_at = "d1", body = "x" },
			{ user = { login = "b" }, created_at = "d2", body = "y" },
		}
		local result = ui.format_reply_comments_for_display(comments, identity)
		assert.are.equal(string.rep("-", 40), result.lines[4])
	end)

	it("strips CRLF from body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\r\nline2" },
		}
		local result = ui.format_reply_comments_for_display(comments, identity)
		assert.are.equal("line1", result.lines[2])
		assert.are.equal("line2", result.lines[3])
		for _, line in ipairs(result.lines) do
			assert.is_nil(line:find("\r"), "Line should not contain CR")
		end
	end)
end)

describe("calculate_comment_browser_layout", function()
	it("returns 3-pane layout with correct structure", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.is_table(layout.left)
		assert.is_table(layout.right_upper)
		assert.is_table(layout.right_lower)
		assert.is_number(layout.left.width)
		assert.is_number(layout.right_upper.width)
		assert.is_number(layout.right_lower.width)
	end)

	it("right panes share same width", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.are.equal(layout.right_upper.width, layout.right_lower.width)
	end)

	it("right panes share same col", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.are.equal(layout.right_upper.col, layout.right_lower.col)
	end)

	it("right_lower.row = right_upper.row + right_upper.height + 3 (gap)", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.are.equal(layout.right_upper.row + layout.right_upper.height + 3, layout.right_lower.row)
	end)

	it("upper + lower height + 3 gap rows equals total height", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.are.equal(layout.left.height, layout.right_upper.height + layout.right_lower.height + 3)
	end)

	it("left + right widths + 4 border chars fits in total", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		-- Total width = left_width + 2 (left border) + right_width + 2 (right border)
		local total = layout.left.width + layout.right_upper.width + 4
		assert.is_true(total <= math.floor(200 * 80 / 100) + 4) -- within expected range
	end)

	it("enforces minimum dimensions for small terminal", function()
		local layout = ui.calculate_comment_browser_layout(60, 15, 100, 100)
		assert.is_true(layout.left.width >= 20)
		assert.is_true(layout.right_upper.width >= 25)
		assert.is_true(layout.right_upper.height >= 5)
		assert.is_true(layout.right_lower.height >= 5)
	end)

	it("right pane starts after left pane with 2 border chars", function()
		local layout = ui.calculate_comment_browser_layout(200, 50, 80, 80)
		assert.are.equal(layout.left.col + layout.left.width + 2, layout.right_upper.col)
	end)
end)

describe("format_comment_browser_list", function()
	local id_fn = function(s)
		return s or ""
	end

	it("returns one line per entry", function()
		local entries = {
			{
				type = "review",
				last_ts = "2024-01-01T00:00:00Z",
				author = "alice",
				path = "src/a.lua",
				line = 10,
				is_pending = false,
			},
			{ type = "issue", last_ts = "2024-01-02T00:00:00Z", author = "bob", is_pending = false },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.are.equal(2, #result.lines)
	end)

	it("formats review entry with author and path", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "src/a.lua", line = 10, is_pending = false },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_truthy(result.lines[1]:find("@alice"))
		assert.is_truthy(result.lines[1]:find("src/a.lua:10"))
	end)

	it("formats issue entry with PR Comment label and no author", function()
		local entries = {
			{ type = "issue", last_ts = "2024-01-01", author = nil, is_pending = false },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_truthy(result.lines[1]:find("PR Comment"))
		assert.is_falsy(result.lines[1]:find("@"))
	end)

	it("formats pending entry with [pending] label", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "src/a.lua", line = 5, is_pending = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_truthy(result.lines[1]:find("%[pending%]"))
	end)

	it("truncates long lines to max_width", function()
		local entries = {
			{
				type = "review",
				last_ts = "2024-01-01",
				author = "alice",
				path = "very/long/path/that/is/really/long/file.lua",
				line = 10,
				is_pending = false,
			},
		}
		local result = ui.format_comment_browser_list(entries, 30, id_fn)
		assert.is_true(#result.lines[1] <= 30)
		assert.is_truthy(result.lines[1]:find("%.%.%."))
	end)

	it("includes highlight ranges for PR Comment", function()
		local entries = {
			{ type = "issue", last_ts = "2024-01-01", author = nil, is_pending = false },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_true(#result.hl_ranges > 0)
		assert.are.equal("DiagnosticInfo", result.hl_ranges[1].hl)
	end)

	it("includes highlight ranges for pending", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "a", path = "f.lua", line = 1, is_pending = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_true(#result.hl_ranges > 0)
		assert.are.equal("DiagnosticHint", result.hl_ranges[1].hl)
	end)

	it("formats outdated entry with [outdated] label", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "a", path = "f.lua", line = 1, is_outdated = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_true(result.lines[1]:find("%[outdated%]") ~= nil)
		assert.is_true(#result.hl_ranges > 0)
		assert.are.equal("Comment", result.hl_ranges[1].hl)
	end)

	it("shows pending over outdated when both are true", function()
		local entries = {
			{
				type = "review",
				last_ts = "2024-01-01",
				author = "a",
				path = "f.lua",
				line = 1,
				is_pending = true,
				is_outdated = true,
			},
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		-- Pending takes precedence
		assert.is_true(result.lines[1]:find("%[pending%]") ~= nil)
		assert.is_falsy(result.lines[1]:find("%[outdated%]"))
	end)

	it("does not show [outdated] for normal entries", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "f.lua", line = 1 },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn)
		assert.is_falsy(result.lines[1]:find("%[outdated%]"))
		assert.is_true(result.lines[1]:find("@alice") ~= nil)
	end)

	it("returns empty lines for empty entries", function()
		local result = ui.format_comment_browser_list({}, 120, id_fn)
		assert.are.equal(0, #result.lines)
	end)

	it("hides [outdated] label when outdated_opts.show = false", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "f.lua", line = 1, is_outdated = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn, { show = false })
		assert.is_falsy(result.lines[1]:find("%[outdated%]"))
		-- Should show as normal entry with author
		assert.is_true(result.lines[1]:find("@alice") ~= nil)
	end)

	it("uses custom label from outdated_opts.label", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "f.lua", line = 1, is_outdated = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn, { label = "[OLD]" })
		assert.is_true(result.lines[1]:find("%[OLD%]") ~= nil)
		assert.is_falsy(result.lines[1]:find("%[outdated%]"))
	end)

	it("uses custom hl_group from outdated_opts.hl_group", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "f.lua", line = 1, is_outdated = true },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn, { hl_group = "Error" })
		assert.are.equal("Error", result.hl_ranges[1].hl)
	end)

	it("applies format_path_fn to review entry path", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "lua/fude/init.lua", line = 42 },
		}
		local tail_fn = function(p)
			return p:match("[^/]+$")
		end
		local result = ui.format_comment_browser_list(entries, 120, id_fn, nil, tail_fn)
		assert.is_truthy(result.lines[1]:find("init.lua:42"))
		assert.is_falsy(result.lines[1]:find("lua/fude/init.lua"))
	end)

	it("applies format_path_fn to pending entry path", function()
		local entries = {
			{
				type = "review",
				last_ts = "2024-01-01",
				author = "a",
				path = "lua/fude/config.lua",
				line = 5,
				is_pending = true,
			},
		}
		local tail_fn = function(p)
			return p:match("[^/]+$")
		end
		local result = ui.format_comment_browser_list(entries, 120, id_fn, nil, tail_fn)
		assert.is_truthy(result.lines[1]:find("config.lua:5"))
		assert.is_falsy(result.lines[1]:find("lua/fude/config.lua"))
	end)

	it("applies format_path_fn to outdated entry path", function()
		local entries = {
			{
				type = "review",
				last_ts = "2024-01-01",
				author = "a",
				path = "lua/fude/ui.lua",
				line = 10,
				is_outdated = true,
			},
		}
		local tail_fn = function(p)
			return p:match("[^/]+$")
		end
		local result = ui.format_comment_browser_list(entries, 120, id_fn, nil, tail_fn)
		assert.is_truthy(result.lines[1]:find("ui.lua:10"))
		assert.is_falsy(result.lines[1]:find("lua/fude/ui.lua"))
	end)

	it("uses identity when format_path_fn is nil", function()
		local entries = {
			{ type = "review", last_ts = "2024-01-01", author = "alice", path = "lua/fude/init.lua", line = 42 },
		}
		local result = ui.format_comment_browser_list(entries, 120, id_fn, nil, nil)
		assert.is_truthy(result.lines[1]:find("lua/fude/init.lua:42"))
	end)
end)

describe("format_comment_browser_thread", function()
	local id_fn = function(s)
		return s or ""
	end

	it("formats review comment thread", function()
		local entry = {
			type = "review",
			comments = {
				{ id = 1, user = { login = "alice" }, created_at = "2024-01-01", body = "fix this" },
			},
		}
		local all_comments = {
			{ id = 1, user = { login = "alice" }, created_at = "2024-01-01", body = "fix this", in_reply_to_id = nil },
		}
		local result = ui.format_comment_browser_thread(entry, all_comments, {}, id_fn)
		assert.is_true(#result.lines > 0)
		assert.is_truthy(result.lines[1]:find("@alice"))
	end)

	it("formats issue comments showing all issue comments", function()
		local entry = {
			type = "issue",
			comments = {
				{ id = 10, user = { login = "bob" }, created_at = "2024-01-01", body = "great work" },
			},
		}
		local all_issue_comments = {
			{ id = 10, user = { login = "bob" }, created_at = "2024-01-01", body = "great work" },
			{ id = 11, user = { login = "carol" }, created_at = "2024-01-02", body = "thanks" },
		}
		local result = ui.format_comment_browser_thread(entry, {}, all_issue_comments, id_fn)
		assert.is_true(#result.lines > 0)
		-- Both issue comments should be shown
		local has_bob = false
		local has_carol = false
		for _, line in ipairs(result.lines) do
			if line:find("@bob") then
				has_bob = true
			end
			if line:find("@carol") then
				has_carol = true
			end
		end
		assert.is_true(has_bob)
		assert.is_true(has_carol)
	end)

	it("returns placeholder for empty comment", function()
		local entry = { type = "review", comments = {} }
		local result = ui.format_comment_browser_thread(entry, {}, {}, id_fn)
		assert.is_true(#result.lines > 0)
	end)
end)

describe("parse_markdown_line", function()
	-- Note: These tests require markdown_inline parser to be available
	-- If parser is not available, parse_markdown_line returns nil

	it("returns nil for empty string", function()
		local result = ui.parse_markdown_line("")
		assert.is_nil(result)
	end)

	it("returns nil for nil input", function()
		local result = ui.parse_markdown_line(nil)
		assert.is_nil(result)
	end)

	it("returns nil for plain text without markdown", function()
		local result = ui.parse_markdown_line("just plain text")
		-- With parser: returns nil (no segments)
		-- Without parser: returns nil
		-- Either way, nil is expected
		assert.is_nil(result)
	end)

	-- The following tests are conditional on parser availability
	it("parses bold text when parser available", function()
		local result = ui.parse_markdown_line("**bold** text")
		if result then
			assert.is_true(#result >= 1)
			local found_bold = false
			for _, seg in ipairs(result) do
				if seg.hl_type == "bold" then
					found_bold = true
				end
			end
			assert.is_true(found_bold)
		end
	end)

	it("parses italic text when parser available", function()
		local result = ui.parse_markdown_line("*italic* text")
		if result then
			assert.is_true(#result >= 1)
			local found_italic = false
			for _, seg in ipairs(result) do
				if seg.hl_type == "italic" then
					found_italic = true
				end
			end
			assert.is_true(found_italic)
		end
	end)

	it("parses code span when parser available", function()
		local result = ui.parse_markdown_line("`code` text")
		if result then
			assert.is_true(#result >= 1)
			local found_code = false
			for _, seg in ipairs(result) do
				if seg.hl_type == "code" then
					found_code = true
				end
			end
			assert.is_true(found_code)
		end
	end)

	it("parses inline link when parser available", function()
		local result = ui.parse_markdown_line("[text](url)")
		if result then
			assert.is_true(#result >= 1)
			local found_link = false
			for _, seg in ipairs(result) do
				if seg.hl_type == "link" or seg.hl_type == "link_url" then
					found_link = true
				end
			end
			assert.is_true(found_link)
		end
	end)
end)

describe("build_highlighted_chunks", function()
	it("returns single chunk with base_hl when no segments", function()
		local chunks = ui.build_highlighted_chunks("plain text", nil, "Comment", {})
		assert.are.equal(1, #chunks)
		assert.are.equal("plain text", chunks[1][1])
		assert.are.equal("Comment", chunks[1][2])
	end)

	it("returns single chunk for empty segments", function()
		local chunks = ui.build_highlighted_chunks("plain text", {}, "Comment", {})
		assert.are.equal(1, #chunks)
		assert.are.equal("plain text", chunks[1][1])
	end)

	it("splits line at segment boundaries", function()
		local segments = {
			{ start_col = 0, end_col = 4, hl_type = "bold" },
		}
		local md_hl = { bold = "@markup.strong" }
		local chunks = ui.build_highlighted_chunks("**ab** cd", segments, "Comment", md_hl)
		-- First chunk should be the bold segment
		assert.are.equal("**ab", chunks[1][1])
		assert.are.equal("@markup.strong", chunks[1][2])
	end)

	it("handles multiple segments", function()
		local segments = {
			{ start_col = 0, end_col = 4, hl_type = "bold" },
			{ start_col = 5, end_col = 11, hl_type = "italic" },
		}
		local md_hl = { bold = "@markup.strong", italic = "@markup.italic" }
		local chunks = ui.build_highlighted_chunks("bold *text*", segments, "Comment", md_hl)
		assert.is_true(#chunks >= 2)
	end)

	it("handles segment in middle of line", function()
		local segments = {
			{ start_col = 5, end_col = 9, hl_type = "code" },
		}
		local md_hl = { code = "@markup.raw" }
		local chunks = ui.build_highlighted_chunks("text `cd` end", segments, "Comment", md_hl)
		-- Should have: "text " (base), "`cd`" (code), " end" (base)
		assert.are.equal(3, #chunks)
		assert.are.equal("text ", chunks[1][1])
		assert.are.equal("Comment", chunks[1][2])
		assert.are.equal("`cd`", chunks[2][1])
		assert.are.equal("@markup.raw", chunks[2][2])
		assert.are.equal(" end", chunks[3][1])
		assert.are.equal("Comment", chunks[3][2])
	end)

	it("uses base_hl when hl_type not in md_hl", function()
		local segments = {
			{ start_col = 0, end_col = 4, hl_type = "unknown" },
		}
		local md_hl = {}
		local chunks = ui.build_highlighted_chunks("text", segments, "Comment", md_hl)
		assert.are.equal("Comment", chunks[1][2])
	end)
end)

describe("apply_markdown_highlight_to_line", function()
	it("returns single chunk when md_enabled is false", function()
		local chunks, in_block = ui.apply_markdown_highlight_to_line("**bold**", false, "Comment", {}, false)
		assert.are.equal(1, #chunks)
		assert.are.equal("**bold**", chunks[1][1])
		assert.are.equal("Comment", chunks[1][2])
		assert.is_false(in_block)
	end)

	it("returns single chunk when in_code_block is true", function()
		local chunks, in_block = ui.apply_markdown_highlight_to_line("**bold**", true, "Comment", {}, true)
		assert.are.equal(1, #chunks)
		assert.are.equal("**bold**", chunks[1][1])
		assert.is_true(in_block)
	end)

	it("toggles code block state on fence", function()
		local _, in_block = ui.apply_markdown_highlight_to_line("```", false, "Comment", {}, true)
		assert.is_true(in_block)

		_, in_block = ui.apply_markdown_highlight_to_line("```", true, "Comment", {}, true)
		assert.is_false(in_block)
	end)

	it("returns fence line with base_hl", function()
		local chunks, _ = ui.apply_markdown_highlight_to_line("```python", false, "Comment", {}, true)
		assert.are.equal("```python", chunks[1][1])
		assert.are.equal("Comment", chunks[1][2])
	end)

	it("processes markdown when enabled and not in code block", function()
		local md_hl = { bold = "@markup.strong" }
		-- Without parser, returns single chunk
		-- With parser, may return multiple chunks
		local chunks, in_block = ui.apply_markdown_highlight_to_line("**bold** text", false, "Comment", md_hl, true)
		assert.is_table(chunks)
		assert.is_true(#chunks >= 1)
		assert.is_false(in_block)
	end)
end)

describe("format_comments_for_inline", function()
	local identity = function(s)
		return s or ""
	end

	it("returns virt_lines for a single comment", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "looks good" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		assert.is_table(result.virt_lines)
		-- top border + header + body + bottom border
		assert.is_true(#result.virt_lines >= 4)
	end)

	it("includes author in header line", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- Header is 2nd line (after top border)
		local header = result.virt_lines[2]
		local found_author = false
		for _, chunk in ipairs(header) do
			if chunk[1]:find("@alice") then
				found_author = true
				break
			end
		end
		assert.is_true(found_author)
	end)

	it("includes timestamp in header line", function()
		local comments = {
			{ user = { login = "bob" }, created_at = "2024-01-01", body = "x" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- Header is 2nd line (after top border)
		local header = result.virt_lines[2]
		local found_ts = false
		for _, chunk in ipairs(header) do
			if chunk[1]:find("2024%-01%-01") then
				found_ts = true
				break
			end
		end
		assert.is_true(found_ts)
	end)

	it("includes pending label in top border for pending comments", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "pending", is_pending = true },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- Top border is 1st line and should contain [pending]
		local top_border = result.virt_lines[1]
		local found_pending = false
		for _, chunk in ipairs(top_border) do
			if chunk[1]:find("%[pending%]") then
				found_pending = true
				break
			end
		end
		assert.is_true(found_pending)
	end)

	it("splits multiline body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\nline2\nline3" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- top border + header + 3 body lines + bottom border
		assert.are.equal(6, #result.virt_lines)
	end)

	it("displays all body lines without truncation", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "1\n2\n3\n4\n5\n6\n7" },
		}
		local result = ui.format_comments_for_inline(comments, identity, {})
		-- top border + header + 7 body lines + bottom border = 10 lines
		assert.are.equal(10, #result.virt_lines)
	end)

	it("has horizontal border lines", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "first" },
			{ user = { login = "bob" }, created_at = "2024-01-02", body = "second" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- Check for border lines (─)
		local border_count = 0
		for _, vline in ipairs(result.virt_lines) do
			if vline[1] and vline[1][1]:find("─") then
				border_count = border_count + 1
			end
		end
		-- Each comment has top and bottom border, so at least 4 for 2 comments
		assert.is_true(border_count >= 4)
	end)

	it("uses custom highlight groups", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_inline(comments, identity, {
			hl_group = "CustomBody",
			author_hl = "CustomAuthor",
			timestamp_hl = "CustomTimestamp",
		})
		-- Header is 2nd line (after top border)
		local header = result.virt_lines[2]
		local found_custom_author = false
		local found_custom_ts = false
		for _, chunk in ipairs(header) do
			if chunk[2] == "CustomAuthor" then
				found_custom_author = true
			end
			if chunk[2] == "CustomTimestamp" then
				found_custom_ts = true
			end
		end
		assert.is_true(found_custom_author)
		assert.is_true(found_custom_ts)
	end)

	it("hides author when show_author is false", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_inline(comments, identity, { show_author = false })
		-- Check all lines for author
		local found_author = false
		for _, vline in ipairs(result.virt_lines) do
			for _, chunk in ipairs(vline) do
				if chunk[1]:find("@alice") then
					found_author = true
					break
				end
			end
		end
		assert.is_false(found_author)
	end)

	it("hides timestamp when show_timestamp is false", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_inline(comments, identity, { show_timestamp = false })
		-- Check all lines for timestamp
		local found_ts = false
		for _, vline in ipairs(result.virt_lines) do
			for _, chunk in ipairs(vline) do
				if chunk[1]:find("2024%-01%-01") then
					found_ts = true
					break
				end
			end
		end
		assert.is_false(found_ts)
	end)

	it("handles nil body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = nil },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		assert.is_table(result.virt_lines)
		-- top border + header + bottom border
		assert.is_true(#result.virt_lines >= 3)
	end)

	it("handles CRLF in body", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "line1\r\nline2" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- top border + header + 2 body lines + bottom border
		assert.are.equal(5, #result.virt_lines)
		-- No CR should remain
		for _, vline in ipairs(result.virt_lines) do
			for _, chunk in ipairs(vline) do
				assert.is_nil(chunk[1]:find("\r"))
			end
		end
	end)

	it("uses 'unknown' for missing user", function()
		local comments = {
			{ user = nil, created_at = "2024-01-01", body = "test" },
		}
		local result = ui.format_comments_for_inline(comments, identity)
		-- Header is 2nd line (after top border)
		local header = result.virt_lines[2]
		local found_unknown = false
		for _, chunk in ipairs(header) do
			if chunk[1]:find("@unknown") then
				found_unknown = true
				break
			end
		end
		assert.is_true(found_unknown)
	end)

	it("returns empty virt_lines for empty comments", function()
		local result = ui.format_comments_for_inline({}, identity)
		assert.are.equal(0, #result.virt_lines)
	end)

	it("accepts markdown_highlight option", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "**bold** text" },
		}
		-- Should not error with markdown_highlight = true
		local result = ui.format_comments_for_inline(comments, identity, { markdown_highlight = true })
		assert.is_table(result.virt_lines)
	end)

	it("accepts markdown_highlight = false option", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "**bold** text" },
		}
		local result = ui.format_comments_for_inline(comments, identity, { markdown_highlight = false })
		assert.is_table(result.virt_lines)
		-- Body line should have single chunk (no markdown highlighting)
		-- Body is 3rd line: top border (1), header (2), body (3)
		local body_vline = result.virt_lines[3]
		-- body_vline has: { indent, "" }, { body_text, hl }
		assert.are.equal(2, #body_vline)
	end)

	it("accepts custom markdown_hl options", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01", body = "**bold**" },
		}
		local md_hl = {
			bold = "CustomBold",
			italic = "CustomItalic",
			code = "CustomCode",
		}
		local result = ui.format_comments_for_inline(comments, identity, {
			markdown_highlight = true,
			markdown_hl = md_hl,
		})
		assert.is_table(result.virt_lines)
	end)

	it("does not highlight inside code block", function()
		local comments = {
			{
				user = { login = "alice" },
				created_at = "2024-01-01",
				body = "```\n**bold**\n```",
			},
		}
		local md_hl = { bold = "CustomBold" }
		local result = ui.format_comments_for_inline(comments, identity, {
			markdown_highlight = true,
			markdown_hl = md_hl,
		})
		assert.is_table(result.virt_lines)
		-- Inside code block, **bold** should not get CustomBold highlight
		-- The middle line (```\n**bold**\n```) should be: fence, body, fence
		-- Verify no CustomBold in the body line
		local found_custom_bold = false
		for _, vline in ipairs(result.virt_lines) do
			for _, chunk in ipairs(vline) do
				if chunk[2] == "CustomBold" then
					found_custom_bold = true
				end
			end
		end
		assert.is_false(found_custom_bold)
	end)
end)
