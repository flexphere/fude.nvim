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
		assert.truthy(last_content:find("new comment"))
		assert.truthy(last_content:find("refresh"))
		assert.truthy(last_content:find("close"))
	end)

	it("produces correct highlight ranges", function()
		local pr = { number = 1, title = "T", state = "OPEN", url = "" }
		local result = ui.build_overview_lines(pr, {}, identity)
		-- At minimum: title, DESCRIPTION header, COMMENTS header, footer
		assert.is_true(#result.hl_ranges >= 4)
	end)
end)
