local M = {}
local config = require("fude.config")
local diff = require("fude.diff")
local format = require("fude.ui.format")
local ui = require("fude.ui")
local data = require("fude.comments.data")
local sync = require("fude.comments.sync")
local pickers = require("fude.comments.pickers")

-- Re-export data functions (facade)
M.build_comment_map = data.build_comment_map
M.find_next_comment_line = data.find_next_comment_line
M.find_prev_comment_line = data.find_prev_comment_line
M.find_comment_by_id = data.find_comment_by_id
M.get_comment_thread = data.get_comment_thread
M.parse_draft_key = data.parse_draft_key
M.build_pending_comments_from_review = data.build_pending_comments_from_review
M.build_review_comment_object = data.build_review_comment_object
M.merge_pending_into_comments = data.merge_pending_into_comments
M.pending_comments_to_array = data.pending_comments_to_array
M.get_comment_line_range = data.get_comment_line_range
M.get_reply_target_id = data.get_reply_target_id

-- Re-export sync functions (facade)
M.submit_as_review = sync.submit_as_review
M.load_comments = sync.load_comments
M.sync_pending_review = sync.sync_pending_review
M.reply_to_comment_sync = sync.reply_to_comment

-- Re-export picker functions (facade)
M.list_comments = pickers.list_comments

--- Get comments at a specific file and line.
--- @param rel_path string repo-relative file path
--- @param line number line number
--- @return table[] comments
function M.get_comments_at(rel_path, line)
	return data.get_comments_at(config.state.comment_map, rel_path, line)
end

--- Get all line numbers with comments for a file.
--- @param rel_path string repo-relative file path
--- @return number[] sorted line numbers
function M.get_comment_lines(rel_path)
	return data.get_comment_lines(config.state.comment_map, rel_path)
end

--- Create a new comment on the current line or visual selection.
--- @param is_visual boolean whether the comment is for a visual selection
function M.create_comment(is_visual)
	local state = config.state
	if not state.active or not state.pr_number then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		vim.notify("fude.nvim: File not in repository", vim.log.levels.WARN)
		return
	end

	local start_line, end_line
	if is_visual then
		start_line = vim.fn.line("'<")
		end_line = vim.fn.line("'>")
	else
		start_line = vim.fn.line(".")
		end_line = start_line
	end

	local pending_key = rel_path .. ":" .. start_line .. ":" .. end_line
	local existing = state.pending_comments[pending_key]
	local initial_lines = existing and vim.split(format.normalize_newlines(existing.body), "\n") or nil

	ui.open_comment_input(function(comment_body)
		if comment_body then
			-- <CR> pressed: save as pending review on GitHub
			local comment_obj = data.build_review_comment_object(rel_path, start_line, end_line, comment_body)
			state.pending_comments[pending_key] = comment_obj

			sync.sync_pending_review(function(err)
				vim.schedule(function()
					if err then
						vim.notify("fude.nvim: Failed to save pending: " .. err, vim.log.levels.ERROR)
						-- Remove from pending_comments on failure
						state.pending_comments[pending_key] = nil
					else
						vim.notify("fude.nvim: Pending comment saved", vim.log.levels.INFO)
					end
					ui.refresh_extmarks()
				end)
			end)
		end
		-- nil: q pressed, cancel without saving
	end, {
		initial_lines = initial_lines,
	})
end

--- View comments on the current line.
function M.view_comments()
	local state = config.state
	if not state.active then
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	local line = vim.fn.line(".")
	local comments = M.get_comments_at(rel_path, line)

	if #comments == 0 then
		vim.notify("fude.nvim: No comments on this line", vim.log.levels.INFO)
		return
	end

	-- Get the line range from the first comment (all comments at this line share the same range)
	local start_line, end_line = data.get_comment_line_range(comments[1])

	ui.show_comments_float(comments, { source_buf = buf, source_start_line = start_line, source_end_line = end_line })
end

