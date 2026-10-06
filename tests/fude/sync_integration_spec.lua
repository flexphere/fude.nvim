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

		it("skips get_review_threads when outdated and resolved disabled and no pending review", function()
			config.setup({ outdated = { show = false }, resolved = { show = false } })

			local gh = require("fude.gh")
			local threads_called = 0
			helpers.mock(gh, "get_review_threads", function(_, callback)
				threads_called = threads_called + 1
				vim.schedule(function()
					callback(nil, {}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "comment" },
				},
			})

			config.state.pr_number = 42
			config.state.active = true
			-- Stale thread_map left over from a previously submitted pending review
			config.state.thread_map = { [99] = "STALE_THREAD" }

			local cb_called = false
			sync.load_comments(function()
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok)
			assert.are.equal(0, threads_called, "get_review_threads should not be called when all conditions are unmet")
			assert.are.same({}, config.state.thread_map, "thread_map should be cleared when no pending review")
		end)

		it("applies is_resolved to root comments and propagates to replies", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "get_review_threads", function(_, callback)
				vim.schedule(function()
					callback(nil, {
						[1] = { is_outdated = false, is_resolved = true, original_line = 10 },
						[3] = { is_outdated = false, is_resolved = false, original_line = 20 },
					}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "root", in_reply_to_id = vim.NIL },
					{ id = 2, path = "foo.lua", line = 10, body = "reply", in_reply_to_id = 1 },
					{ id = 3, path = "foo.lua", line = 20, body = "unresolved", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments")

			local by_id = {}
			for _, c in ipairs(config.state.comments) do
				by_id[c.id] = c
			end
			assert.is_true(by_id[1].is_resolved)
			assert.is_true(by_id[2].is_resolved, "reply should inherit is_resolved from its thread root")
			assert.is_nil(by_id[3].is_resolved)
		end)

		it("propagates is_resolved to siblings when the thread root was deleted", function()
			local gh = require("fude.gh")
			-- Root comment (id=1) was deleted on GitHub: GraphQL comments(first:1)
			-- returns the earliest surviving reply (id=2), so thread info is keyed
			-- by 2 while the REST replies still point at the deleted root (1).
			helpers.mock(gh, "get_review_threads", function(_, callback)
				vim.schedule(function()
					callback(nil, {
						[2] = { is_outdated = false, is_resolved = true, original_line = 10 },
					}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 2, path = "foo.lua", line = 10, body = "surviving reply", in_reply_to_id = 1 },
					{ id = 3, path = "foo.lua", line = 10, body = "sibling reply", in_reply_to_id = 1 },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments")

			local by_id = {}
			for _, c in ipairs(config.state.comments) do
				by_id[c.id] = c
			end
			assert.is_true(by_id[2].is_resolved)
			assert.is_true(by_id[3].is_resolved, "sibling should inherit is_resolved via the shared deleted-root id")
		end)

		it("does not mark unsubmitted pending replies on a resolved thread as resolved", function()
			local gh = require("fude.gh")
			helpers.mock(gh, "get_review_threads", function(_, callback)
				vim.schedule(function()
					callback(nil, {
						[1] = { is_outdated = false, is_resolved = true, original_line = 10 },
					}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {
					{ id = 99, state = "PENDING" },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "resolved root", in_reply_to_id = vim.NIL },
				},
				["api:repos/{owner}/{repo}/pulls/42/reviews/99/comments"] = {
					{
						id = 2,
						path = "foo.lua",
						line = 10,
						body = "unsubmitted pending reply",
						side = "RIGHT",
						in_reply_to_id = 1,
						pull_request_review_id = 99,
					},
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments")

			local by_id = {}
			for _, c in ipairs(config.state.comments) do
				by_id[c.id] = c
			end
			assert.is_true(by_id[1].is_resolved)
			assert.is_nil(by_id[2].is_resolved, "unsubmitted pending reply must not be marked resolved")
		end)

		it("keeps resolved comments in comment_map across reloads even when show_resolved is off", function()
			-- The resolved-visibility toggle only hides inline comment boxes at
			-- render time; comment_map always keeps resolved comments so navigation,
			-- the viewer, and the comment browser stay unaffected.
			local gh = require("fude.gh")
			helpers.mock(gh, "get_review_threads", function(_, callback)
				vim.schedule(function()
					callback(nil, {
						[1] = { is_outdated = false, is_resolved = true, original_line = 10 },
					}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "resolved", in_reply_to_id = vim.NIL },
					{ id = 2, path = "foo.lua", line = 20, body = "open", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true
			config.state.show_resolved = false -- user toggled resolved comments off

			local cb_called = false
			sync.load_comments(function()
				cb_called = true
			end)

			local ok = helpers.wait_for(function()
				return cb_called
			end)
			assert.is_true(ok)
			assert.are.equal(2, #config.state.comments, "resolved comments stay in state.comments")
			assert.is_not_nil(config.state.comment_map["foo.lua"][10], "resolved comment stays in comment_map")
			assert.is_not_nil(config.state.comment_map["foo.lua"][20])
		end)

		it("applies only is_resolved when outdated disabled but resolved enabled", function()
			config.setup({ outdated = { show = false } })

			local gh = require("fude.gh")
			local threads_called = 0
			helpers.mock(gh, "get_review_threads", function(_, callback)
				threads_called = threads_called + 1
				vim.schedule(function()
					callback(nil, {
						[1] = { is_outdated = true, is_resolved = true, original_line = 10 },
					}, {})
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "comment", in_reply_to_id = vim.NIL },
				},
			})

			config.state.pr_number = 42
			config.state.active = true

			sync.load_comments()

			local ok = helpers.wait_for(function()
				return #config.state.comments > 0
			end)
			assert.is_true(ok, "Should have fetched comments")
			assert.are.equal(1, threads_called, "get_review_threads should be called for resolved info")
			assert.is_true(config.state.comments[1].is_resolved)
			assert.is_nil(config.state.comments[1].is_outdated, "is_outdated should not be applied when outdated disabled")
		end)

		it("calls get_review_threads when pending review exists even with outdated disabled", function()
			config.setup({ outdated = { show = false } })

			local gh = require("fude.gh")
			local threads_called = 0
			helpers.mock(gh, "get_review_threads", function(_, callback)
				threads_called = threads_called + 1
				vim.schedule(function()
					callback(nil, {}, { [1] = "THREAD_X" })
				end)
			end)
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/reviews"] = {
					{ id = 99, state = "PENDING" },
				},
				["api:repos/{owner}/{repo}/pulls/42/comments"] = {
					{ id = 1, path = "foo.lua", line = 10, body = "comment" },
				},
				["api:repos/{owner}/{repo}/pulls/42/reviews/99/comments"] = {},
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
			assert.is_true(ok)
			assert.are.equal(1, threads_called, "get_review_threads should be called to populate thread_map")
			assert.are.equal("THREAD_X", config.state.thread_map[1])
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
			-- sync_pending_review fetches real comment IDs after creating the
			-- review; mock it so the test does not fall through to a real
			-- `gh api` subprocess (which times out the callback in CI).
			helpers.mock(gh, "get_review_comments", function(_, _, callback)
				vim.schedule(function()
					callback(nil, {})
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
	describe("toggle_resolved", function()
		local gh = require("fude.gh")
		local set_calls

		local function mock_threads(err, info_map, thread_map)
			helpers.mock(gh, "get_review_threads", function(_, callback)
				vim.schedule(function()
					callback(err, info_map, thread_map)
				end)
			end)
		end

		local function mock_set(err)
			helpers.mock(gh, "set_review_thread_resolved", function(thread_id, resolved, callback)
				table.insert(set_calls, { thread_id = thread_id, resolved = resolved })
				vim.schedule(function()
					callback(err, err == nil and {} or nil)
				end)
			end)
		end

		local function run_toggle(comment_id)
			local result = { called = false }
			sync.toggle_resolved(comment_id, function(err, resolved)
				result.called = true
				result.err = err
				result.resolved = resolved
			end)
			helpers.wait_for(function()
				return result.called
			end)
			return result
		end

		before_each(function()
			set_calls = {}
			helpers.mock_gh({ ["api:repos/{owner}/{repo}/pulls/42/comments"] = {} })
			config.state.active = true
			config.state.pr_number = 42
			config.state.comments = {
				{ id = 1, path = "a.lua", line = 1, body = "root" },
				{ id = 2, path = "a.lua", line = 1, body = "reply", in_reply_to_id = 1 },
			}
		end)

		it("resolves an unresolved thread looked up from a reply", function()
			mock_threads(nil, { [1] = { is_resolved = false } }, { [1] = "THREAD_1" })
			mock_set(nil)

			local result = run_toggle(2)

			assert.is_nil(result.err)
			assert.is_true(result.resolved)
			assert.are.same({ { thread_id = "THREAD_1", resolved = true } }, set_calls)
		end)

		it("unresolves a resolved thread", function()
			mock_threads(nil, { [1] = { is_resolved = true } }, { [1] = "THREAD_1" })
			mock_set(nil)

			local result = run_toggle(1)

			assert.is_false(result.resolved)
			assert.is_false(set_calls[1].resolved)
		end)

		it("reads the current state from the API even when resolved.show is false", function()
			-- is_resolved is never set on comments in this configuration, so the
			-- direction must come from the fetched thread info.
			config.setup({ resolved = { show = false } })
			config.state.active = true
			config.state.pr_number = 42
			config.state.comments = { { id = 1, path = "a.lua", line = 1, body = "root" } }
			mock_threads(nil, { [1] = { is_resolved = true } }, { [1] = "THREAD_1" })
			mock_set(nil)

			local result = run_toggle(1)

			assert.is_false(result.resolved)
		end)

		it("reports a thread lookup failure without calling the mutation", function()
			mock_threads("network down", nil, nil)
			mock_set(nil)

			local result = run_toggle(1)

			assert.truthy(result.err:find("network down", 1, true))
			assert.are.equal(0, #set_calls)
		end)

		it("reports a missing thread", function()
			mock_threads(nil, {}, {})
			mock_set(nil)

			local result = run_toggle(1)

			assert.truthy(result.err:find("Could not find the review thread", 1, true))
			assert.are.equal(0, #set_calls)
		end)

		it("passes a mutation error to the callback", function()
			mock_threads(nil, { [1] = { is_resolved = false } }, { [1] = "THREAD_1" })
			mock_set("Resource not accessible by integration")

			local result = run_toggle(1)

			assert.are.equal("Resource not accessible by integration", result.err)
			assert.is_nil(result.resolved)
		end)

		it("returns error when not active", function()
			config.state.active = false
			local result = run_toggle(1)
			assert.are.equal("Not active", result.err)
		end)

		it("refuses a second toggle while the first is in flight, then accepts one again", function()
			local finish_lookup
			helpers.mock(gh, "get_review_threads", function(_, callback)
				finish_lookup = function()
					callback(nil, { [1] = { is_resolved = false } }, { [1] = "THREAD_1" })
				end
			end)
			mock_set(nil)

			local first = { called = false }
			sync.toggle_resolved(1, function(err, resolved)
				first.called, first.err, first.resolved = true, err, resolved
			end)
			local second_err
			sync.toggle_resolved(1, function(err)
				second_err = err
			end)
			assert.are.equal("Another resolve is still in progress", second_err)

			finish_lookup()
			helpers.wait_for(function()
				return first.called
			end)
			assert.is_true(first.resolved)
			assert.are.equal(1, #set_calls)

			mock_threads(nil, { [1] = { is_resolved = true } }, { [1] = "THREAD_1" })
			local third = run_toggle(1)
			assert.is_nil(third.err)
			assert.is_false(third.resolved)
		end)

		for _, case in ipairs({
			{ name = "thread lookup", threads_err = "boom", set_err = nil },
			{ name = "successful mutation", threads_err = nil, set_err = nil },
			{ name = "failed mutation", threads_err = nil, set_err = "boom" },
		}) do
			it("drops a " .. case.name .. " response that arrives after the session was reset", function()
				local pending = {}
				helpers.mock(gh, "get_review_threads", function(_, callback)
					table.insert(pending, function()
						callback(case.threads_err, { [1] = { is_resolved = false } }, { [1] = "THREAD_1" })
					end)
				end)
				helpers.mock(gh, "set_review_thread_resolved", function(_, _, callback)
					table.insert(pending, function()
						callback(case.set_err, nil)
					end)
				end)

				local called = false
				sync.toggle_resolved(1, function()
					called = true
				end)
				if case.threads_err == nil then
					-- Let the lookup land so the mutation is the stale response.
					table.remove(pending, 1)()
				end
				config.reset_state()
				table.remove(pending, 1)()

				assert.is_false(called)
			end)
		end
	end)

	describe("comments.toggle_resolve (github)", function()
		local comments = require("fude.comments")

		before_each(function()
			config.state.active = true
			config.state.review_mode = "github"
			config.state.pr_number = 42
			config.state.comments = {
				{ id = 1, path = "a.lua", line = 1, body = "root" },
				{ id = 2, path = "a.lua", line = 1, body = "reply", in_reply_to_id = 1 },
			}
			config.state.comment_map = require("fude.comments.data").build_comment_map(config.state.comments)
		end)

		it("delegates the given comment to the GitHub backend", function()
			local seen
			helpers.mock(sync, "toggle_resolved", function(comment_id, callback)
				seen = comment_id
				callback(nil, true)
			end)

			comments.toggle_resolve(2)

			assert.are.equal(2, seen)
		end)

		it("targets the first comment on the current line when no id is given", function()
			local buf = helpers.create_buf({ "x" }, "/tmp/fude_resolve/a.lua")
			vim.api.nvim_win_set_buf(0, buf)
			helpers.mock_diff({ ["fude_resolve/a.lua"] = "a.lua" })
			local seen
			helpers.mock(sync, "toggle_resolved", function(comment_id, callback)
				seen = comment_id
				callback(nil, false)
			end)

			comments.toggle_resolve()

			assert.are.equal(1, seen)
		end)

		it("refuses a thread started in the pending review", function()
			config.state.pending_review_id = 77
			config.state.comments[1].pull_request_review_id = 77
			config.state.comment_map = require("fude.comments.data").build_comment_map(config.state.comments)
			local called = false
			helpers.mock(sync, "toggle_resolved", function()
				called = true
			end)

			comments.toggle_resolve(2)

			assert.is_false(called)
		end)

		it("refuses a pending thread before pending_review_id arrives", function()
			config.state.pending_review_id = nil
			config.state.pending_comments = { ["a.lua:1:1"] = { id = 1, body = "root" } }
			local called = false
			helpers.mock(sync, "toggle_resolved", function()
				called = true
			end)

			comments.toggle_resolve(1)

			assert.is_false(called)
		end)
	end)

	describe("comment viewer R key", function()
		it("toggles the thread of the comment under the cursor and shows the hint", function()
			local ui = require("fude.ui")
			local comments = require("fude.comments")
			local seen
			helpers.mock(comments, "toggle_resolve", function(comment_id)
				seen = comment_id
			end)

			ui.show_comments_float({
				{ id = 1, body = "root", user = { login = "a" }, created_at = "2026-01-01T00:00:00Z" },
				{ id = 2, body = "reply", user = { login = "b" }, created_at = "2026-01-02T00:00:00Z" },
			})
			local win = vim.api.nvim_get_current_win()
			local footer = vim.api.nvim_win_get_config(win).footer
			local footer_text = type(footer) == "table" and footer[1][1] or footer
			assert.truthy(footer_text:find("R resolve", 1, true))

			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			local map = vim.fn.maparg("R", "n", false, true)
			map.callback()

			assert.are.equal(1, seen)
			assert.is_false(vim.api.nvim_win_is_valid(win))
		end)

		it("ignores a comment without an id instead of falling back to the source line", function()
			local ui = require("fude.ui")
			local comments = require("fude.comments")
			local called = false
			helpers.mock(comments, "toggle_resolve", function()
				called = true
			end)

			ui.show_comments_float({
				{ body = "synthetic pending", user = { login = "a" }, created_at = "2026-01-01T00:00:00Z" },
			})
			local win = vim.api.nvim_get_current_win()
			vim.fn.maparg("R", "n", false, true).callback()

			assert.is_false(called)
			assert.is_true(vim.api.nvim_win_is_valid(win))
		end)
	end)

	describe("create_single_comment", function()
		-- POST and GET share the same gh args prefix, so dispatch on --method.
		local function mock_comments_endpoint(post_resp)
			local calls = { post = nil, get = 0 }
			helpers.mock_gh({
				["api:repos/{owner}/{repo}/pulls/42/comments"] = function(args, callback)
					local is_post = vim.tbl_contains(args, "POST")
					if is_post then
						calls.post = args
					else
						calls.get = calls.get + 1
					end
					vim.schedule(function()
						if is_post and type(post_resp) == "string" then
							callback(post_resp, nil)
						else
							callback(nil, is_post and { id = 99 } or {})
						end
					end)
				end,
			})
			return calls
		end

		local function arg_values(args)
			local set = {}
			for _, a in ipairs(args) do
				set[a] = true
			end
			return set
		end

		before_each(function()
			config.state.active = true
			config.state.pr_number = 42
		end)

		it("posts a single-line comment on HEAD and refreshes comments", function()
			local calls = mock_comments_endpoint()
			local cb_called, cb_err = false, "unset"
			sync.create_single_comment("foo.lua", 10, 10, "looks good", function(err)
				cb_called = true
				cb_err = err
			end)

			assert.is_true(helpers.wait_for(function()
				return cb_called and calls.get > 0
			end))
			assert.is_nil(cb_err)
			local v = arg_values(calls.post)
			assert.is_true(v["body=looks good"])
			assert.is_true(v["commit_id=abc123def456"])
			assert.is_true(v["path=foo.lua"])
			assert.is_true(v["line=10"])
			assert.is_true(v["side=RIGHT"])
			assert.is_nil(v["start_side=RIGHT"])
		end)

		it("posts a range comment with start_line and start_side", function()
			local calls = mock_comments_endpoint()
			local cb_called = false
			sync.create_single_comment("foo.lua", 5, 8, "range", function()
				cb_called = true
			end)

			assert.is_true(helpers.wait_for(function()
				return cb_called
			end))
			local v = arg_values(calls.post)
			assert.is_true(v["start_line=5"])
			assert.is_true(v["line=8"])
			assert.is_true(v["start_side=RIGHT"])
		end)

		it("fails without calling the API while a pending review exists", function()
			local calls = mock_comments_endpoint()
			config.state.pending_review_id = 7

			local cb_err
			sync.create_single_comment("foo.lua", 10, 10, "body", function(err)
				cb_err = err
			end)

			assert.is_not_nil(cb_err)
			assert.is_not_nil(cb_err:find("pending review", 1, true))
			assert.is_nil(calls.post)
		end)

		it("still reports success but skips the refresh when the session changed", function()
			local calls = mock_comments_endpoint()
			local cb_called, cb_err = false, "unset"
			sync.create_single_comment("foo.lua", 10, 10, "body", function(err)
				cb_called = true
				cb_err = err
			end)
			-- Session stopped and restarted before the POST response arrives.
			config.reset_state()
			config.state.active = true
			config.state.pr_number = 42

			assert.is_true(helpers.wait_for(function()
				return cb_called
			end))
			assert.is_nil(cb_err)
			vim.wait(100, function()
				return calls.get > 0
			end)
			assert.are.equal(0, calls.get)
		end)

		it("fails while the first pending review sync is still in flight", function()
			local calls = mock_comments_endpoint()
			-- pending_comments is set before sync_pending_review assigns pending_review_id.
			config.state.pending_comments = { ["foo.lua:1:1"] = { body = "queued" } }

			local cb_err
			sync.create_single_comment("foo.lua", 10, 10, "body", function(err)
				cb_err = err
			end)

			assert.is_not_nil(cb_err)
			assert.is_nil(calls.post)
		end)

		it("returns error when not active", function()
			config.state.active = false

			local cb_err
			sync.create_single_comment("foo.lua", 10, 10, "body", function(err)
				cb_err = err
			end)

			assert.are.equal("Not active", cb_err)
		end)

		it("passes API error to callback without refreshing", function()
			local calls = mock_comments_endpoint("Validation Failed")
			local cb_called, cb_err = false, nil
			sync.create_single_comment("foo.lua", 10, 10, "body", function(err)
				cb_called = true
				cb_err = err
			end)

			assert.is_true(helpers.wait_for(function()
				return cb_called
			end))
			assert.are.equal("Validation Failed", cb_err)
			assert.are.equal(0, calls.get)
		end)
	end)
	describe("fetch_pr_level_comments", function()
		local ISSUE_KEY = "api:repos/{owner}/{repo}/issues/42/comments"
		local REVIEWS_KEY = "api:repos/{owner}/{repo}/pulls/42/reviews"

		local function fetch()
			local got
			sync.fetch_pr_level_comments(42, function(pr_comments)
				got = pr_comments
			end)
			assert.is_true(helpers.wait_for(function()
				return got ~= nil
			end))
			return got
		end

		it("merges issue comments with submitted review bodies, oldest first", function()
			helpers.mock_gh({
				[ISSUE_KEY] = {
					{ id = 10, body = "issue", user = { login = "bob" }, created_at = "2024-01-02T00:00:00Z" },
				},
				[REVIEWS_KEY] = {
					{
						id = 5,
						state = "APPROVED",
						body = "LGTM",
						user = { login = "alice" },
						submitted_at = "2024-01-03T00:00:00Z",
					},
					{ id = 6, state = "COMMENTED", body = "", submitted_at = "2024-01-04T00:00:00Z" },
				},
			})
			local got = fetch()
			assert.are.same({ 10, 5 }, { got[1].id, got[2].id })
			assert.is_true(got[2].is_review_summary)
		end)

		it("falls back to issue comments alone when the reviews listing fails", function()
			helpers.mock_gh({
				[ISSUE_KEY] = { { id = 10, body = "issue", created_at = "2024-01-02T00:00:00Z" } },
				[REVIEWS_KEY] = "API error",
			})
			local got = fetch()
			assert.are.equal(1, #got)
			assert.are.equal(10, got[1].id)
		end)

		it("still shows review bodies when the issue comments listing fails", function()
			helpers.mock_gh({
				[ISSUE_KEY] = "API error",
				[REVIEWS_KEY] = { { id = 5, state = "APPROVED", body = "LGTM", submitted_at = "2024-01-03T00:00:00Z" } },
			})
			local got = fetch()
			assert.are.equal(1, #got)
			assert.are.equal(5, got[1].id)
		end)

		it("waits for both listings before calling back once", function()
			local release_issue
			local calls = 0
			helpers.mock_gh({
				[ISSUE_KEY] = function(_, callback)
					release_issue = function()
						callback(nil, { { id = 10, body = "issue", created_at = "2024-01-02T00:00:00Z" } })
					end
				end,
				[REVIEWS_KEY] = { { id = 5, state = "APPROVED", body = "LGTM", submitted_at = "2024-01-03T00:00:00Z" } },
			})
			local got
			sync.fetch_pr_level_comments(42, function(pr_comments)
				calls = calls + 1
				got = pr_comments
			end)
			assert.is_true(helpers.wait_for(function()
				return release_issue ~= nil
			end))
			-- reviews already answered; the callback must not fire yet
			assert.is_false(vim.wait(100, function()
				return got ~= nil
			end))
			release_issue()
			assert.is_true(helpers.wait_for(function()
				return got ~= nil
			end))
			assert.are.equal(1, calls)
			assert.are.equal(2, #got)
		end)

		it("yields an empty list without calling gh when pr_number is nil", function()
			local called = false
			helpers.mock(require("fude.gh"), "run_json", function()
				called = true
			end)
			local got
			sync.fetch_pr_level_comments(nil, function(pr_comments)
				got = pr_comments
			end)
			assert.are.same({}, got)
			assert.is_false(called)
		end)
	end)
end)
