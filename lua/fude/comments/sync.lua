local M = {}
local config = require("fude.config")
local gh = require("fude.gh")
local data = require("fude.comments.data")

--- Apply outdated info from outdated_map to comments.
--- Note: We intentionally do NOT set original_line here to prevent outdated comments
--- from appearing in comment_map (and thus being displayed at wrong positions in the editor).
--- Outdated comments are displayed only in FudeReviewListComments.
--- @param comments table[] array of comment objects
--- @param outdated_map table<number, table> { [databaseId] = { is_outdated, original_line } }
local function apply_outdated_info(comments, outdated_map)
	for _, c in ipairs(comments) do
		local info = outdated_map[c.id]
		if info and info.is_outdated then
			c.is_outdated = true
		end
	end
end

--- Fetch all PR review comments and build the lookup map.
--- GET /pulls/{pr}/comments does not include pending review comments,
--- so when a pending review exists, also fetches from the review-specific endpoint
--- and builds pending_comments from the same data.
--- Also fetches outdated info via GraphQL and merges it into comments.
--- @param callback fun()|nil optional callback invoked after comments are applied
local function fetch_comments(callback)
	local state = config.state
	if not state.pr_number then
		if callback then
			callback()
		end
		return
	end

	local function apply(comments)
		state.comments = comments
		state.comment_map = data.build_comment_map(comments)
		require("fude.ui").refresh_extmarks()
		vim.notify(string.format("fude.nvim: Loaded %d comments", #comments), vim.log.levels.INFO)
		if callback then
			callback()
		end
	end

	local function fetch_outdated_and_apply(comments)
		-- Fetch outdated info via GraphQL
		gh.get_review_threads(state.pr_number, function(outdated_err, outdated_map)
			if not outdated_err and outdated_map then
				state.outdated_map = outdated_map
				apply_outdated_info(comments, outdated_map)
			else
				state.outdated_map = {}
				-- Continue without outdated info on error (fallback)
				if outdated_err then
					vim.notify("fude.nvim: Failed to fetch outdated info: " .. outdated_err, vim.log.levels.DEBUG)
				end
			end
			apply(comments)
		end)
	end

	gh.get_pr_comments(state.pr_number, function(err, comments)
		if err then
			vim.notify("fude.nvim: Failed to fetch comments: " .. err, vim.log.levels.WARN)
			if callback then
				callback()
			end
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
				fetch_outdated_and_apply(comments)
			end)
		else
			state.pending_comments = {}
			fetch_outdated_and_apply(comments)
		end
	end)
end

--- Submit pending review or create a new review with event and body.
--- If a pending review exists on GitHub, submits it (with or without comments).
--- Otherwise, creates a new review. APPROVE works without body; COMMENT and
--- REQUEST_CHANGES require a body (GitHub API constraint).
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param body string|nil review body (optional for APPROVE, required for others)
--- @param callback fun(err: string|nil)
function M.submit_as_review(event, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	-- If we have a pending review on GitHub, submit it
	if state.pending_review_id then
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

	-- No pending review on GitHub — create a new review.
	-- APPROVE works without body; COMMENT/REQUEST_CHANGES require body.
	local has_body = body and body ~= ""
	if not has_body and event ~= "APPROVE" then
		callback("Review body is required for " .. event)
		return
	end

	local sha, sha_err = gh.get_head_sha()
	if not sha then
		callback(sha_err or "Failed to get HEAD SHA")
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
--- @param callback fun()|nil optional callback invoked after comments are loaded
function M.load_comments(callback)
	local state = config.state
	if not state.pr_number then
		if callback then
			callback()
		end
		return
	end

	gh.get_reviews(state.pr_number, function(err, reviews)
		if err then
			vim.notify("fude.nvim: Failed to fetch reviews: " .. err, vim.log.levels.DEBUG)
			-- Still fetch comments even if reviews fail
			fetch_comments(callback)
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
		else
			state.pending_review_id = nil
			state.pending_comments = {}
		end

		fetch_comments(callback)
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

--- Edit a submitted review comment on GitHub.
--- @param comment_id number target comment ID
--- @param body string new comment body
--- @param callback fun(err: string|nil)
function M.edit_comment(comment_id, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	gh.update_comment(comment_id, body, function(err, _)
		if err then
			callback(err)
			return
		end
		callback(nil)
		fetch_comments()
	end)
end

--- Delete a submitted review comment on GitHub.
--- @param comment_id number target comment ID
--- @param callback fun(err: string|nil)
function M.delete_comment(comment_id, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active")
		return
	end

	gh.delete_comment(comment_id, function(err)
		if err then
			callback(err)
			return
		end
		callback(nil)
		fetch_comments()
	end)
end

return M