--- Reply to the most recent comment on the current line.
--- @param comment_id number|nil specific comment id, or nil to use latest on current line
function M.reply_to_comment(comment_id)
	local state = config.state
	if not state.active or not state.pr_number then
		return
	end

	-- GitHub API doesn't allow creating replies while a pending review exists
	if state.pending_review_id then
		vim.notify("fude.nvim: Cannot reply while pending review exists. Run :FudeReviewSubmit first.", vim.log.levels.WARN)
		return
	end

	if not comment_id then
		local buf = vim.api.nvim_get_current_buf()
		local filepath = vim.api.nvim_buf_get_name(buf)
		local rel_path = diff.to_repo_relative(filepath)
		if not rel_path then
			return
		end
		local line = vim.fn.line(".")
		local line_comments = M.get_comments_at(rel_path, line)
		if #line_comments == 0 then
			vim.notify("fude.nvim: No comments on this line to reply to", vim.log.levels.INFO)
			return
		end
		comment_id = line_comments[#line_comments].id
	end

	-- Get the full thread for this comment
	local thread = data.get_comment_thread(comment_id, state.comments or {})
	if #thread == 0 then
		vim.notify("fude.nvim: Comment not found", vim.log.levels.WARN)
		return
	end

	-- GitHub API doesn't allow replying to replies, find top-level comment
	local reply_target_id = data.get_reply_target_id(comment_id, state.comment_map or {})

	ui.open_reply_window(thread, {
		on_submit = function(reply_body)
			sync.reply_to_comment(reply_target_id, reply_body, function(err)
				if err then
					vim.notify("fude.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("fude.nvim: Reply posted", vim.log.levels.INFO)
			end)
		end,
	})
end

--- Check if a comment is owned by the authenticated user.
--- @param comment table comment object from GitHub API
--- @return boolean
function M.is_own_comment(comment)
	local github_user = config.state.github_user
	if not github_user then
		return false
	end
	return (comment.user and comment.user.login == github_user) == true
end

--- Find the pending_comments key for a given comment ID.
--- @param comment_id number
--- @return string|nil key
function M.find_pending_key(comment_id)
	local state = config.state
	for key, pc in pairs(state.pending_comments) do
		if pc.id == comment_id then
			return key
		end
	end
	return nil
end

--- Check if a comment belongs to the current pending review.
--- @param comment table comment object
--- @return boolean
function M.is_pending_comment(comment)
	local state = config.state
	return state.pending_review_id ~= nil and comment.pull_request_review_id == state.pending_review_id
end

--- Edit a comment (pending or submitted).
--- @param comment_id number comment ID to edit
function M.edit_comment(comment_id)
	local state = config.state
	if not state.active or not state.pr_number then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.github_user then
		vim.notify("fude.nvim: GitHub user not available yet", vim.log.levels.WARN)
		return
	end

	-- Find the comment
	local found = data.find_comment_by_id(comment_id, state.comment_map or {})
	if not found then
		vim.notify("fude.nvim: Comment not found", vim.log.levels.WARN)
		return
	end

	local comment = found.comment

	-- Ownership check
	if not M.is_own_comment(comment) then
		vim.notify("fude.nvim: Cannot edit another user's comment", vim.log.levels.WARN)
		return
	end

	local is_pending = M.is_pending_comment(comment)

	-- For submitted comments, block if pending review exists (GitHub API limitation)
	if not is_pending and state.pending_review_id then
		vim.notify(
			"fude.nvim: Cannot edit submitted comment while pending review exists. Run :FudeReviewSubmit first.",
			vim.log.levels.WARN
		)
		return
	end

	-- Get thread for display in upper pane
	local thread = data.get_comment_thread(comment_id, state.comments or {})

	ui.open_edit_window(thread, comment, {
		on_submit = function(new_body)
			if is_pending then
				-- Pending comment: update in pending_comments and re-sync
				local pending_key = M.find_pending_key(comment_id)
				if pending_key and state.pending_comments[pending_key] then
					state.pending_comments[pending_key].body = new_body
					sync.sync_pending_review(function(err)
						vim.schedule(function()
							if err then
								vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
							else
								vim.notify("fude.nvim: Pending comment updated", vim.log.levels.INFO)
							end
							ui.refresh_extmarks()
						end)
					end)
				else
					-- Pending key not found in local state, try API update
					sync.edit_comment(comment_id, new_body, function(err)
						if err then
							vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
							return
						end
						vim.notify("fude.nvim: Comment updated", vim.log.levels.INFO)
					end)
				end
			else
				-- Submitted comment: direct API update
				sync.edit_comment(comment_id, new_body, function(err)
					if err then
						vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
						return
					end
					vim.notify("fude.nvim: Comment updated", vim.log.levels.INFO)
				end)
			end
		end,
	})
end

--- Delete a comment (pending or submitted).
--- @param comment_id number comment ID to delete
function M.delete_comment(comment_id)
	local state = config.state
	if not state.active or not state.pr_number then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.github_user then
		vim.notify("fude.nvim: GitHub user not available yet", vim.log.levels.WARN)
		return
	end

	-- Find the comment
	local found = data.find_comment_by_id(comment_id, state.comment_map or {})
	if not found then
		vim.notify("fude.nvim: Comment not found", vim.log.levels.WARN)
		return
	end

	local comment = found.comment

	-- Ownership check
	if not M.is_own_comment(comment) then
		vim.notify("fude.nvim: Cannot delete another user's comment", vim.log.levels.WARN)
		return
	end

	local is_pending = M.is_pending_comment(comment)

	-- For submitted comments, block if pending review exists
	if not is_pending and state.pending_review_id then
		vim.notify(
			"fude.nvim: Cannot delete submitted comment while pending review exists. Run :FudeReviewSubmit first.",
			vim.log.levels.WARN
		)
		return
	end

	vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
		if choice ~= "Yes" then
			return
		end

		if is_pending then
			-- Pending comment: remove from pending_comments and re-sync
			local pending_key = M.find_pending_key(comment_id)
			if pending_key then
				state.pending_comments[pending_key] = nil
			end
			sync.sync_pending_review(function(err)
				vim.schedule(function()
					if err then
						vim.notify("fude.nvim: Delete failed: " .. err, vim.log.levels.ERROR)
					else
						vim.notify("fude.nvim: Pending comment deleted", vim.log.levels.INFO)
					end
					ui.refresh_extmarks()
				end)
			end)
		else
			-- Submitted comment: direct API delete
			sync.delete_comment(comment_id, function(err)
				if err then
					vim.notify("fude.nvim: Delete failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("fude.nvim: Comment deleted", vim.log.levels.INFO)
			end)
		end
	end)
end

--- Navigate to the next comment in the current file.
function M.next_comment()
	local state = config.state
	if not state.active then
		return
	end

	-- Close float window if called from within one, but avoid closing modifiable floats (e.g. comment input)
	local win_config = vim.api.nvim_win_get_config(0)
	if win_config.relative and win_config.relative ~= "" then
		local buf = vim.api.nvim_get_current_buf()
		if not vim.bo[buf].modifiable then
			vim.api.nvim_win_close(0, true)
		end
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	local current_line = vim.fn.line(".")
	local comment_lines = M.get_comment_lines(rel_path)
	local target = data.find_next_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		-- In inline mode, comments are already visible below the line, so just flash
		-- In virtualText mode, open the comment viewer if auto_view_comment is enabled
		local style = config.get_comment_style()
		if style == "inline" then
			ui.flash_line(target)
		elseif config.opts.auto_view_comment then
			M.view_comments()
		else
			ui.flash_line(target)
		end
	end
end

--- Suggest a change on the current line or visual selection.
--- @param is_visual boolean whether the suggestion is for a visual selection
function M.suggest_change(is_visual)
	local state = config.state
	if not state.active or not state.pr_number then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		vim.notify("fude.nvim: File not in repository", vim.log.levels.WARN)
		return
	end

	local start_line, end_line
	if is_visual then
		start_line = vim.fn.line("'<")
		end_line = vim.fn.line("'>")
	else
		start_line = vim.fn.line(".")
		end_line = start_line
	end

	local pending_key = rel_path .. ":" .. start_line .. ":" .. end_line
	local existing = state.pending_comments[pending_key]

	local source_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	local suggestion_lines = { "```suggestion" }
	vim.list_extend(suggestion_lines, source_lines)
	table.insert(suggestion_lines, "```")

	local initial_lines = existing and vim.split(format.normalize_newlines(existing.body), "\n") or suggestion_lines
	local cursor_pos = existing and nil or { 2, 0 }

	ui.open_comment_input(function(comment_body)
		if comment_body then
			-- <CR> pressed: save as pending review on GitHub
			local comment_obj = data.build_review_comment_object(rel_path, start_line, end_line, comment_body)
			state.pending_comments[pending_key] = comment_obj

			sync.sync_pending_review(function(err)
				vim.schedule(function()
					if err then
						vim.notify("fude.nvim: Failed to save pending: " .. err, vim.log.levels.ERROR)
						state.pending_comments[pending_key] = nil
					else
						vim.notify("fude.nvim: Pending suggestion saved", vim.log.levels.INFO)
					end
					ui.refresh_extmarks()
				end)
			end)
		end
		-- nil: q pressed, cancel without saving
	end, {
		initial_lines = initial_lines,
		title = " Suggest Change ",
		cursor_pos = cursor_pos,
	})
end

--- Navigate to the previous comment in the current file.
function M.prev_comment()
	local state = config.state
	if not state.active then
		return
	end

	-- Close float window if called from within one, but avoid closing modifiable floats (e.g. comment input)
	local win_config = vim.api.nvim_win_get_config(0)
	if win_config.relative and win_config.relative ~= "" then
		local buf = vim.api.nvim_get_current_buf()
		if not vim.bo[buf].modifiable then
			vim.api.nvim_win_close(0, true)
		end
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	local current_line = vim.fn.line(".")
	local comment_lines = M.get_comment_lines(rel_path)
	local target = data.find_prev_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		-- In inline mode, comments are already visible below the line, so just flash
		-- In virtualText mode, open the comment viewer if auto_view_comment is enabled
		local style = config.get_comment_style()
		if style == "inline" then
			ui.flash_line(target)
		elseif config.opts.auto_view_comment then
			M.view_comments()
		else
			ui.flash_line(target)
		end
	end
end

return M
