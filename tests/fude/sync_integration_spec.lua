local config = require("fude.config")
local sync = require("fude.comments.sync")
local helpers = require("tests.helpers")

describe("sync integration", function()
	before_each(function()
		config.setup({})
		helpers.mock_head_sha("abc123def456")
		-- Mock diff to prevent refresh_extmarks from failing
		helpers.mock_diff({})
	end)

	after_each(function()
		helpers.cleanup()
	end)

	describe("fetch_comments", function()
		it("populates state.comments and state.comment_map", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "fix this", in_reply_to_id = vim.NIL },
					{ id = 2, path = "foo.lua", line = 20, body = "also this", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.fetch_comments()

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

		it("does not change state on error", function()
			local done = false
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = function(_, callback)
					vim.schedule(function()
						callback("API error", nil)
						done = true
					end)
				end,
			})

			config.state.pr_number = 42
			config.state.active = true
			config.state.comments = {}

			sync.fetch_comments()

			helpers.wait_for(function()
				return done
			end)

			assert.are.equal(0, #config.state.comments)
		end)
	end)

	describe("fetch_pending_review", function()
		it("loads pending review from GitHub", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {
					{ id = 99, state = "PENDING" },
				},
				["api:repos/{owner}/{repo}/pulls/42/reviews/99/comments"] = {
					{ path = "bar.lua", line = 5, body = "pending comment", side = "RIGHT" },
				},
			})

			config.state.pr_number = 42
			config.state.active = true
			config.state.comments = {}

			sync.fetch_pending_review()

			local ok = helpers.wait_for(function()
				return config.state.pending_review_id ~= nil
			end)
			assert.is_true(ok, "Should have loaded pending review")
			assert.are.equal(99, config.state.pending_review_id)
		end)

		it("does nothing when no pending review exists", function()
			local done = false
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = function(_, callback)
					vim.schedule(function()
						callback(nil, { { id = 1, state = "APPROVED" } })
						done = true
					end)
				end,
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.fetch_pending_review()

			helpers.wait_for(function()
				return done
			end)

			assert.is_nil(config.state.pending_review_id)
		end)
	end)

	describe("submit_as_review", function()
		it("creates review and clears comment-type drafts", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = function(_, callback)
					vim.schedule(function()
						callback(nil, { id = 100 })
					end)
				end,
			})

			config.state.active = true
			config.state.pr_number = 42
			config.state.drafts = {
				["src/main.lua:5:5"] = { "comment body" },
				["reply:123"] = { "reply body" }, -- should be excluded
			}

			local cb_err, cb_excluded
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(err, excluded_count)
				cb_err = err
				cb_excluded = excluded_count
				cb_called = true
			end)

			helpers.wait_for(function()
				return cb_called
			end)

			assert.is_nil(cb_err)
			assert.are.equal(1, cb_excluded) -- reply is excluded
			-- Comment-type draft should be cleared
			assert.is_nil(config.state.drafts["src/main.lua:5:5"])
			-- Reply draft should remain
			assert.is_not_nil(config.state.drafts["reply:123"])
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(err, _)
				cb_err = err
				cb_called = true
			end)

			assert.is_true(cb_called)
			assert.are.equal("Not active", cb_err)
		end)

		it("reports excluded count for reply and issue_comment drafts", function()
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = function(_, callback)
					vim.schedule(function()
						callback(nil, { id = 101 })
					end)
				end,
			})

			config.state.active = true
			config.state.pr_number = 42
			config.state.drafts = {
				["reply:100"] = { "reply" },
				["issue_comment"] = { "issue comment" },
				["file.lua:1:1"] = { "normal comment" },
			}

			local cb_excluded
			local cb_called = false
			sync.submit_as_review("COMMENT", nil, function(_, excluded_count)
				cb_excluded = excluded_count
				cb_called = true
			end)

			helpers.wait_for(function()
				return cb_called
			end)

			assert.are.equal(2, cb_excluded) -- reply + issue_comment
		end)
	end)

	describe("submit_drafts", function()
		it("reports success and failure counts", function()
			local call_count = 0
			-- Mock individual gh API functions used by submit_drafts
			local gh = require("fude.gh")
			helpers.mock(gh, "create_comment", function(_, _, _, _, _, callback)
				call_count = call_count + 1
				vim.schedule(function()
					if call_count == 1 then
						callback(nil) -- first succeeds
					else
						callback("API error") -- second fails
					end
				end)
			end)

			config.state.active = true
			config.state.pr_number = 42
			config.state.drafts = {
				["file1.lua:1:1"] = { "comment 1" },
				["file2.lua:2:2"] = { "comment 2" },
			}

			local entries = {
				{
					draft_key = "file1.lua:1:1",
					draft_lines = { "comment 1" },
					parsed = { type = "comment", path = "file1.lua", start_line = 1, end_line = 1 },
				},
				{
					draft_key = "file2.lua:2:2",
					draft_lines = { "comment 2" },
					parsed = { type = "comment", path = "file2.lua", start_line = 2, end_line = 2 },
				},
			}

			local result_succeeded, result_failed
			local cb_called = false
			sync.submit_drafts(entries, function(succeeded, failed)
				result_succeeded = succeeded
				result_failed = failed
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok, "Callback should be called")
			assert.are.equal(1, result_succeeded)
			assert.are.equal(1, result_failed)
			-- First draft should be cleared, second should remain
			assert.is_nil(config.state.drafts["file1.lua:1:1"])
			assert.is_not_nil(config.state.drafts["file2.lua:2:2"])
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
	end)
end)
