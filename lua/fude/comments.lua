local M = {}
local config = require("fude.config")
local gh = require("fude.gh")
local ui = require("fude.ui")

--- Build a nested lookup map from a flat array of comments.
--- Excludes comments belonging to a pending review (cannot be replied to).
--- @param comments table[] flat array of comment objects
--- @param pending_review_id number|nil review ID to exclude
--- @return table<string, table<number, table[]>> map[path][line] = {comments}
function M.build_comment_map(comments, pending_review_id)
	local map = {}
	for _, c in ipairs(comments) do
		-- Skip comments belonging to user's pending review (not yet submitted)
		if pending_review_id and c.pull_request_review_id == pending_review_id then
			goto continue
		end
		local path = c.path
		local line = c.line or c.original_line
		if path and line then
			if not map[path] then
				map[path] = {}
			end
			if not map[path][line] then
				map[path][line] = {}
			end
			table.insert(map[path][line], c)
		end
		::continue::
	end
	return map
end

--- Find the next comment line after current_line, with wrap-around.
--- @param current_line number
--- @param sorted_lines number[]
--- @return number|nil
function M.find_next_comment_line(current_line, sorted_lines)
	if #sorted_lines == 0 then
		return nil
	end
	for _, line in ipairs(sorted_lines) do
		if line > current_line then
			return line
		end
	end
	return sorted_lines[1]
end

