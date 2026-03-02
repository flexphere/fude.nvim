local ui = require("reviewit.ui")

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

	it("applies format_date_fn", function()
		local comments = {
			{ user = { login = "alice" }, created_at = "2024-01-01T00:00:00Z", body = "test" },
		}
		local result = ui.format_comments_for_display(comments, function()
			return "FORMATTED"
		end)
		assert.truthy(result.lines[1]:find("FORMATTED"))
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
end)

describe("build_overview_lines", function()
	local identity = function(s)
		return s or ""
	end

	it("includes PR title and number", function()
		local pr = { number = 42, title = "Fix bug", state = "OPEN", url = "https://example.com" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.truthy(result.lines[1]:find("PR #42: Fix bug"))
	end)

	it("includes author", function()
		local pr = { number = 1, title = "T", state = "OPEN", author = { login = "alice" }, url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.truthy(result.lines[2]:find("@alice"))
	end)

	it("uses 'unknown' for missing author", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.truthy(result.lines[2]:find("unknown"))
	end)

	it("includes labels when present", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			labels = { { name = "bug" }, { name = "urgent" } },
		}
		local result = ui.build_overview_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("bug, urgent") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("omits labels line when no labels", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:find("^Labels:"))
		end
	end)

	it("shows no description placeholder", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line == "Hello world" then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("shows no comments placeholder", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, issue_comments, identity)
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

	it("includes footer with keybind hints", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		local last_content = result.lines[#result.lines]
		assert.truthy(last_content:find("sections"))
		assert.truthy(last_content:find("new comment"))
		assert.truthy(last_content:find("refresh"))
		assert.truthy(last_content:find("close"))
	end)

	it("produces correct highlight ranges", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		-- At minimum: title, DESCRIPTION header, CI STATUS header, COMMENTS header, footer
		assert.is_true(#result.hl_ranges >= 5)
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
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
		-- Should show 2/2 passed (deduplicated lint is SUCCESS)
		local found_header = false
		for _, line in ipairs(result.lines) do
			if line:find("CI STATUS") and line:find("2/2 passed") then
				found_header = true
			end
		end
		assert.is_true(found_header)
	end)

	it("returns sections with 1-indexed line numbers", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.is_table(result.sections)
		assert.is_number(result.sections.description)
		assert.is_number(result.sections.ci_status)
		assert.is_number(result.sections.comments)
		-- Each section line should contain the section header text
		assert.truthy(result.lines[result.sections.description]:find("DESCRIPTION"))
		assert.truthy(result.lines[result.sections.ci_status]:find("CI STATUS"))
		assert.truthy(result.lines[result.sections.comments]:find("COMMENTS"))
	end)

	it("returns sections in correct order", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "text" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.is_true(result.sections.description < result.sections.ci_status)
		assert.is_true(result.sections.ci_status < result.sections.comments)
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
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.is_table(result.check_urls)
		-- Should have at least one URL mapped
		local has_url = false
		for _, url in pairs(result.check_urls) do
			if url == "https://example.com/lint" then
				has_url = true
			end
		end
		assert.is_true(has_url)
	end)

	it("shows REVIEWERS section with reviewers", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			reviewRequests = { { login = "bob" } },
			latestReviews = { { author = { login = "alice" }, state = "APPROVED" } },
		}
		local result = ui.build_overview_lines(pr, {}, identity)
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
		local result = ui.build_overview_lines(pr, {}, identity)
		local found = false
		for _, line in ipairs(result.lines) do
			if line:find("%(no reviewers%)") then
				found = true
				break
			end
		end
		assert.is_true(found)
	end)

	it("places REVIEWERS section before DESCRIPTION", function()
		local pr = {
			number = 1,
			title = "T",
			state = "OPEN",
			url = "",
			reviewRequests = { { login = "alice" } },
		}
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.is_number(result.sections.reviewers)
		assert.is_true(result.sections.reviewers < result.sections.description)
	end)

	it("includes reviewers section in correct order", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "", body = "text" }
		local result = ui.build_overview_lines(pr, {}, identity)
		assert.is_true(result.sections.reviewers < result.sections.description)
		assert.is_true(result.sections.description < result.sections.ci_status)
		assert.is_true(result.sections.ci_status < result.sections.comments)
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
