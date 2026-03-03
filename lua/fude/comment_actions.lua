local M = {}
local config = require("fude.config")
local comments = require("fude.comments")
local gh = require("fude.gh")
local diff = require("fude.diff")
local ui = require("fude.ui")

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
	local initial_lines = existing and vim.split(existing.body, "\n") or nil

	ui.open_comment_input(function(body)
		if body then
			-- <CR> pressed: save as pending review on GitHub
			local comment_obj = comments.build_review_comment_object(rel_path, start_line, end_line, body)
			state.pending_comments[pending_key] = comment_obj

			comments.sync_pending_review(function(err)
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
		on_save = function(lines)
			-- Save as local draft (fallback for q key in submit_on_enter mode)
			state.drafts[pending_key] = lines
			vim.notify("fude.nvim: Draft saved locally", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end,
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
	local line_comments = comments.get_comments_at(rel_path, line)

	if #line_comments == 0 then
		vim.notify("fude.nvim: No comments on this line", vim.log.levels.INFO)
		return
	end

	ui.show_comments_float(line_comments)
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
		local line_comments = comments.get_comments_at(rel_path, line)
		if #line_comments == 0 then
			vim.notify("fude.nvim: No comments on this line to reply to", vim.log.levels.INFO)
			return
		end
		comment_id = line_comments[#line_comments].id
	end

	-- GitHub API doesn't allow replying to replies, find top-level comment
	local reply_target_id = comments.get_reply_target_id(comment_id, state.comment_map or {})

	local draft_key = "reply:" .. reply_target_id
	local draft = state.drafts[draft_key]

	ui.open_comment_input(function(body)
		if not body then
			return
		end

		state.drafts[draft_key] = nil

		gh.reply_to_comment(state.pr_number, reply_target_id, body, function(err, _)
			if err then
				vim.notify("fude.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("fude.nvim: Reply posted", vim.log.levels.INFO)
			comments.fetch_comments()
		end)
	end, {
		initial_lines = draft or nil,
		submit_on_enter = true,
		on_save = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end,
	})
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

	local initial_lines = existing and vim.split(existing.body, "\n") or suggestion_lines
	local cursor_pos = existing and nil or { 2, 0 }

	ui.open_comment_input(function(body)
		if body then
			-- <CR> pressed: save as pending review on GitHub
			local comment_obj = comments.build_review_comment_object(rel_path, start_line, end_line, body)
			state.pending_comments[pending_key] = comment_obj

			comments.sync_pending_review(function(err)
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
		on_save = function(lines)
			state.drafts[pending_key] = lines
			vim.notify("fude.nvim: Draft saved locally", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end,
	})
end

--- Navigate to the next comment in the current file.
function M.next_comment()
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

	local current_line = vim.fn.line(".")
	local comment_lines = comments.get_comment_lines(rel_path)
	local target = comments.find_next_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		if config.opts.auto_view_comment then
			M.view_comments()
		end
	end
end

--- Navigate to the previous comment in the current file.
function M.prev_comment()
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

	local current_line = vim.fn.line(".")
	local comment_lines = comments.get_comment_lines(rel_path)
	local target = comments.find_prev_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		if config.opts.auto_view_comment then
			M.view_comments()
		end
	end
end

return M