--- Find the previous comment line before current_line, with wrap-around.
--- @param current_line number
--- @param sorted_lines number[]
--- @return number|nil
function M.find_prev_comment_line(current_line, sorted_lines)
	if #sorted_lines == 0 then
		return nil
	end
	for i = #sorted_lines, 1, -1 do
		if sorted_lines[i] < current_line then
			return sorted_lines[i]
		end
	end
	return sorted_lines[#sorted_lines]
end

--- Find a comment by its ID in the comment map.
--- @param comment_id number
--- @param comment_map table<string, table<number, table[]>>
--- @return table|nil { path: string, line: number, comment: table }
function M.find_comment_by_id(comment_id, comment_map)
	for path, file_lines in pairs(comment_map) do
		for line, cmts in pairs(file_lines) do
			for _, c in ipairs(cmts) do
				if c.id == comment_id then
					return { path = path, line = tonumber(line), comment = c }
				end
			end
		end
	end
	return nil
end

--- Parse a draft key string into its components.
--- @param key string "path:start:end" or "reply:comment_id"
--- @return table|nil parsed key components
function M.parse_draft_key(key)
	if key == "issue_comment" then
		return { type = "issue_comment" }
	end
	local reply_id = key:match("^reply:(%d+)$")
	if reply_id then
		return { type = "reply", comment_id = tonumber(reply_id) }
	end
	local path, sl, el = key:match("^(.+):(%d+):(%d+)$")
	if path then
		return { type = "comment", path = path, start_line = tonumber(sl), end_line = tonumber(el) }
	end
	return nil
end

--- Build a submit request from a parsed draft key.
--- @param parsed table parse_draft_key() result
--- @param body string comment body
--- @param pr_number number
--- @param sha string HEAD commit SHA
--- @return table { type: "comment"|"comment_range"|"reply", args: table }
function M.build_submit_request(parsed, body, pr_number, sha)
	if parsed.type == "issue_comment" then
		return { type = "issue_comment", args = { pr_number, body } }
	end
	if parsed.type == "reply" then
		return { type = "reply", args = { pr_number, parsed.comment_id, body } }
	end
	if parsed.start_line == parsed.end_line then
		return { type = "comment", args = { pr_number, sha, parsed.path, parsed.end_line, body } }
	end
	return { type = "comment_range", args = { pr_number, sha, parsed.path, parsed.start_line, parsed.end_line, body } }
end

--- Format a submit result into a notification message.
--- @param succeeded number
--- @param failed number
--- @param total number
--- @return string message, number log_level
function M.format_submit_result(succeeded, failed, total)
	if failed == 0 then
		return string.format("Submitted %d/%d drafts", succeeded, total), vim.log.levels.INFO
	end
	return string.format("Submitted %d/%d drafts (%d failed)", succeeded, total, failed), vim.log.levels.WARN
end

--- Build review comments array from drafts.
--- Only "comment" type drafts can be included in a review.
--- Replies and issue_comments are excluded.
--- @param drafts table<string, string[]> draft_key -> lines
--- @return table { comments: table[], excluded: table<string, string> }
function M.build_review_comments(drafts)
	local comments = {}
	local excluded = {}

	for key, lines in pairs(drafts) do
		local parsed = M.parse_draft_key(key)
		if not parsed then
			excluded[key] = "invalid_key"
		elseif parsed.type == "reply" then
			excluded[key] = "reply"
		elseif parsed.type == "issue_comment" then
			excluded[key] = "issue_comment"
		elseif parsed.type == "comment" then
			local body = table.concat(lines, "\n")
			local comment = {
				path = parsed.path,
				body = body,
				line = parsed.end_line,
				side = "RIGHT",
			}
			if parsed.start_line ~= parsed.end_line then
				comment.start_line = parsed.start_line
				comment.start_side = "RIGHT"
			end
			table.insert(comments, comment)
		end
	end

	return { comments = comments, excluded = excluded }
end

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
	local result = M.build_review_comments(state.drafts)
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
				local parsed = M.parse_draft_key(key)
				if parsed and parsed.type == "comment" then
					state.drafts[key] = nil
				end
			end

			ui.refresh_extmarks()
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
			local parsed = M.parse_draft_key(key)
			if parsed and parsed.type == "comment" then
				state.drafts[key] = nil
			end
		end

		ui.refresh_extmarks()
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
		local body = table.concat(entry.draft_lines, "\n")
		local req = M.build_submit_request(entry.parsed, body, state.pr_number, sha)

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
		state.comment_map = M.build_comment_map(state.comments, state.pending_review_id)

		ui.refresh_extmarks()
		vim.notify(string.format("fude.nvim: Loaded %d comments", #state.comments), vim.log.levels.INFO)
	end)
end

--- Build pending_comments from review comments array.
--- @param comments table[] array of review comment objects from GitHub
--- @return table<string, table> map of key -> comment data
function M.build_pending_comments_from_review(comments)
	local result = {}
	for _, c in ipairs(comments) do
		local path = c.path
		local line = c.line or c.original_line
		local start_line = c.start_line or line
		if path and line then
			local key = path .. ":" .. start_line .. ":" .. line
			result[key] = {
				path = path,
				body = c.body,
				line = line,
				side = c.side or "RIGHT",
			}
			if start_line ~= line then
				result[key].start_line = start_line
				result[key].start_side = c.start_side or "RIGHT"
			end
		end
	end
	return result
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
			state.comment_map = M.build_comment_map(state.comments, state.pending_review_id)
			ui.refresh_extmarks()
		end

		-- Fetch comments for this pending review
		gh.get_review_comments(state.pr_number, pending_review.id, function(comments_err, comments)
			if comments_err then
				vim.notify("fude.nvim: Failed to fetch pending comments: " .. comments_err, vim.log.levels.DEBUG)
				return
			end

			state.pending_comments = M.build_pending_comments_from_review(comments or {})
			ui.refresh_extmarks()

			local count = vim.tbl_count(state.pending_comments)
			if count > 0 then
				vim.notify(string.format("fude.nvim: Loaded %d pending comments", count), vim.log.levels.INFO)
			end
		end)
	end)
end

--- Get comments at a specific file and line.
--- @param rel_path string repo-relative file path
--- @param line number line number
--- @return table[] comments
function M.get_comments_at(rel_path, line)
	local state = config.state
	if not state.comment_map[rel_path] then
		return {}
	end
	return state.comment_map[rel_path][line] or {}
end

--- Get all line numbers with comments for a file.
--- @param rel_path string repo-relative file path
--- @return number[] sorted line numbers
function M.get_comment_lines(rel_path)
	local state = config.state
	if not state.comment_map[rel_path] then
		return {}
	end
	local lines = {}
	for line, _ in pairs(state.comment_map[rel_path]) do
		table.insert(lines, tonumber(line))
	end
	table.sort(lines)
	return lines
end

--- Build a review comment object from parsed draft key components.
--- @param path string repo-relative file path
--- @param start_line number start line number
--- @param end_line number end line number
--- @param body string comment body
--- @return table review comment object for GitHub API
function M.build_review_comment_object(path, start_line, end_line, body)
	local comment = {
		path = path,
		body = body,
		line = end_line,
		side = "RIGHT",
	}
	if start_line ~= end_line then
		comment.start_line = start_line
		comment.start_side = "RIGHT"
	end
	return comment
end

--- Convert pending_comments table to array of review comment objects.
--- @param pending_comments table<string, table> map of key -> comment data
--- @return table[] array of review comment objects
function M.pending_comments_to_array(pending_comments)
	local result = {}
	for _, comment_data in pairs(pending_comments) do
		table.insert(result, comment_data)
	end
	return result
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

	local comments_array = M.pending_comments_to_array(state.pending_comments)

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
		gh.create_pending_review(state.pr_number, sha, comments_array, function(err, data)
			if err then
				callback(err)
				return
			end
			state.pending_review_id = data and data.id
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

--- Get the reply target ID for a comment.
--- GitHub API doesn't allow replying to replies, so we need to find the top-level comment.
--- @param comment_id number the comment ID
--- @param comment_map table the comment map
--- @return number the ID to use for reply (either original or in_reply_to_id)
function M.get_reply_target_id(comment_id, comment_map)
	local found = M.find_comment_by_id(comment_id, comment_map)
	if found and found.comment.in_reply_to_id then
		return found.comment.in_reply_to_id
	end
	return comment_id
end

return M
