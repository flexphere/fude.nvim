local M = {}
local config = require("fude.config")
local gh = require("fude.gh")
local data = require("fude.comments.data")

--- Fetch all PR review comments and build the lookup map.
--- GET /pulls/{pr}/comments does not include pending review comments,
--- so when a pending review exists, also fetches from the review-specific endpoint
--- and builds pending_comments from the same data.
local function fetch_comments()
	local state = config.state
	if not state.pr_number then
		return
	end

	local function apply(comments)
		state.comments = comments
		state.comment_map = data.build_comment_map(comments)
		require("fude.ui").refresh_extmarks()
		vim.notify(string.format("fude.nvim: Loaded %d comments", #comments), vim.log.levels.INFO)
	end

	gh.get_pr_comments(state.pr_number, function(err, comments)
		if err then
			vim.notify("fude.nvim: Failed to fetch comments: " .. err, vim.log.levels.WARN)
			return
		end

		comments = comments or {}

		if state.pending_review_id then
			gh.get_review_comments(state.pr_number, state.pending_review_id, function(rev_err, rev_comments)
				if not rev_err and rev_comments then
					-- Review-specific endpoint returns `position` instead of `line`.
					-- Convert to `line` using diff_hunk so build_comment_map can index them.
					for _, c in ipairs(rev_comments) do
						if not c.line and not c.original_line then
							c.line = data.line_from_diff_hunk(c.diff_hunk, c.position)
						end
					end
					vim.list_extend(comments, rev_comments)
					-- Also build pending_comments from the same data
					state.pending_comments = data.build_pending_comments_from_review(rev_comments)
				else
					state.pending_comments = {}
				end
				apply(comments)
			end)
		else
			state.pending_comments = {}
			apply(comments)
		end
	end)
end

--- Submit pending review or create a new review with event and body.
--- If pending_comments exist (already on GitHub), submits the existing pending review.
--- Otherwise, creates a new review with just event and body (for APPROVE/REQUEST_CHANGES).
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param body string|nil review body (optional)
--- @param callback fun(err: string|nil)
function M.submit_as_review(event, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	-- If we have a pending review on GitHub, submit it
	if state.pending_review_id and vim.tbl_count(state.pending_comments) > 0 then
		gh.submit_review(state.pr_number, state.pending_review_id, event, body, function(err, _)
			if err then
				callback(err)
				return
			end

			-- Clear pending state
			state.pending_review_id = nil
			state.pending_comments = {}

			require("fude.ui").refresh_extmarks()
			fetch_comments()

			callback(nil)
		end)
		return
	end

	-- No pending review on GitHub, create a new review (for APPROVE/REQUEST_CHANGES with body)
	local sha, sha_err = gh.get_head_sha()
	if not sha then
		callback(sha_err or "Failed to get HEAD SHA")
		return
	end

	if not body or body == "" then
		callback("No pending review to submit")
		return
	end

	gh.create_review(state.pr_number, sha, body, event, {}, function(err, _)
		if err then
			callback(err)
			return
		end

		fetch_comments()

		callback(nil)
	end)
end

--- Load all comment data: detect pending review, then fetch comments.
--- This is the main entry point for initializing comment state on start.
--- For refreshing after mutations (submit, reply, sync), use fetch_comments directly.
function M.load_comments()
	local state = config.state
	if not state.pr_number then
		return
	end

	gh.get_reviews(state.pr_number, function(err, reviews)
		if err then
			vim.notify("fude.nvim: Failed to fetch reviews: " .. err, vim.log.levels.DEBUG)
			-- Still fetch comments even if reviews fail
			fetch_comments()
			return
		end

		-- Find pending review for current user
		local pending_review = nil
		for _, review in ipairs(reviews or {}) do
			if review.state == "PENDING" then
				pending_review = review
				break
			end
		end

		if pending_review then
			state.pending_review_id = pending_review.id
		end

		fetch_comments()
	end)
end

--- Sync pending comments to GitHub as a pending review.
--- This will delete any existing pending review and create a new one with all comments.
--- @param callback fun(err: string|nil)
function M.sync_pending_review(callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	local sha, sha_err = gh.get_head_sha()
	if not sha then
		callback(sha_err or "Failed to get HEAD SHA")
		return
	end

	local comments_array = data.pending_comments_to_array(state.pending_comments)

	-- If no pending comments, just delete any existing pending review
	if #comments_array == 0 then
		if state.pending_review_id then
			gh.delete_review(state.pr_number, state.pending_review_id, function(err)
				if not err then
					state.pending_review_id = nil
				end
				callback(err)
			end)
		else
			callback(nil)
		end
		return
	end

	local function create_new_review()
		gh.create_pending_review(state.pr_number, sha, comments_array, function(err, review_data)
			if err then
				callback(err)
				return
			end
			state.pending_review_id = review_data and review_data.id

			callback(nil)

			-- fetch_comments also fetches pending review comments when pending_review_id is set
			fetch_comments()
		end)
	end

	-- If there's an existing pending review, delete it first
	if state.pending_review_id then
		gh.delete_review(state.pr_number, state.pending_review_id, function(err)
			if err then
				-- Ignore delete error (review might already be gone)
				vim.notify("fude.nvim: Note: " .. err, vim.log.levels.DEBUG)
			end
			state.pending_review_id = nil
			create_new_review()
		end)
	else
		create_new_review()
	end
end

--- Reply to a review comment on GitHub.
--- @param comment_id number target comment ID (must be top-level)
--- @param body string reply body
--- @param callback fun(err: string|nil)
function M.reply_to_comment(comment_id, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	gh.reply_to_comment(state.pr_number, comment_id, body, function(err, _)
		if err then
			callback(err)
			return
		end
		callback(nil)
		fetch_comments()
	end)
end

return M
