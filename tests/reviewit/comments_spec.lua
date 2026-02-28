local config = require("reviewit.config")
local comments = require("reviewit.comments")

describe("comments data access", function()
	before_each(function()
		config.setup({})
		config.state.comment_map = {
			["lua/foo.lua"] = {
				[10] = { { id = 1, body = "fix this" } },
				[25] = { { id = 2, body = "nice" }, { id = 3, body = "agreed" } },
			},
		}
	end)

	describe("get_comments_at", function()
		it("returns comments for existing path and line", function()
			local result = comments.get_comments_at("lua/foo.lua", 10)
			assert.are.equal(1, #result)
			assert.are.equal("fix this", result[1].body)
		end)

		it("returns multiple comments on the same line", function()
			local result = comments.get_comments_at("lua/foo.lua", 25)
			assert.are.equal(2, #result)
		end)

		it("returns empty table for line with no comments", function()
			local result = comments.get_comments_at("lua/foo.lua", 99)
			assert.are.same({}, result)
		end)

		it("returns empty table for unknown file", function()
			local result = comments.get_comments_at("nope.lua", 10)
			assert.are.same({}, result)
		end)
	end)

	describe("get_comment_lines", function()
		it("returns sorted line numbers", function()
			local result = comments.get_comment_lines("lua/foo.lua")
			assert.are.same({ 10, 25 }, result)
		end)

		it("returns empty table for unknown file", function()
			local result = comments.get_comment_lines("nope.lua")
			assert.are.same({}, result)
		end)
	end)
end)

describe("build_comment_map", function()
	it("builds map from flat comments array", function()
		local input = {
			{ path = "a.lua", line = 10, body = "first" },
			{ path = "a.lua", line = 10, body = "second" },
			{ path = "b.lua", line = 5, body = "other" },
		}
		local map = comments.build_comment_map(input)
		assert.are.equal(2, #map["a.lua"][10])
		assert.are.equal("first", map["a.lua"][10][1].body)
		assert.are.equal(1, #map["b.lua"][5])
	end)

	it("uses original_line as fallback", function()
		local input = {
			{ path = "a.lua", original_line = 7, body = "fallback" },
		}
		local map = comments.build_comment_map(input)
		assert.are.equal(1, #map["a.lua"][7])
	end)

	it("skips comments with nil path", function()
		local input = {
			{ path = nil, line = 10, body = "no path" },
		}
		local map = comments.build_comment_map(input)
		assert.are.same({}, map)
	end)

	it("skips comments with nil line and nil original_line", function()
		local input = {
			{ path = "a.lua", line = nil, original_line = nil, body = "no line" },
		}
		local map = comments.build_comment_map(input)
		assert.are.same({}, map)
	end)

	it("returns empty table for empty input", function()
		local map = comments.build_comment_map({})
		assert.are.same({}, map)
	end)
end)

describe("find_next_comment_line", function()
	it("returns next line after current", function()
		assert.are.equal(20, comments.find_next_comment_line(10, { 5, 10, 20, 30 }))
	end)

	it("wraps around to first line", function()
		assert.are.equal(5, comments.find_next_comment_line(30, { 5, 10, 20, 30 }))
	end)

	it("returns nil for empty list", function()
		assert.is_nil(comments.find_next_comment_line(10, {}))
	end)

	it("wraps around with single element", function()
		assert.are.equal(15, comments.find_next_comment_line(15, { 15 }))
	end)

	it("returns first line greater than current", function()
		assert.are.equal(10, comments.find_next_comment_line(1, { 10, 20, 30 }))
	end)
end)

describe("find_prev_comment_line", function()
	it("returns previous line before current", function()
		assert.are.equal(10, comments.find_prev_comment_line(20, { 5, 10, 20, 30 }))
	end)

	it("wraps around to last line", function()
		assert.are.equal(30, comments.find_prev_comment_line(5, { 5, 10, 20, 30 }))
	end)

	it("returns nil for empty list", function()
		assert.is_nil(comments.find_prev_comment_line(10, {}))
	end)

	it("wraps around with single element", function()
		assert.are.equal(15, comments.find_prev_comment_line(15, { 15 }))
	end)

	it("returns last line less than current", function()
		assert.are.equal(20, comments.find_prev_comment_line(30, { 10, 20, 30 }))
	end)
end)

describe("find_comment_by_id", function()
	it("finds comment by id", function()
		local map = {
			["a.lua"] = {
				[10] = { { id = 1, body = "hello" } },
				[20] = { { id = 2, body = "world" }, { id = 3, body = "!" } },
			},
		}
		local result = comments.find_comment_by_id(3, map)
		assert.is_not_nil(result)
		assert.are.equal("a.lua", result.path)
		assert.are.equal(20, result.line)
		assert.are.equal("!", result.comment.body)
	end)

	it("returns nil for non-existent id", function()
		local map = {
			["a.lua"] = { [10] = { { id = 1, body = "hello" } } },
		}
		assert.is_nil(comments.find_comment_by_id(999, map))
	end)

	it("returns nil for empty map", function()
		assert.is_nil(comments.find_comment_by_id(1, {}))
	end)
end)

describe("parse_draft_key", function()
	it("parses comment draft key", function()
		local result = comments.parse_draft_key("lua/foo.lua:10:20")
		assert.are.same({
			type = "comment",
			path = "lua/foo.lua",
			start_line = 10,
			end_line = 20,
		}, result)
	end)

	it("parses single-line comment key", function()
		local result = comments.parse_draft_key("lua/bar.lua:5:5")
		assert.are.equal("comment", result.type)
		assert.are.equal(5, result.start_line)
		assert.are.equal(5, result.end_line)
	end)

	it("parses reply draft key", function()
		local result = comments.parse_draft_key("reply:123")
		assert.are.same({
			type = "reply",
			comment_id = 123,
		}, result)
	end)

	it("parses issue_comment key", function()
		local result = comments.parse_draft_key("issue_comment")
		assert.are.same({ type = "issue_comment" }, result)
	end)

	it("returns nil for invalid key", function()
		assert.is_nil(comments.parse_draft_key("invalid"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(comments.parse_draft_key(""))
	end)

	it("handles path with colons", function()
		local result = comments.parse_draft_key("a:b/c.lua:1:5")
		assert.are.equal("comment", result.type)
		assert.are.equal("a:b/c.lua", result.path)
		assert.are.equal(1, result.start_line)
		assert.are.equal(5, result.end_line)
	end)
end)

describe("build_submit_request", function()
	it("builds single-line comment request", function()
		local parsed = { type = "comment", path = "a.lua", start_line = 10, end_line = 10 }
		local req = comments.build_submit_request(parsed, "hello", 42, "abc123")
		assert.are.equal("comment", req.type)
		assert.are.same({ 42, "abc123", "a.lua", 10, "hello" }, req.args)
	end)

	it("builds multi-line comment request", function()
		local parsed = { type = "comment", path = "b.lua", start_line = 5, end_line = 15 }
		local req = comments.build_submit_request(parsed, "range", 42, "abc123")
		assert.are.equal("comment_range", req.type)
		assert.are.same({ 42, "abc123", "b.lua", 5, 15, "range" }, req.args)
	end)

	it("builds reply request", function()
		local parsed = { type = "reply", comment_id = 99 }
		local req = comments.build_submit_request(parsed, "reply body", 42, "abc123")
		assert.are.equal("reply", req.type)
		assert.are.same({ 42, 99, "reply body" }, req.args)
	end)

	it("builds issue_comment request", function()
		local parsed = { type = "issue_comment" }
		local req = comments.build_submit_request(parsed, "pr body", 42, "abc123")
		assert.are.equal("issue_comment", req.type)
		assert.are.same({ 42, "pr body" }, req.args)
	end)

	it("treats equal start and end line as single-line", function()
		local parsed = { type = "comment", path = "c.lua", start_line = 7, end_line = 7 }
		local req = comments.build_submit_request(parsed, "body", 1, "sha")
		assert.are.equal("comment", req.type)
		assert.are.equal(7, req.args[4])
	end)
end)

describe("format_submit_result", function()
	it("returns success message when no failures", function()
		local msg, level = comments.format_submit_result(3, 0, 3)
		assert.are.equal("Submitted 3/3 drafts", msg)
		assert.are.equal(vim.log.levels.INFO, level)
	end)

	it("returns warning message with failure count", function()
		local msg, level = comments.format_submit_result(2, 1, 3)
		assert.are.equal("Submitted 2/3 drafts (1 failed)", msg)
		assert.are.equal(vim.log.levels.WARN, level)
	end)

	it("returns warning when all failed", function()
		local msg, level = comments.format_submit_result(0, 3, 3)
		assert.are.equal("Submitted 0/3 drafts (3 failed)", msg)
		assert.are.equal(vim.log.levels.WARN, level)
	end)
end)
