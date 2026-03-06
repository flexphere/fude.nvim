local config = require("fude.config")
local comments = require("fude.comments")
local data = require("fude.comments.data")

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

	it("includes all comments regardless of review id", function()
		local input = {
			{ path = "a.lua", line = 10, body = "submitted", pull_request_review_id = 100 },
			{ path = "a.lua", line = 20, body = "pending", pull_request_review_id = 200 },
			{ path = "b.lua", line = 5, body = "also submitted", pull_request_review_id = 100 },
		}
		local map = comments.build_comment_map(input)
		assert.are.equal(1, #map["a.lua"][10])
		assert.are.equal(1, #map["a.lua"][20])
		assert.are.equal(1, #map["b.lua"][5])
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
			{ id = 101, path = "a.lua", line = 10, body = "fix this", side = "RIGHT" },
		}
		local result = comments.build_pending_comments_from_review(review_comments)
		local key = "a.lua:10:10"
		assert.is_not_nil(result[key])
		assert.are.equal(101, result[key].id)
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

-- Tests for pure data functions added during refactoring

describe("data.line_from_diff_hunk", function()
	it("returns line for new file at position 1", function()
		local hunk = "@@ -0,0 +1,113 @@\n+package main"
		assert.are.equal(1, data.line_from_diff_hunk(hunk, 1))
	end)

	it("returns correct line for later position in new file", function()
		local hunk = "@@ -0,0 +1,5 @@\n+line1\n+line2\n+line3"
		assert.are.equal(1, data.line_from_diff_hunk(hunk, 1))
		assert.are.equal(2, data.line_from_diff_hunk(hunk, 2))
		assert.are.equal(3, data.line_from_diff_hunk(hunk, 3))
	end)

	it("handles modified file with context and additions", function()
		local hunk = "@@ -10,5 +20,8 @@\n context\n+added"
		assert.are.equal(20, data.line_from_diff_hunk(hunk, 1))
		assert.are.equal(21, data.line_from_diff_hunk(hunk, 2))
	end)

	it("skips deletion lines for new file line count", function()
		local hunk = "@@ -10,3 +20,3 @@\n context\n-deleted\n+added\n context2"
		assert.are.equal(20, data.line_from_diff_hunk(hunk, 1)) -- context
		-- pos 2 is deletion: skipped for RIGHT side
		assert.are.equal(21, data.line_from_diff_hunk(hunk, 3)) -- added
		assert.are.equal(22, data.line_from_diff_hunk(hunk, 4)) -- context2
	end)

	it("returns nil for nil inputs", function()
		assert.is_nil(data.line_from_diff_hunk(nil, 1))
		assert.is_nil(data.line_from_diff_hunk("@@ -0,0 +1 @@\n+x", nil))
	end)

	it("returns nil when position exceeds hunk lines", function()
		local hunk = "@@ -0,0 +1,1 @@\n+only"
		assert.is_nil(data.line_from_diff_hunk(hunk, 99))
	end)

	it("returns nil for invalid hunk header", function()
		assert.is_nil(data.line_from_diff_hunk("no header here", 1))
	end)
end)

describe("data.get_comments_at (pure)", function()
	it("returns comments for existing path and line", function()
		local map = { ["a.lua"] = { [10] = { { id = 1, body = "hello" } } } }
		local result = data.get_comments_at(map, "a.lua", 10)
		assert.are.equal(1, #result)
		assert.are.equal("hello", result[1].body)
	end)

	it("returns empty table for missing path", function()
		local result = data.get_comments_at({}, "nope.lua", 10)
		assert.are.same({}, result)
	end)

	it("returns empty table for missing line", function()
		local map = { ["a.lua"] = { [10] = { { id = 1 } } } }
		local result = data.get_comments_at(map, "a.lua", 99)
		assert.are.same({}, result)
	end)
end)

describe("data.get_comment_lines (pure)", function()
	it("returns sorted line numbers", function()
		local map = { ["a.lua"] = { [25] = { {} }, [10] = { {} }, [5] = { {} } } }
		local result = data.get_comment_lines(map, "a.lua")
		assert.are.same({ 5, 10, 25 }, result)
	end)

	it("returns empty table for missing path", function()
		local result = data.get_comment_lines({}, "nope.lua")
		assert.are.same({}, result)
	end)
end)

describe("is_own_comment", function()
	before_each(function()
		config.setup({})
	end)

	it("returns true when comment user matches github_user", function()
		config.state.github_user = "alice"
		local comment = { user = { login = "alice" }, body = "test" }
		assert.is_true(comments.is_own_comment(comment))
	end)

	it("returns false when comment user does not match", function()
		config.state.github_user = "alice"
		local comment = { user = { login = "bob" }, body = "test" }
		assert.is_false(comments.is_own_comment(comment))
	end)

	it("returns false when github_user is nil", function()
		config.state.github_user = nil
		local comment = { user = { login = "alice" }, body = "test" }
		assert.is_false(comments.is_own_comment(comment))
	end)

	it("returns false when comment has no user field", function()
		config.state.github_user = "alice"
		local comment = { body = "test" }
		assert.is_false(comments.is_own_comment(comment))
	end)

	it("returns false when comment user login is nil", function()
		config.state.github_user = "alice"
		local comment = { user = {}, body = "test" }
		assert.is_false(comments.is_own_comment(comment))
	end)
end)

describe("is_pending_comment", function()
	before_each(function()
		config.setup({})
	end)

	it("returns true when comment belongs to pending review", function()
		config.state.pending_review_id = 200
		local comment = { pull_request_review_id = 200, body = "test" }
		assert.is_true(comments.is_pending_comment(comment))
	end)

	it("returns false when comment belongs to different review", function()
		config.state.pending_review_id = 200
		local comment = { pull_request_review_id = 100, body = "test" }
		assert.is_false(comments.is_pending_comment(comment))
	end)

	it("returns false when no pending review exists", function()
		config.state.pending_review_id = nil
		local comment = { pull_request_review_id = 100, body = "test" }
		assert.is_false(comments.is_pending_comment(comment))
	end)
end)

describe("find_pending_key", function()
	before_each(function()
		config.setup({})
	end)

	it("returns key when matching comment id found", function()
		config.state.pending_comments = {
			["a.lua:5:5"] = { id = 10, path = "a.lua", body = "comment", line = 5 },
			["b.lua:10:20"] = { id = 20, path = "b.lua", body = "other", line = 20 },
		}
		assert.are.equal("a.lua:5:5", comments.find_pending_key(10))
		assert.are.equal("b.lua:10:20", comments.find_pending_key(20))
	end)

	it("returns nil when comment id not found", function()
		config.state.pending_comments = {
			["a.lua:5:5"] = { id = 10, path = "a.lua", body = "comment", line = 5 },
		}
		assert.is_nil(comments.find_pending_key(999))
	end)

	it("returns nil when pending_comments is empty", function()
		config.state.pending_comments = {}
		assert.is_nil(comments.find_pending_key(1))
	end)
end)

describe("data.build_comment_entries", function()
	local function id_fn(s)
		return s
	end

	it("builds entries from comment map", function()
		local map = {
			["a.lua"] = {
				[10] = {
					{ id = 1, body = "hello", user = { login = "alice" }, created_at = "2024-01-01T00:00:00Z" },
				},
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn)
		assert.are.equal(1, #entries)
		assert.are.equal("/repo/a.lua", entries[1].filename)
		assert.are.equal(10, entries[1].lnum)
		assert.are.equal("2024-01-01T00:00:00Z", entries[1].last_ts)
	end)

	it("sorts entries by last_ts descending", function()
		local map = {
			["a.lua"] = {
				[10] = { { id = 1, body = "old", user = { login = "a" }, created_at = "2024-01-01T00:00:00Z" } },
				[20] = { { id = 2, body = "new", user = { login = "b" }, created_at = "2024-02-01T00:00:00Z" } },
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn)
		assert.are.equal(2, #entries)
		assert.are.equal(20, entries[1].lnum) -- newer first
		assert.are.equal(10, entries[2].lnum)
	end)

	it("truncates body preview over 60 chars", function()
		local long_body = string.rep("x", 100)
		local map = {
			["a.lua"] = {
				[1] = { { id = 1, body = long_body, user = { login = "a" }, created_at = "2024-01-01T00:00:00Z" } },
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn)
		assert.is_true(#entries[1].detail < #long_body, "detail should be shorter than full body")
		assert.is_truthy(entries[1].detail:match("%.%.%.$"), "truncated detail should end with '...'")
	end)

	it("returns empty for empty map", function()
		local entries = data.build_comment_entries({}, "/repo", id_fn)
		assert.are.same({}, entries)
	end)

	it("uses last comment created_at for sorting", function()
		local map = {
			["a.lua"] = {
				[10] = {
					{ id = 1, body = "first", user = { login = "a" }, created_at = "2024-01-01T00:00:00Z" },
					{ id = 2, body = "reply", user = { login = "b" }, created_at = "2024-03-01T00:00:00Z" },
				},
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn)
		assert.are.equal("2024-03-01T00:00:00Z", entries[1].last_ts)
	end)

	it("labels pending review comments with [pending]", function()
		local map = {
			["a.lua"] = {
				[10] = {
					{
						id = 1,
						body = "submitted",
						user = { login = "alice" },
						created_at = "2024-01-01T00:00:00Z",
						pull_request_review_id = 100,
					},
				},
				[20] = {
					{
						id = 2,
						body = "my pending",
						user = { login = "bob" },
						created_at = "2024-02-01T00:00:00Z",
						pull_request_review_id = 200,
					},
				},
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn, 200)
		assert.are.equal(2, #entries)
		-- Find the pending entry
		local pending_entry, submitted_entry
		for _, e in ipairs(entries) do
			if e.is_pending then
				pending_entry = e
			else
				submitted_entry = e
			end
		end
		assert.is_not_nil(pending_entry)
		assert.is_not_nil(submitted_entry)
		assert.is_truthy(pending_entry.detail:find("%[pending%]"))
		assert.is_truthy(submitted_entry.detail:find("@alice"))
		assert.is_false(submitted_entry.is_pending)
	end)

	it("does not label as pending when pending_review_id is nil", function()
		local map = {
			["a.lua"] = {
				[10] = {
					{
						id = 1,
						body = "comment",
						user = { login = "alice" },
						created_at = "2024-01-01T00:00:00Z",
						pull_request_review_id = 100,
					},
				},
			},
		}
		local entries = data.build_comment_entries(map, "/repo", id_fn, nil)
		assert.are.equal(1, #entries)
		assert.is_false(entries[1].is_pending)
		assert.is_truthy(entries[1].detail:find("@alice"))
	end)
end)
