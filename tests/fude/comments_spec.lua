local config = require("fude.config")
local comments = require("fude.comments")

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

	it("excludes comments belonging to pending review", function()
		local input = {
			{ path = "a.lua", line = 10, body = "submitted", pull_request_review_id = 100 },
			{ path = "a.lua", line = 20, body = "pending", pull_request_review_id = 200 },
			{ path = "b.lua", line = 5, body = "also submitted", pull_request_review_id = 100 },
		}
		local map = comments.build_comment_map(input, 200)
		assert.are.equal(1, #map["a.lua"][10])
		assert.is_nil(map["a.lua"][20])
		assert.are.equal(1, #map["b.lua"][5])
	end)

	it("includes all comments when pending_review_id is nil", function()
		local input = {
			{ path = "a.lua", line = 10, body = "first", pull_request_review_id = 100 },
			{ path = "a.lua", line = 20, body = "second", pull_request_review_id = 200 },
		}
		local map = comments.build_comment_map(input, nil)
		assert.are.equal(1, #map["a.lua"][10])
		assert.are.equal(1, #map["a.lua"][20])
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

describe("get_reply_target_id", function()
	it("returns original id for top-level comment", function()
		local map = {
			["a.lua"] = { [10] = { { id = 100, body = "top-level" } } },
		}
		assert.are.equal(100, comments.get_reply_target_id(100, map))
	end)

	it("returns in_reply_to_id for reply comment", function()
		local map = {
			["a.lua"] = { [10] = { { id = 200, body = "reply", in_reply_to_id = 100 } } },
		}
		assert.are.equal(100, comments.get_reply_target_id(200, map))
	end)

	it("returns original id when comment not found in map", function()
		assert.are.equal(999, comments.get_reply_target_id(999, {}))
	end)
end)

describe("get_comment_thread", function()
	it("returns single comment when no replies", function()
		local all = {
			{ id = 1, body = "hello", created_at = "2024-01-01" },
			{ id = 2, body = "other", created_at = "2024-01-02" },
		}
		local thread = comments.get_comment_thread(1, all)
		assert.are.equal(1, #thread)
		assert.are.equal(1, thread[1].id)
	end)

	it("returns thread with replies sorted by time", function()
		local all = {
			{ id = 1, body = "root", created_at = "2024-01-01" },
			{ id = 2, body = "reply1", created_at = "2024-01-03", in_reply_to_id = 1 },
			{ id = 3, body = "reply2", created_at = "2024-01-02", in_reply_to_id = 1 },
		}
		local thread = comments.get_comment_thread(1, all)
		assert.are.equal(3, #thread)
		assert.are.equal(1, thread[1].id)
		assert.are.equal(3, thread[2].id) -- earlier reply
		assert.are.equal(2, thread[3].id) -- later reply
	end)

	it("finds thread when given reply id", function()
		local all = {
			{ id = 1, body = "root", created_at = "2024-01-01" },
			{ id = 2, body = "reply", created_at = "2024-01-02", in_reply_to_id = 1 },
		}
		local thread = comments.get_comment_thread(2, all)
		assert.are.equal(2, #thread)
		assert.are.equal(1, thread[1].id)
		assert.are.equal(2, thread[2].id)
	end)

	it("handles nested replies", function()
		local all = {
			{ id = 1, body = "root", created_at = "2024-01-01" },
			{ id = 2, body = "reply1", created_at = "2024-01-02", in_reply_to_id = 1 },
			{ id = 3, body = "nested", created_at = "2024-01-03", in_reply_to_id = 2 },
		}
		local thread = comments.get_comment_thread(3, all)
		assert.are.equal(3, #thread)
	end)

	it("returns empty for non-existent id", function()
		local all = {
			{ id = 1, body = "hello", created_at = "2024-01-01" },
		}
		local thread = comments.get_comment_thread(999, all)
		assert.are.same({}, thread)
	end)

	it("excludes comments from different threads", function()
		local all = {
			{ id = 1, body = "thread1", created_at = "2024-01-01" },
			{ id = 2, body = "reply1", created_at = "2024-01-02", in_reply_to_id = 1 },
			{ id = 10, body = "thread2", created_at = "2024-01-01" },
			{ id = 11, body = "reply2", created_at = "2024-01-02", in_reply_to_id = 10 },
		}
		local thread = comments.get_comment_thread(1, all)
		assert.are.equal(2, #thread)
		assert.are.equal(1, thread[1].id)
		assert.are.equal(2, thread[2].id)
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

describe("build_review_comments", function()
	it("builds single-line comment", function()
		local drafts = {
			["src/foo.lua:10:10"] = { "fix this bug" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(1, #result.comments)
		assert.are.equal("src/foo.lua", result.comments[1].path)
		assert.are.equal(10, result.comments[1].line)
		assert.are.equal("fix this bug", result.comments[1].body)
		assert.are.equal("RIGHT", result.comments[1].side)
		assert.is_nil(result.comments[1].start_line)
		assert.are.same({}, result.excluded)
	end)

	it("builds multi-line comment with start_line", function()
		local drafts = {
			["src/bar.lua:5:15"] = { "refactor this", "block" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(1, #result.comments)
		assert.are.equal("src/bar.lua", result.comments[1].path)
		assert.are.equal(15, result.comments[1].line)
		assert.are.equal(5, result.comments[1].start_line)
		assert.are.equal("RIGHT", result.comments[1].side)
		assert.are.equal("RIGHT", result.comments[1].start_side)
		assert.are.equal("refactor this\nblock", result.comments[1].body)
	end)

	it("excludes reply drafts", function()
		local drafts = {
			["reply:123"] = { "thanks!" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(0, #result.comments)
		assert.are.equal("reply", result.excluded["reply:123"])
	end)

	it("excludes issue_comment drafts", function()
		local drafts = {
			["issue_comment"] = { "pr comment" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(0, #result.comments)
		assert.are.equal("issue_comment", result.excluded["issue_comment"])
	end)

	it("excludes invalid keys", function()
		local drafts = {
			["invalid"] = { "body" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(0, #result.comments)
		assert.are.equal("invalid_key", result.excluded["invalid"])
	end)

	it("handles mixed drafts", function()
		local drafts = {
			["src/a.lua:1:1"] = { "comment 1" },
			["src/b.lua:10:20"] = { "comment 2" },
			["reply:456"] = { "reply text" },
			["issue_comment"] = { "pr text" },
		}
		local result = comments.build_review_comments(drafts)
		assert.are.equal(2, #result.comments)
		assert.are.equal("reply", result.excluded["reply:456"])
		assert.are.equal("issue_comment", result.excluded["issue_comment"])
	end)

	it("returns empty result for empty drafts", function()
		local result = comments.build_review_comments({})
		assert.are.equal(0, #result.comments)
		assert.are.same({}, result.excluded)
	end)
end)

describe("build_review_comment_object", function()
	it("builds single-line comment object", function()
		local result = comments.build_review_comment_object("src/foo.lua", 10, 10, "fix this")
		assert.are.equal("src/foo.lua", result.path)
		assert.are.equal(10, result.line)
		assert.are.equal("fix this", result.body)
		assert.are.equal("RIGHT", result.side)
		assert.is_nil(result.start_line)
		assert.is_nil(result.start_side)
	end)

	it("builds multi-line comment object", function()
		local result = comments.build_review_comment_object("src/bar.lua", 5, 15, "refactor")
		assert.are.equal("src/bar.lua", result.path)
		assert.are.equal(15, result.line)
		assert.are.equal("refactor", result.body)
		assert.are.equal("RIGHT", result.side)
		assert.are.equal(5, result.start_line)
		assert.are.equal("RIGHT", result.start_side)
	end)
end)

describe("pending_comments_to_array", function()
	it("converts map to array", function()
		local pending = {
			["a.lua:1:1"] = { path = "a.lua", line = 1, body = "comment 1" },
			["b.lua:10:20"] = { path = "b.lua", line = 20, start_line = 10, body = "comment 2" },
		}
		local result = comments.pending_comments_to_array(pending)
		assert.are.equal(2, #result)
	end)

	it("returns empty array for empty map", function()
		local result = comments.pending_comments_to_array({})
		assert.are.same({}, result)
	end)
end)

describe("build_pending_comments_from_review", function()
	it("builds map from single-line comments", function()
		local review_comments = {
			{ path = "a.lua", line = 10, body = "fix this", side = "RIGHT" },
		}
		local result = comments.build_pending_comments_from_review(review_comments)
		local key = "a.lua:10:10"
		assert.is_not_nil(result[key])
		assert.are.equal("a.lua", result[key].path)
		assert.are.equal(10, result[key].line)
		assert.are.equal("fix this", result[key].body)
		assert.is_nil(result[key].start_line)
	end)

	it("builds map from multi-line comments", function()
		local review_comments = {
			{ path = "b.lua", line = 20, start_line = 10, body = "range comment", side = "RIGHT", start_side = "RIGHT" },
		}
		local result = comments.build_pending_comments_from_review(review_comments)
		local key = "b.lua:10:20"
		assert.is_not_nil(result[key])
		assert.are.equal("b.lua", result[key].path)
		assert.are.equal(20, result[key].line)
		assert.are.equal(10, result[key].start_line)
	end)

	it("uses original_line as fallback", function()
		local review_comments = {
			{ path = "c.lua", original_line = 5, body = "old line" },
		}
		local result = comments.build_pending_comments_from_review(review_comments)
		local key = "c.lua:5:5"
		assert.is_not_nil(result[key])
		assert.are.equal(5, result[key].line)
	end)

	it("skips comments without path or line", function()
		local review_comments = {
			{ path = nil, line = 10, body = "no path" },
			{ path = "a.lua", line = nil, original_line = nil, body = "no line" },
		}
		local result = comments.build_pending_comments_from_review(review_comments)
		assert.are.same({}, result)
	end)

	it("returns empty map for empty input", function()
		local result = comments.build_pending_comments_from_review({})
		assert.are.same({}, result)
	end)
end)

describe("get_comment_line_range", function()
	it("returns start_line and line for multi-line comment", function()
		local comment = { line = 20, start_line = 10, path = "a.lua" }
		local start_line, end_line = comments.get_comment_line_range(comment)
		assert.are.equal(10, start_line)
		assert.are.equal(20, end_line)
	end)

	it("returns same line for single-line comment without start_line", function()
		local comment = { line = 15, path = "a.lua" }
		local start_line, end_line = comments.get_comment_line_range(comment)
		assert.are.equal(15, start_line)
		assert.are.equal(15, end_line)
	end)

	it("uses original_line as fallback when line is nil", function()
		local comment = { original_line = 8, path = "a.lua" }
		local start_line, end_line = comments.get_comment_line_range(comment)
		assert.are.equal(8, start_line)
		assert.are.equal(8, end_line)
	end)

	it("defaults to 1 when both line and original_line are nil", function()
		local comment = { path = "a.lua" }
		local start_line, end_line = comments.get_comment_line_range(comment)
		assert.are.equal(1, start_line)
		assert.are.equal(1, end_line)
	end)
end)
