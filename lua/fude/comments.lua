local M = {}
local config = require("fude.config")
local diff = require("fude.diff")
local ui = require("fude.ui")
local data = require("fude.comments.data")
local sync = require("fude.comments.sync")

-- Re-export data functions (facade)
M.build_comment_map = data.build_comment_map
M.find_next_comment_line = data.find_next_comment_line
M.find_prev_comment_line = data.find_prev_comment_line
M.find_comment_by_id = data.find_comment_by_id
M.get_comment_thread = data.get_comment_thread
M.parse_draft_key = data.parse_draft_key
M.build_submit_request = data.build_submit_request
M.format_submit_result = data.format_submit_result
M.build_review_comments = data.build_review_comments
M.build_pending_comments_from_review = data.build_pending_comments_from_review
M.build_review_comment_object = data.build_review_comment_object
M.pending_comments_to_array = data.pending_comments_to_array
M.get_comment_line_range = data.get_comment_line_range
M.get_reply_target_id = data.get_reply_target_id

-- Re-export sync functions (facade)
M.submit_as_review = sync.submit_as_review
M.submit_drafts = sync.submit_drafts
M.fetch_comments = sync.fetch_comments
M.fetch_pending_review = sync.fetch_pending_review
M.sync_pending_review = sync.sync_pending_review

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

	local draft_key = "reply:" .. reply_target_id
	local gh = require("fude.gh")

	ui.open_reply_window(thread, {
		on_submit = function(reply_body)
			state.drafts[draft_key] = nil

			gh.reply_to_comment(state.pr_number, reply_target_id, reply_body, function(err, _)
				if err then
					vim.notify("fude.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("fude.nvim: Reply posted", vim.log.levels.INFO)
				sync.fetch_comments()
			end)
		end,
		on_cancel = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
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
		if config.opts.auto_view_comment then
			M.view_comments()
		else
			ui.flash_line(target)
		end
	end
end

--- List all PR review comments in a Telescope picker.
function M.list_comments()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.comment_map or vim.tbl_isempty(state.comment_map) then
		vim.notify("fude.nvim: No comments found", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim required for comment list", vim.log.levels.WARN)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local previewers = require("telescope.previewers")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local date_col_width = #config.format_date("2000-01-01T00:00:00Z")

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = date_col_width },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		return displayer({
			{ entry.last_date, "Comment" },
			{ entry.detail, "Normal" },
		})
	end

	local entries = {}
	for path, lines in pairs(state.comment_map) do
		for line_key, comments in pairs(lines) do
			local line = math.floor(tonumber(line_key) or 1)
			local first = comments[1]
			local last = comments[#comments]
			local author = first.user and first.user.login or "unknown"
			local last_ts = last.created_at or ""
			local last_date = config.format_date(last_ts)
			local body_preview = (first.body or ""):gsub("\r?\n", " ")
			if #body_preview > 60 then
				body_preview = body_preview:sub(1, 57) .. "..."
			end
			local detail = string.format("%s:%d  @%s  %s", path, line, author, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s:%d %s", path, line, first.body or ""),
				filename = repo_root .. "/" .. path,
				lnum = line,
				last_ts = last_ts,
				last_date = last_date,
				detail = detail,
				comments = comments,
				display = make_display,
			})
		end
	end

	table.sort(entries, function(a, b)
		return a.last_ts > b.last_ts
	end)

	pickers
		.new({}, {
			prompt_title = string.format("PR #%d Review Comments", state.pr_number),
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Comment Thread",
				define_preview = function(self, entry)
					local preview_lines = {}
					for _, comment in ipairs(entry.comments) do
						local author = comment.user and comment.user.login or "unknown"
						local date = config.format_date(comment.created_at)
						table.insert(preview_lines, string.format("── @%s (%s) ──", author, date))
						table.insert(preview_lines, "")
						for _, body_line in ipairs(vim.split(comment.body or "", "\n", { trimempty = false })) do
							table.insert(preview_lines, body_line)
						end
						table.insert(preview_lines, "")
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
						local lnum = math.max(1, selection.lnum)
						pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
						if config.opts.auto_view_comment then
							M.view_comments()
						else
							ui.flash_line(lnum)
						end
					end
				end)
				return true
			end,
		})
		:find()
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
		on_save = function(lines)
			state.drafts[pending_key] = lines
			vim.notify("fude.nvim: Draft saved locally", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end,
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
		if config.opts.auto_view_comment then
			M.view_comments()
		else
			ui.flash_line(target)
		end
	end
end

--- List all draft comments in a Telescope picker.
function M.list_drafts()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.drafts or vim.tbl_isempty(state.drafts) then
		vim.notify("fude.nvim: No drafts", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim required for draft list", vim.log.levels.WARN)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local entries = {}
	for key, draft_lines in pairs(state.drafts) do
		local parsed = data.parse_draft_key(key)
		if not parsed then
			goto continue
		end

		local body_preview = table.concat(draft_lines, " "):gsub("%s+", " ")
		if #body_preview > 60 then
			body_preview = body_preview:sub(1, 57) .. "..."
		end

		if parsed.type == "comment" then
			local range_str = parsed.start_line == parsed.end_line and tostring(parsed.start_line)
				or string.format("%d-%d", parsed.start_line, parsed.end_line)
			local detail = string.format("%s:%s  %s", parsed.path, range_str, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s:%d %s", parsed.path, parsed.start_line, table.concat(draft_lines, " ")),
				filename = repo_root .. "/" .. parsed.path,
				lnum = parsed.start_line,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		elseif parsed.type == "reply" then
			local found = data.find_comment_by_id(parsed.comment_id, state.comment_map or {})
			local reply_path = found and found.path
			local reply_line = found and found.line
			local loc = reply_path and string.format("%s:%d", reply_path, reply_line or 1) or "reply:" .. parsed.comment_id
			local detail = string.format("%s  (reply)  %s", loc, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s %s", loc, table.concat(draft_lines, " ")),
				filename = reply_path and (repo_root .. "/" .. reply_path) or nil,
				lnum = reply_line,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		elseif parsed.type == "issue_comment" then
			local detail = string.format("PR comment  %s", body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = "PR comment " .. table.concat(draft_lines, " "),
				filename = nil,
				lnum = nil,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		end

		::continue::
	end

	table.sort(entries, function(a, b)
		return a.value < b.value
	end)

	pickers
		.new({}, {
			prompt_title = "Draft Comments",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Draft Content",
				define_preview = function(self, entry)
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, entry.draft_lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.filename then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
						local lnum = math.max(1, selection.lnum or 1)
						pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
					end
				end)
				map("n", "d", function()
					local selection = action_state.get_selected_entry()
					if selection then
						state.drafts[selection.draft_key] = nil
						vim.notify("fude.nvim: Draft deleted", vim.log.levels.INFO)
						actions.close(prompt_bufnr)
						ui.refresh_extmarks()
					end
				end)
				map({ "n", "i" }, "<C-s>", function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local multi = picker:get_multi_selection()
					local targets = #multi > 0 and multi or entries
					local to_submit = {}
					for _, entry in ipairs(targets) do
						local parsed = data.parse_draft_key(entry.draft_key)
						if parsed then
							table.insert(to_submit, {
								draft_key = entry.draft_key,
								draft_lines = entry.draft_lines,
								parsed = parsed,
							})
						end
					end
					if #to_submit == 0 then
						return
					end
					actions.close(prompt_bufnr)
					vim.ui.select({ "Yes", "No" }, {
						prompt = string.format("Submit %d draft(s)?", #to_submit),
					}, function(choice)
						if choice ~= "Yes" then
							return
						end
						sync.submit_drafts(to_submit, function(succeeded, failed)
							local msg, level = data.format_submit_result(succeeded, failed, #to_submit)
							vim.notify("fude.nvim: " .. msg, level)
							ui.refresh_extmarks()
							sync.fetch_comments()
						end)
					end)
				end)
				map({ "n", "i" }, "<C-r>", function()
					actions.close(prompt_bufnr)
					-- Submit drafts as a review
					ui.select_review_event(function(event)
						if not event then
							return
						end
						ui.open_comment_input(function(review_body)
							sync.submit_as_review(event, review_body, function(err, excluded_count)
								if err then
									vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
									return
								end
								local msg = "Review submitted"
								if excluded_count > 0 then
									msg = msg .. string.format(" (%d drafts excluded: replies/PR comments)", excluded_count)
								end
								vim.notify("fude.nvim: " .. msg, vim.log.levels.INFO)
							end)
						end, {
							title = " Review Body (optional) ",
							footer = " <CR> submit | q skip body ",
							submit_on_enter = true,
						})
					end)
				end)
				return true
			end,
		})
		:find()
end

return M
