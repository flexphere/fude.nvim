local M = {}
local config = require("reviewit.config")
local gh = require("reviewit.gh")
local diff = require("reviewit.diff")
local ui = require("reviewit.ui")

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
		state.comment_map = {}

		for _, comment in ipairs(state.comments) do
			local path = comment.path
			local line = comment.line or comment.original_line
			if path and line then
				if not state.comment_map[path] then
					state.comment_map[path] = {}
				end
				if not state.comment_map[path][line] then
					state.comment_map[path][line] = {}
				end
				table.insert(state.comment_map[path][line], comment)
			end
		end

		ui.refresh_extmarks()
		vim.notify(
			string.format("reviewit.nvim: Loaded %d comments", #state.comments),
			vim.log.levels.INFO
		)
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
		table.insert(lines, line)
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

	ui.open_comment_input(function(body)
		if not body then
			return
		end

		local sha, sha_err = gh.get_head_sha()
		if not sha then
			vim.notify("reviewit.nvim: " .. (sha_err or "Unknown error"), vim.log.levels.ERROR)
			return
		end

		local on_complete = function(post_err, _)
			if post_err then
				vim.notify("reviewit.nvim: Failed to post comment: " .. post_err, vim.log.levels.ERROR)
				return
			end
			vim.notify("reviewit.nvim: Comment posted", vim.log.levels.INFO)
			M.fetch_comments()
		end

		if start_line == end_line then
			gh.create_comment(state.pr_number, sha, rel_path, end_line, body, on_complete)
		else
			gh.create_comment_range(state.pr_number, sha, rel_path, start_line, end_line, body, on_complete)
		end
	end)
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

	ui.open_comment_input(function(body)
		if not body then
			return
		end

		gh.reply_to_comment(state.pr_number, comment_id, body, function(err, _)
			if err then
				vim.notify("reviewit.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("reviewit.nvim: Reply posted", vim.log.levels.INFO)
			M.fetch_comments()
		end)
	end)
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

	for _, line in ipairs(comment_lines) do
		if line > current_line then
			vim.api.nvim_win_set_cursor(0, { line, 0 })
			return
		end
	end

	if #comment_lines > 0 then
		vim.api.nvim_win_set_cursor(0, { comment_lines[1], 0 })
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

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 16 },
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
			local line = tonumber(line_key) or 0
			local first = comments[1]
			local last = comments[#comments]
			local author = first.user and first.user.login or "unknown"
			local last_ts = last.created_at or ""
			-- "2025-02-28T23:01:00Z" -> "2025/02/28 23:01"
			local last_date
			local y, md, hm = last_ts:match("^(%d%d%d%d)%-(%d%d%-%d%d)T(%d%d:%d%d)")
			if y then
				last_date = y .. "/" .. md:gsub("%-", "/") .. " " .. hm
			else
				last_date = last_ts:sub(1, 10)
			end
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
						local c_author = comment.user and comment.user.login or "unknown"
						local ts = comment.created_at or ""
						local c_y, c_md, c_hm = ts:match("^(%d%d%d%d)%-(%d%d%-%d%d)T(%d%d:%d%d)")
						local date = c_y and (c_y .. "/" .. c_md:gsub("%-", "/") .. " " .. c_hm) or ts:sub(1, 10)
						table.insert(preview_lines, string.format("── @%s (%s) ──", c_author, date))
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
						vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
					end
				end)
				return true
			end,
		})
		:find()
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

	for i = #comment_lines, 1, -1 do
		if comment_lines[i] < current_line then
			vim.api.nvim_win_set_cursor(0, { comment_lines[i], 0 })
			return
		end
	end

	if #comment_lines > 0 then
		vim.api.nvim_win_set_cursor(0, { comment_lines[#comment_lines], 0 })
	end
end

return M
