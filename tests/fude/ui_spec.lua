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
