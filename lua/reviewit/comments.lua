local M = {}
local config = require("reviewit.config")
local gh = require("reviewit.gh")
local diff = require("reviewit.diff")
local ui = require("reviewit.ui")

--- Build a nested lookup map from a flat array of comments.
--- @param comments table[] flat array of comment objects
--- @return table<string, table<number, table[]>> map[path][line] = {comments}
function M.build_comment_map(comments)
	local map = {}
	for _, c in ipairs(comments) do
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
--- Only "comment" type drafts are included. Replies and issue_comments are excluded.
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param body string|nil review body (optional)
--- @param callback fun(err: string|nil, excluded_count: number)
function M.submit_as_review(event, body, callback)
	local state = config.state
	if not state.active or not state.pr_number then
		callback("Not active", 0)
		return
	end

	local sha, sha_err = gh.get_head_sha()
	if not sha then
		callback(sha_err or "Failed to get HEAD SHA", 0)
		return
	end

	local result = M.build_review_comments(state.drafts)
	local excluded_count = vim.tbl_count(result.excluded)

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
		vim.notify("reviewit.nvim: " .. (sha_err or "Failed to get HEAD SHA"), vim.log.levels.ERROR)
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

		api_fn(unpack(req.args), function(err)
			vim.schedule(function()
				if err then
					failed = failed + 1
				else
					succeeded = succeeded + 1
					state.drafts[entry.draft_key] = nil
				end
				submit_next()
			end)
		end)
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
			vim.notify("reviewit.nvim: Failed to fetch comments: " .. err, vim.log.levels.WARN)
			return
		end

		state.comments = comments or {}
		state.comment_map = M.build_comment_map(state.comments)

		ui.refresh_extmarks()
		vim.notify(string.format("reviewit.nvim: Loaded %d comments", #state.comments), vim.log.levels.INFO)
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

--- Create a new comment on the current line or visual selection.
--- @param is_visual boolean whether the comment is for a visual selection
function M.create_comment(is_visual)
	local state = config.state
	if not state.active or not state.pr_number then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		vim.notify("reviewit.nvim: File not in repository", vim.log.levels.WARN)
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

	local draft_key = rel_path .. ":" .. start_line .. ":" .. end_line
	local draft = state.drafts[draft_key]

	ui.open_comment_input(function(body)
		if body then
			-- <CR> pressed: save as draft (not posting to API)
			state.drafts[draft_key] = vim.split(body, "\n")
			vim.notify("reviewit.nvim: Draft saved", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end
		-- nil: q pressed, cancel without saving
	end, {
		initial_lines = draft or nil,
		on_save = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("reviewit.nvim: Draft saved", vim.log.levels.INFO)
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
		vim.notify("reviewit.nvim: No comments on this line", vim.log.levels.INFO)
		return
	end

	ui.show_comments_float(comments)
end

--- Reply to the most recent comment on the current line.
--- @param comment_id number|nil specific comment id, or nil to use latest on current line
function M.reply_to_comment(comment_id)
	local state = config.state
	if not state.active or not state.pr_number then
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
		local comments = M.get_comments_at(rel_path, line)
		if #comments == 0 then
			vim.notify("reviewit.nvim: No comments on this line to reply to", vim.log.levels.INFO)
			return
		end
		comment_id = comments[#comments].id
	end

	local draft_key = "reply:" .. comment_id
	local draft = state.drafts[draft_key]

	ui.open_comment_input(function(body)
		if not body then
			return
		end

		state.drafts[draft_key] = nil

		gh.reply_to_comment(state.pr_number, comment_id, body, function(err, _)
			if err then
				vim.notify("reviewit.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("reviewit.nvim: Reply posted", vim.log.levels.INFO)
			M.fetch_comments()
		end)
	end, {
		initial_lines = draft or nil,
		submit_on_enter = true,
		on_save = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("reviewit.nvim: Draft saved", vim.log.levels.INFO)
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
	local comment_lines = M.get_comment_lines(rel_path)
	local target = M.find_next_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		if config.opts.auto_view_comment then
			M.view_comments()
		end
	end
end

--- List all PR review comments in a Telescope picker.
function M.list_comments()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.comment_map or vim.tbl_isempty(state.comment_map) then
		vim.notify("reviewit.nvim: No comments found", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("reviewit.nvim: telescope.nvim required for comment list", vim.log.levels.WARN)
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
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		vim.notify("reviewit.nvim: File not in repository", vim.log.levels.WARN)
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

	local draft_key = rel_path .. ":" .. start_line .. ":" .. end_line
	local draft = state.drafts[draft_key]

	local source_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	local initial_lines = { "```suggestion" }
	vim.list_extend(initial_lines, source_lines)
	table.insert(initial_lines, "```")

	ui.open_comment_input(function(body)
		if body then
			-- <CR> pressed: save as draft (not posting to API)
			state.drafts[draft_key] = vim.split(body, "\n")
			vim.notify("reviewit.nvim: Draft saved", vim.log.levels.INFO)
			ui.refresh_extmarks()
		end
		-- nil: q pressed, cancel without saving
	end, {
		initial_lines = draft or initial_lines,
		title = " Suggest Change ",
		cursor_pos = draft and nil or { 2, 0 },
		on_save = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("reviewit.nvim: Draft saved", vim.log.levels.INFO)
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

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	local current_line = vim.fn.line(".")
	local comment_lines = M.get_comment_lines(rel_path)
	local target = M.find_prev_comment_line(current_line, comment_lines)
	if target then
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		if config.opts.auto_view_comment then
			M.view_comments()
		end
	end
end

--- List all draft comments in a Telescope picker.
function M.list_drafts()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.drafts or vim.tbl_isempty(state.drafts) then
		vim.notify("reviewit.nvim: No drafts", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("reviewit.nvim: telescope.nvim required for draft list", vim.log.levels.WARN)
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
		local parsed = M.parse_draft_key(key)
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
			local found = M.find_comment_by_id(parsed.comment_id, state.comment_map or {})
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
						vim.notify("reviewit.nvim: Draft deleted", vim.log.levels.INFO)
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
						local parsed = M.parse_draft_key(entry.draft_key)
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
						M.submit_drafts(to_submit, function(succeeded, failed)
							local msg, level = M.format_submit_result(succeeded, failed, #to_submit)
							vim.notify("reviewit.nvim: " .. msg, level)
							ui.refresh_extmarks()
							M.fetch_comments()
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
						ui.open_comment_input(function(body)
							M.submit_as_review(event, body, function(err, excluded_count)
								if err then
									vim.notify("reviewit.nvim: " .. err, vim.log.levels.ERROR)
									return
								end
								local msg = "Review submitted"
								if excluded_count > 0 then
									msg = msg
										.. string.format(" (%d drafts excluded: replies/PR comments)", excluded_count)
								end
								vim.notify("reviewit.nvim: " .. msg, vim.log.levels.INFO)
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
