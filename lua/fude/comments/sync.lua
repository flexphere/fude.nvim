local M = {}
local config = require("fude.config")
local gh = require("fude.gh")
local data = require("fude.comments.data")

--- Submit drafts as a single review.
--- If pending_comments exist (already on GitHub), submits the existing pending review.
--- Otherwise, creates a new review with local drafts.
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param body string|nil review body (optional)
--- @param callback fun(err: string|nil, excluded_count: number)
function M.submit_as_review(event, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active", 0)
		return
	end

	-- Count excluded drafts (replies and issue_comments cannot be submitted as review)
	local result = data.build_review_comments(state.drafts)
	local excluded_count = vim.tbl_count(result.excluded)

	-- If we have a pending review on GitHub, submit it
	if state.pending_review_id and vim.tbl_count(state.pending_comments) > 0 then
		gh.submit_review(state.pr_number, state.pending_review_id, event, body, function(err, _)
			if err then
				callback(err, excluded_count)
				return
			end

			-- Clear pending state
			state.pending_review_id = nil
			state.pending_comments = {}

			-- Also clear local drafts that were comment type
			for key, _ in pairs(state.drafts) do
				local parsed = data.parse_draft_key(key)
				if parsed and parsed.type == "comment" then
					state.drafts[key] = nil
				end
			end

			vim.schedule(function()
				require("fude.ui").refresh_extmarks()
			end)
			M.fetch_comments()

			callback(nil, excluded_count)
		end)
		return
	end

	-- No pending review on GitHub, check local drafts
	local sha, sha_err = gh.get_head_sha()
	if not sha then
		callback(sha_err or "Failed to get HEAD SHA", 0)
		return
	end

	if #result.comments == 0 and (not body or body == "") then
		callback("No comments to submit", excluded_count)
		return
	end

	gh.create_review(state.pr_number, sha, body, event, result.comments, function(err, _)
		if err then
			callback(err, excluded_count)
			return
		end

		-- Clear submitted drafts (only "comment" type)
		for key, _ in pairs(state.drafts) do
			local parsed = data.parse_draft_key(key)
			if parsed and parsed.type == "comment" then
				state.drafts[key] = nil
			end
		end

		vim.schedule(function()
			require("fude.ui").refresh_extmarks()
		end)
		M.fetch_comments()

		callback(nil, excluded_count)
	end)
end

--- Submit multiple draft comments sequentially.
--- @param draft_entries table[] { draft_key, draft_lines, parsed }
--- @param callback fun(succeeded: number, failed: number)
function M.submit_drafts(draft_entries, callback)
	local sha, sha_err = gh.get_head_sha()
	if not sha then
		vim.notify("fude.nvim: " .. (sha_err or "Failed to get HEAD SHA"), vim.log.levels.ERROR)
		callback(0, #draft_entries)
		return
	end

	local state = config.state
	local idx = 0
	local succeeded, failed = 0, 0

	local function submit_next()
		idx = idx + 1
		if idx > #draft_entries then
			callback(succeeded, failed)
			return
		end
		local entry = draft_entries[idx]
		local entry_body = table.concat(entry.draft_lines, "\n")
		local req = data.build_submit_request(entry.parsed, entry_body, state.pr_number, sha)

		local api_fn
		if req.type == "issue_comment" then
			api_fn = gh.create_issue_comment
		elseif req.type == "reply" then
			api_fn = gh.reply_to_comment
		elseif req.type == "comment_range" then
			api_fn = gh.create_comment_range
		else
			api_fn = gh.create_comment
		end

		local args = vim.list_extend({}, req.args)
		args[#args + 1] = function(err)
			vim.schedule(function()
				if err then
					failed = failed + 1
				else
					succeeded = succeeded + 1
					state.drafts[entry.draft_key] = nil
				end
				submit_next()
			end)
		end
		api_fn(unpack(args))
	end

	submit_next()
end

--- Fetch all PR review comments and build the lookup map.
function M.fetch_comments()
	local state = config.state
	if not state.pr_number then
		return
	end

	gh.get_pr_comments(state.pr_number, function(err, comments)
		if err then
			vim.notify("fude.nvim: Failed to fetch comments: " .. err, vim.log.levels.WARN)
			return
		end

		state.comments = comments or {}
		state.comment_map = data.build_comment_map(state.comments, state.pending_review_id)

		vim.schedule(function()
			require("fude.ui").refresh_extmarks()
		end)
		vim.notify(string.format("fude.nvim: Loaded %d comments", #state.comments), vim.log.levels.INFO)
	end)
end

--- Fetch existing pending review from GitHub and load into state.
function M.fetch_pending_review()
	local state = config.state
	if not state.pr_number then
		return
	end

	gh.get_reviews(state.pr_number, function(err, reviews)
		if err then
			vim.notify("fude.nvim: Failed to fetch reviews: " .. err, vim.log.levels.DEBUG)
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

		if not pending_review then
			return
		end

		state.pending_review_id = pending_review.id

		-- Rebuild comment_map to exclude pending review comments
		if state.comments then
			state.comment_map = data.build_comment_map(state.comments, state.pending_review_id)
			vim.schedule(function()
				require("fude.ui").refresh_extmarks()
			end)
		end

		-- Fetch comments for this pending review
		gh.get_review_comments(state.pr_number, pending_review.id, function(comments_err, comments)
			if comments_err then
				vim.notify("fude.nvim: Failed to fetch pending comments: " .. comments_err, vim.log.levels.DEBUG)
				return
			end

			state.pending_comments = data.build_pending_comments_from_review(comments or {})
			vim.schedule(function()
				require("fude.ui").refresh_extmarks()
			end)

			local count = vim.tbl_count(state.pending_comments)
			if count > 0 then
				vim.notify(string.format("fude.nvim: Loaded %d pending comments", count), vim.log.levels.INFO)
			end
		end)
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

return M
