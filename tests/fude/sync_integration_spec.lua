local config = require("fude.config")
local sync = require("fude.comments.sync")
local helpers = require("tests.helpers")

describe("sync integration", function()
	before_each(function()
		config.setup({})
		helpers.mock_head_sha("abc123def456")
		-- Mock diff to prevent refresh_extmarks from failing
		helpers.mock_diff({})
		-- Mock get_review_threads to return empty outdated/thread maps (avoid repo owner lookup)
		local gh = require("fude.gh")
		helpers.mock(gh, "get_review_threads", function(_, callback)
			vim.schedule(function()
				callback(nil, {}, {})
			end)
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	describe("load_comments", function()
		it("populates state.comments and state.comment_map without pending review", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "fix this", in_reply_to_id = vim.NIL },
					{ id = 2, path = "foo.lua", line = 20, body = "also this", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments")
			assert.are.equal(2, #config.state.comments)

			-- Check comment_map structure
			assert.is_not_nil(config.state.comment_map["foo.lua"])
			assert.is_not_nil(config.state.comment_map["foo.lua"][10])
			assert.is_not_nil(config.state.comment_map["foo.lua"][20])
		end)

		it("loads pending review and pending comments in one flow", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {
					{ id = 99, state = "PENDING" },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "submitted", pull_request_review_id = 50 },
				},
				["api:repos/{owner}/{repo}/pulls/42/reviews/99/comments"] = {
					{ path = "bar.lua", line = 5, body = "pending comment", side = "RIGHT", start_line = 5 },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return config.state.pending_review_id ~= nil and #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have loaded pending review and comments")
			assert.are.equal(99, config.state.pending_review_id)

			-- comment_map should include both submitted and pending comments
			assert.is_not_nil(config.state.comment_map["foo.lua"])
			assert.is_not_nil(config.state.comment_map["foo.lua"][10])
			assert.is_not_nil(config.state.comment_map["bar.lua"])
			assert.is_not_nil(config.state.comment_map["bar.lua"][5])

			-- pending_comments should be built from review comments
			assert.are.equal(1, vim.tbl_count(config.state.pending_comments))
		end)

		it("does not set pending_review_id when no pending review exists", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {
					{ id = 1, state = "APPROVED" },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return config.state.comment_map ~= nil
			end)
			assert.is_true(ok, "Should have fetched comments")
			assert.is_nil(config.state.pending_review_id)
		end)

		it("fetches comments even when reviews API fails", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = "API error",
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "comment" },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments despite reviews error")
			assert.are.equal(1, #config.state.comments)
		end)

		it("does not change state on comments API error", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = "API error",
			})

			config.state.pr_number = 42
			config.state.active = true
			config.state.comments = {}

			sync.load_comments()

			-- Wait a bit for the async callback
			vim.wait(200, function()
				return false
			end, 10)

			assert.are.equal(0, #config.state.comments)
		end)

		it("invokes callback after comments are loaded", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "fix this", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			local cb_called = false
			sync.load_comments(function()
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called after comments loaded")
			assert.are.equal(1, #config.state.comments)
		end)

		it("invokes callback even when pr_number is nil", function()
			config.state.pr_number = nil

			local cb_called = false
			sync.load_comments(function()
				cb_called = true
			end)

			assert.is_true(cb_called)
		end)

		it("invokes callback on comments API error", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = "API error",
			})

			config.state.pr_number = 42
			config.state.active = true

			local cb_called = false
			sync.load_comments(function()
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called even on error")
		end)
	end)

	describe("submit_as_review", function()
		it("submits pending review and clears pending state", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "submit_review", function(_, _, _, _, callback)
				vim.schedule(function()
					callback(nil, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.active = true
			config.state.pr_number = 42
			config.state.pending_review_id = 100
			config.state.pending_comments = {
				["src/main.lua:5:5"] = { path = "src/main.lua", body = "comment", line = 5, side = "RIGHT" },
			}

			local cb_err
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")

			assert.is_nil(cb_err)
			assert.is_nil(config.state.pending_review_id)
			assert.are.same({}, config.state.pending_comments)
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			assert.is_true(cb_called)
			assert.are.equal("Not active", cb_err)
		end)

		it("creates review with body when no pending review exists", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = function(_, callback)
					vim.schedule(function()
						callback(nil, { id = 102 })
					end)
				end,
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.submit_as_review("APPROVE", "LGTM", function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.is_nil(cb_err)
		end)

		it("returns error when COMMENT without body and no pending review", function()
			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			assert.is_true(cb_called)
			assert.are.equal("Review body is required for COMMENT", cb_err)
		end)

		it("returns error when REQUEST_CHANGES without body and no pending review", function()
			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.submit_as_review("REQUEST_CHANGES", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			assert.is_true(cb_called)
			assert.are.equal("Review body is required for REQUEST_CHANGES", cb_err)
		end)

		it("allows APPROVE without body and no pending review", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = function(_, callback)
					vim.schedule(function()
						callback(nil, { id = 103 })
					end)
				end,
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.submit_as_review("APPROVE", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.is_nil(cb_err)
		end)

		it("submits pending review with no comments", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "submit_review", function(_, _, _, _, callback)
				vim.schedule(function()
					callback(nil, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.active = true
			config.state.pr_number = 42
			config.state.pending_review_id = 100
			config.state.pending_comments = {}

			local cb_err
			local cb_called = false
			sync.submit_as_review("APPROVE", nil, function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")

			assert.is_nil(cb_err)
			assert.is_nil(config.state.pending_review_id)
			assert.are.same({}, config.state.pending_comments)
		end)
	end)

	describe("sync_pending_review", function()
		it("creates a pending review on GitHub", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "create_pending_review", function(_, _, _, callback)
				vim.schedule(function()
					callback(nil, { id = 200 })
				end)
			end)

			config.state.active = true
			config.state.pr_number = 42
			config.state.pending_comments = {
				["file.lua:1:5"] = { path = "file.lua", body = "comment", line = 5, side = "RIGHT" },
			}

			local cb_err
			local cb_called = false
			sync.sync_pending_review(function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.is_nil(cb_err)
			assert.are.equal(200, config.state.pending_review_id)
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			sync.sync_pending_review(function(err)
				cb_err = err
			end)

			assert.are.equal("Not active", cb_err)
		end)

		it("immediately updates comment_map with real IDs after creating review", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "create_pending_review", function(_, _, _, callback)
				vim.schedule(function()
					callback(nil, { id = 300 })
				end)
			end)
			helpers.mock(gh, "get_review_comments", function(_, _, callback)
				vim.schedule(function()
					callback(nil, {
						{
							id = 501,
							path = "new.lua",
							line = 5,
							body = "pending comment",
							side = "RIGHT",
							start_line = 5,
							pull_request_review_id = 300,
						},
					})
				end)
			end)

			config.state.active = true
			config.state.pr_number = 42
			config.state.comments = {
				{ id = 1, path = "existing.lua", line = 10, body = "submitted", pull_request_review_id = 50 },
			}
			config.state.comment_map = require("fude.comments.data").build_comment_map(config.state.comments)
			config.state.pending_comments = {
				["new.lua:5:5"] = { path = "new.lua", body = "pending comment", line = 5, side = "RIGHT" },
			}
			config.state.github_user = "testuser"

			local cb_called = false
			sync.sync_pending_review(function(err)
				cb_called = true
				assert.is_nil(err)
				-- At callback time, comment_map should already contain the pending comment
				assert.is_not_nil(config.state.comment_map["new.lua"])
				assert.is_not_nil(config.state.comment_map["new.lua"][5])
				assert.are.equal("pending comment", config.state.comment_map["new.lua"][5][1].body)
				assert.are.equal(300, config.state.comment_map["new.lua"][5][1].pull_request_review_id)
				-- Pending comment should have real ID from get_review_comments
				assert.are.equal(501, config.state.comment_map["new.lua"][5][1].id)
				-- Existing submitted comment should still be present
				assert.is_not_nil(config.state.comment_map["existing.lua"])
				assert.is_not_nil(config.state.comment_map["existing.lua"][10])
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
		end)
	end)

	describe("edit_comment", function()
		it("calls update_comment API and refreshes comments", function()
			local gh = require("fude.gh")
			local update_called = false
			helpers.mock(gh, "update_comment", function(cid, body, callback)
				update_called = true
				assert.are.equal(1, cid)
				assert.are.equal("updated body", body)
				vim.schedule(function()
					callback(nil, { id = 1, body = "updated body" })
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "updated body" },
				},
			})

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.edit_comment(1, "updated body", function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.is_nil(cb_err)
			assert.is_true(update_called)
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			sync.edit_comment(1, "body", function(err)
				cb_err = err
			end)

			assert.are.equal("Not active", cb_err)
		end)

		it("passes API error to callback", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "update_comment", function(_, _, callback)
				vim.schedule(function()
					callback("Not found", nil)
				end)
			end)

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.edit_comment(1, "body", function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok)
			assert.are.equal("Not found", cb_err)
		end)
	end)

	describe("delete_comment", function()
		it("calls delete_comment API and refreshes comments", function()
			local gh = require("fude.gh")
			local delete_called = false
			helpers.mock(gh, "delete_comment", function(cid, callback)
				delete_called = true
				assert.are.equal(1, cid)
				vim.schedule(function()
					callback(nil)
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {},
			})

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.delete_comment(1, function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.is_nil(cb_err)
			assert.is_true(delete_called)
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			sync.delete_comment(1, function(err)
				cb_err = err
			end)

			assert.are.equal("Not active", cb_err)
		end)

		it("passes API error to callback", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "delete_comment", function(_, callback)
				vim.schedule(function()
					callback("Forbidden")
				end)
			end)

			config.state.active = true
			config.state.pr_number = 42

			local cb_err
			local cb_called = false
			sync.delete_comment(1, function(err)
				cb_err = err
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok)
			assert.are.equal("Forbidden", cb_err)
		end)
	end)
end)
