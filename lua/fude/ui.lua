local M = {}
local config = require("fude.config")
local format = require("fude.ui.format")
local extmarks = require("fude.ui.extmarks")

local ref_ns = vim.api.nvim_create_namespace("fude_refs")

-- Re-export format functions (facade)
M.calculate_float_dimensions = format.calculate_float_dimensions
M.format_comments_for_display = format.format_comments_for_display
M.normalize_check = format.normalize_check
M.format_check_status = format.format_check_status
M.deduplicate_checks = format.deduplicate_checks
M.sort_checks = format.sort_checks
M.build_checks_summary = format.build_checks_summary
M.format_review_status = format.format_review_status
M.build_reviewers_list = format.build_reviewers_list
M.build_reviewers_summary = format.build_reviewers_summary
M.calculate_overview_layout = format.calculate_overview_layout
M.calculate_comments_height = format.calculate_comments_height
M.calculate_reply_window_dimensions = format.calculate_reply_window_dimensions
M.format_reply_comments_for_display = format.format_reply_comments_for_display
M.build_overview_left_lines = format.build_overview_left_lines
M.build_overview_right_lines = format.build_overview_right_lines

-- Re-export extmark functions (facade)
M.flash_line = extmarks.flash_line
M.highlight_comment_lines = extmarks.highlight_comment_lines
M.clear_comment_line_highlight = extmarks.clear_comment_line_highlight
M.refresh_extmarks = extmarks.refresh_extmarks
M.clear_extmarks = extmarks.clear_extmarks
M.clear_all_extmarks = extmarks.clear_all_extmarks

--- Synchronously set preview buffer in Telescope to avoid one-tick delay.
--- Telescope defers win_set_buf via vim.schedule for new buffers; calling
--- nvim_win_set_buf directly with eventignore suppressed fixes this.
--- @param previewer_self table the `self` argument inside define_preview
function M.sync_preview_buffer(previewer_self)
	if previewer_self.state.winid and vim.api.nvim_win_is_valid(previewer_self.state.winid) then
		local save_ei = vim.o.eventignore
		vim.o.eventignore = "all"
		local ok = pcall(vim.api.nvim_win_set_buf, previewer_self.state.winid, previewer_self.state.bufnr)
		vim.o.eventignore = save_ei
		if not ok then
			return
		end
	end
end

--- Get repository base URL (e.g. "https://github.com/owner/repo").
--- @param pr_url string|nil PR URL to extract from
--- @return string|nil
local function get_repo_base_url(pr_url)
	local url = pr_url or config.state.pr_url
	if url then
		return url:match("(https://github%.com/[^/]+/[^/]+)")
	end
	return nil
end

--- Highlight GitHub references (#123) and URLs in a buffer, and set up gx keymap.
--- @param buf number buffer handle
--- @param repo_url string|nil repository base URL
--- @param line_urls table|nil optional mapping of 0-indexed line number to URL
local function setup_github_refs(buf, repo_url, line_urls)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	for i, line in ipairs(lines) do
		-- Highlight #\d+ references
		local start = 1
		while true do
			local s, e = line:find("#%d+", start)
			if not s then
				break
			end
			pcall(vim.api.nvim_buf_add_highlight, buf, ref_ns, "Underlined", i - 1, s - 1, e)
			start = e + 1
		end
		-- Highlight URLs
		start = 1
		while true do
			local s, e = line:find("https?://[%w%.%-/%%_%?&=#~:@!%$%(%)%*%+,;]+", start)
			if not s then
				break
			end
			pcall(vim.api.nvim_buf_add_highlight, buf, ref_ns, "Underlined", i - 1, s - 1, e)
			start = e + 1
		end
	end

	vim.keymap.set("n", "gx", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local row, col = cursor[1], cursor[2]
		local current_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

		-- Check line-level URL mapping (e.g. CI check detailsUrl)
		if line_urls and line_urls[row - 1] then
			vim.ui.open(line_urls[row - 1])
			return
		end

		-- Check #\d+ reference under cursor
		if repo_url then
			for s, num, e in current_line:gmatch("()#(%d+)()") do
				if col >= s - 1 and col < e - 1 then
					vim.ui.open(repo_url .. "/issues/" .. num)
					return
				end
			end
		end

		-- Check URL under cursor
		for url in current_line:gmatch("https?://[%w%.%-/%%_%?&=#~:@!%$%(%)%*%+,;]+") do
			local s, e = current_line:find(url, 1, true)
			if s and col >= s - 1 and col < e then
				vim.ui.open(url)
				return
			end
		end
	end, { buffer = buf, desc = "Open GitHub reference" })
end

--- Select review event type using vim.ui.select.
--- @param callback fun(event: string|nil) called with "COMMENT", "APPROVE", "REQUEST_CHANGES", or nil if cancelled
function M.select_review_event(callback)
	local items = {
		{ label = "Comment", value = "COMMENT" },
		{ label = "Approve", value = "APPROVE" },
		{ label = "Request Changes", value = "REQUEST_CHANGES" },
	}
	vim.ui.select(items, {
		prompt = "Review type:",
		format_item = function(item)
			return item.label
		end,
	}, function(item)
		if item then
			callback(item.value)
		else
			callback(nil)
		end
	end)
end

--- Open a floating window to compose a comment.
--- @param callback fun(body: string|nil) called with comment body or nil if cancelled
--- @param opts table|nil optional settings: initial_lines, title, footer, cursor_pos
function M.open_comment_input(callback, opts)
	opts = opts or {}
	local initial_lines = opts.initial_lines or { "" }
	local title = opts.title or " Review Comment "
	local footer = opts.footer or " <CR> save | q cancel "

	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].fude_comment = true

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = dim.height,
		style = "minimal",
		border = config.opts.float.border,
		title = title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})

	vim.cmd("startinsert")

	if opts.cursor_pos then
		vim.cmd("stopinsert")
		vim.api.nvim_win_set_cursor(win, opts.cursor_pos)
	end

	vim.keymap.set("n", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if callback then
			callback(body ~= "" and body or nil)
		end
	end, { buffer = buf, desc = "Save" })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		if callback then
			callback(nil)
		end
	end, { buffer = buf, desc = "Cancel" })
end

--- Show comments in a floating window.
--- @param comments table[] list of comment objects from GitHub API
--- @param opts table|nil { source_buf?: number, source_start_line?: number, source_end_line?: number }
function M.show_comments_float(comments, opts)
	opts = opts or {}
	local result = format.format_comments_for_display(comments, config.format_date)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = dim.height,
		style = "minimal",
		border = config.opts.float.border,
		title = string.format(" Comments (%d) ", #comments),
		title_pos = "center",
		footer = " r reply | e edit | d delete | q close ",
		footer_pos = "center",
	})

	-- Highlight the source lines while the comment float is open
	if opts.source_buf and opts.source_start_line then
		local end_line = opts.source_end_line or opts.source_start_line
		M.highlight_comment_lines(opts.source_buf, opts.source_start_line, end_line)
	end

	local ns = config.state.ns_id
	for _, hl in ipairs(result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
	end

	-- Clear highlight when window is closed
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			M.clear_comment_line_highlight()
		end,
	})

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "r", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").reply_to_comment(last_comment.id)
		end
	end, { buffer = buf })

	vim.keymap.set("n", "e", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").edit_comment(last_comment.id)
		end
	end, { buffer = buf, desc = "Edit comment" })

	vim.keymap.set("n", "d", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").delete_comment(last_comment.id)
		end
	end, { buffer = buf, desc = "Delete comment" })

	local km = config.opts.keymaps
	if km.next_comment then
		vim.keymap.set("n", km.next_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comments").next_comment()
		end, { buffer = buf })
	end
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comments").prev_comment()
		end, { buffer = buf })
	end

	setup_github_refs(buf, get_repo_base_url())
end

--- Show PR overview in a split-pane floating window.
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- @param opts table { on_new_comment: fun(), on_refresh: fun() }
function M.show_overview_float(pr_info, issue_comments, opts)
	local left_result = format.build_overview_left_lines(pr_info, issue_comments, config.format_date)
	local right_result = format.build_overview_right_lines(pr_info)

	-- Create left buffer
	local left_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_result.lines)
	vim.bo[left_buf].modifiable = false
	vim.bo[left_buf].buftype = "nofile"
	vim.bo[left_buf].bufhidden = "wipe"
	vim.bo[left_buf].filetype = "markdown"

	-- Create right buffer
	local right_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_result.lines)
	vim.bo[right_buf].modifiable = false
	vim.bo[right_buf].buftype = "nofile"
	vim.bo[right_buf].bufhidden = "wipe"
	vim.bo[right_buf].filetype = "markdown"

	-- Calculate split-pane layout
	local ov = config.opts.overview or {}
	local layout =
		format.calculate_overview_layout(vim.o.columns, vim.o.lines, ov.width or 80, ov.height or 80, ov.right_width or 30)

	-- Use the taller content, capped at max layout height
	local content_height = math.min(math.max(#left_result.lines, #right_result.lines) + 2, layout.left.height)
	local row = math.floor((vim.o.lines - content_height) / 2)

	-- Open left window (focused)
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		row = row,
		col = layout.left.col,
		width = layout.left.width,
		height = content_height,
		style = "minimal",
		border = config.opts.float.border,
		title = " PR Overview ",
		title_pos = "center",
	})
	vim.wo[left_win].wrap = true

	-- Open right window (not focused)
	local right_win = vim.api.nvim_open_win(right_buf, false, {
		relative = "editor",
		row = row,
		col = layout.right.col,
		width = layout.right.width,
		height = content_height,
		style = "minimal",
		border = config.opts.float.border,
	})
	vim.wo[right_win].wrap = true

	-- Apply highlights
	local ns = config.state.ns_id or vim.api.nvim_create_namespace("fude")
	for _, hl in ipairs(left_result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, 0, -1)
	end
	for _, hl in ipairs(right_result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, right_buf, ns, hl.hl, hl.line, 0, -1)
	end

	-- Set section marks (left pane only)
	local marks = ov.marks or { description = "d", comments = "c" }
	for section, mark in pairs(marks) do
		local line = left_result.sections[section]
		if line and mark then
			vim.api.nvim_buf_set_mark(left_buf, mark, line, 0, {})
		end
	end

	-- Close both windows helper
	local closing = false
	local function close_both()
		if closing then
			return
		end
		closing = true
		pcall(vim.api.nvim_win_close, left_win, true)
		pcall(vim.api.nvim_win_close, right_win, true)
	end

	-- WinClosed autocmd to close partner window (unique per instance)
	local augroup = vim.api.nvim_create_augroup("fude_overview_" .. left_win, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == left_win or closed_win == right_win then
				close_both()
				vim.api.nvim_del_augroup_by_id(augroup)
			end
		end,
	})

	-- Keymaps for left buffer
	vim.keymap.set("n", "q", close_both, { buffer = left_buf })

	vim.keymap.set("n", "C", function()
		close_both()
		if opts.on_new_comment then
			opts.on_new_comment()
		end
	end, { buffer = left_buf, desc = "New PR comment" })

	vim.keymap.set("n", "R", function()
		close_both()
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = left_buf, desc = "Refresh PR overview" })

	-- Tab to switch between panes
	vim.keymap.set("n", "<Tab>", function()
		vim.api.nvim_set_current_win(right_win)
	end, { buffer = left_buf, desc = "Switch to right pane" })

	vim.keymap.set("n", "<Tab>", function()
		vim.api.nvim_set_current_win(left_win)
	end, { buffer = right_buf, desc = "Switch to left pane" })

	-- Section jump keymaps (left pane)
	local section_lines = {}
	for _, line in pairs(left_result.sections) do
		table.insert(section_lines, line)
	end
	table.sort(section_lines)

	vim.keymap.set("n", "]s", function()
		local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
		for _, line in ipairs(section_lines) do
			if line > cur_line then
				vim.api.nvim_win_set_cursor(left_win, { line, 0 })
				return
			end
		end
	end, { buffer = left_buf, desc = "Next section" })

	vim.keymap.set("n", "[s", function()
		local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
		for i = #section_lines, 1, -1 do
			if section_lines[i] < cur_line then
				vim.api.nvim_win_set_cursor(left_win, { section_lines[i], 0 })
				return
			end
		end
	end, { buffer = left_buf, desc = "Previous section" })

	-- Comment navigation keymaps (left pane only — navigate between issue comments)
	local comment_lines = left_result.comment_positions
	local km = config.opts.keymaps
	if km.next_comment and #comment_lines > 0 then
		vim.keymap.set("n", km.next_comment, function()
			local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
			for _, line in ipairs(comment_lines) do
				if line > cur_line then
					vim.api.nvim_win_set_cursor(left_win, { line, 0 })
					return
				end
			end
			-- Wrap around to first comment
			vim.api.nvim_win_set_cursor(left_win, { comment_lines[1], 0 })
		end, { buffer = left_buf, desc = "Next comment" })
	end
	if km.prev_comment and #comment_lines > 0 then
		vim.keymap.set("n", km.prev_comment, function()
			local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
			for i = #comment_lines, 1, -1 do
				if comment_lines[i] < cur_line then
					vim.api.nvim_win_set_cursor(left_win, { comment_lines[i], 0 })
					return
				end
			end
			-- Wrap around to last comment
			vim.api.nvim_win_set_cursor(left_win, { comment_lines[#comment_lines], 0 })
		end, { buffer = left_buf, desc = "Previous comment" })
	end

	-- Keymaps for right buffer
	vim.keymap.set("n", "q", close_both, { buffer = right_buf })

	vim.keymap.set("n", "R", function()
		close_both()
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = right_buf, desc = "Refresh PR overview" })

	-- GitHub refs for both panes
	setup_github_refs(left_buf, get_repo_base_url(pr_info.url))
	setup_github_refs(right_buf, get_repo_base_url(pr_info.url), right_result.check_urls)
end

--- Setup highlight groups for reply window.
function M.setup_reply_highlights()
	vim.api.nvim_set_hl(0, "ReviewCommentAuthor", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "ReviewCommentTimestamp", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "ReviewCommentBody", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "ReviewReplyBorder", { link = "FloatBorder", default = true })
end

--- Close reply window and cleanup.
--- @param state_reply table reply_window state table
local function close_reply_window(state_reply)
	if state_reply.closing then
		return
	end
	state_reply.closing = true

	if state_reply.upper_win and vim.api.nvim_win_is_valid(state_reply.upper_win) then
		pcall(vim.api.nvim_win_close, state_reply.upper_win, true)
	end
	if state_reply.lower_win and vim.api.nvim_win_is_valid(state_reply.lower_win) then
		pcall(vim.api.nvim_win_close, state_reply.lower_win, true)
	end

	state_reply.upper_win = nil
	state_reply.upper_buf = nil
	state_reply.lower_win = nil
	state_reply.lower_buf = nil
	state_reply.closing = false
end

--- Open a two-pane edit window (thread above, editable comment below).
--- @param thread table[] list of comment objects in the thread
--- @param comment table the specific comment to edit
--- @param opts table { on_submit: fun(body: string) }
function M.open_edit_window(thread, comment, opts)
	opts = opts or {}
	local state = config.state

	-- Close if already open (shares state.reply_window)
	if state.reply_window and state.reply_window.upper_win then
		close_reply_window(state.reply_window)
	end

	M.setup_reply_highlights()

	-- Format thread for upper pane
	local result = format.format_reply_comments_for_display(thread, config.format_date)

	-- Calculate dimensions
	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	-- Split height: lower is fixed 12 lines, upper gets the rest
	local lower_height = 12
	local upper_height = math.max(3, dim.height - lower_height)

	-- Create upper buffer (readonly thread)
	local upper_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(upper_buf, 0, -1, false, result.lines)
	vim.bo[upper_buf].modifiable = false
	vim.bo[upper_buf].buftype = "nofile"
	vim.bo[upper_buf].bufhidden = "wipe"
	vim.bo[upper_buf].filetype = "markdown"

	-- Create lower buffer (editable, pre-filled with comment body)
	local lower_buf = vim.api.nvim_create_buf(false, true)
	local initial_lines = vim.split(comment.body or "", "\n")
	vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, initial_lines)
	vim.bo[lower_buf].buftype = "nofile"
	vim.bo[lower_buf].bufhidden = "wipe"
	vim.bo[lower_buf].filetype = "markdown"
	vim.b[lower_buf].fude_comment = true

	-- Border definitions: upper has no bottom, lower connects
	local upper_border = { "╭", "─", "╮", "│", "", "", "", "│" }
	local lower_border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" }

	-- Open upper window
	local upper_win = vim.api.nvim_open_win(upper_buf, false, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = upper_height,
		style = "minimal",
		border = upper_border,
		title = " Thread ",
		title_pos = "center",
	})
	vim.wo[upper_win].wrap = true
	vim.wo[upper_win].cursorline = false

	-- Open lower window
	local lower_win = vim.api.nvim_open_win(lower_buf, true, {
		relative = "editor",
		row = dim.row + upper_height,
		col = dim.col,
		width = dim.width,
		height = lower_height,
		style = "minimal",
		border = lower_border,
		title = " Edit Comment ",
		title_pos = "center",
		footer = " <CR> save | q cancel | <Tab> switch | <C-u/d> scroll ",
		footer_pos = "center",
	})

	-- Save state (shared with reply_window)
	state.reply_window = {
		upper_win = upper_win,
		upper_buf = upper_buf,
		lower_win = lower_win,
		lower_buf = lower_buf,
		closing = false,
	}

	-- Apply highlights
	local ns = state.ns_id or vim.api.nvim_create_namespace("fude")
	for _, hl in ipairs(result.hl_ranges) do
		if hl.col_start and hl.col_end then
			pcall(vim.api.nvim_buf_add_highlight, upper_buf, ns, hl.hl, hl.line, hl.col_start, hl.col_end)
		else
			pcall(vim.api.nvim_buf_add_highlight, upper_buf, ns, hl.hl, hl.line, 0, -1)
		end
	end

	setup_github_refs(upper_buf, get_repo_base_url())

	-- Helper to close both windows
	local function close_all()
		close_reply_window(state.reply_window)
	end

	-- Submit handler
	local function submit()
		local lines = vim.api.nvim_buf_get_lines(lower_buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		close_all()
		if body ~= "" and opts.on_submit then
			opts.on_submit(body)
		end
	end

	-- Cancel handler
	local function cancel()
		close_all()
	end

	-- Helper to scroll upper window from lower
	local function scroll_upper(keys)
		local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
		return function()
			if vim.api.nvim_win_is_valid(upper_win) then
				vim.api.nvim_win_call(upper_win, function()
					vim.cmd("normal! " .. termcodes)
				end)
			end
		end
	end

	-- Lower window keymaps
	vim.keymap.set("n", "<CR>", submit, { buffer = lower_buf, desc = "Save edit" })
	vim.keymap.set("n", "q", cancel, { buffer = lower_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = lower_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(upper_win) then
			vim.api.nvim_set_current_win(upper_win)
		end
	end, { buffer = lower_buf, desc = "Go to thread" })
	vim.keymap.set(
		{ "n", "i" },
		"<C-u>",
		scroll_upper("<C-u>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread up" }
	)
	vim.keymap.set(
		{ "n", "i" },
		"<C-d>",
		scroll_upper("<C-d>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread down" }
	)

	-- Upper window keymaps
	vim.keymap.set("n", "q", cancel, { buffer = upper_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = upper_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(lower_win) then
			vim.api.nvim_set_current_win(lower_win)
		end
	end, { buffer = upper_buf, desc = "Go to input" })

	-- Autocmd: close both when one closes
	local augroup = vim.api.nvim_create_augroup("fude_edit_window_" .. lower_win, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		pattern = { tostring(upper_win), tostring(lower_win) },
		callback = function()
			vim.schedule(function()
				close_all()
				pcall(vim.api.nvim_del_augroup_by_id, augroup)
			end)
		end,
	})

	-- Start in normal mode (cursor at beginning of pre-filled content)
	vim.api.nvim_win_set_cursor(lower_win, { 1, 0 })
end

--- Open a two-pane reply window (existing comments above, input below).
--- @param comments table[] list of comment objects
--- @param opts table { on_submit: fun(body: string), filetype?: string,
---   width?: number }
function M.open_reply_window(comments, opts)
	opts = opts or {}
	local state = config.state

	-- Close if already open
	if state.reply_window and state.reply_window.upper_win then
		close_reply_window(state.reply_window)
	end

	M.setup_reply_highlights()

	-- Format comments
	local result = format.format_reply_comments_for_display(comments, config.format_date)

	-- Calculate dimensions
	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	-- Split height: lower is fixed 12 lines, upper gets the rest
	local lower_height = 12
	local upper_height = math.max(3, dim.height - lower_height)

	-- Create upper buffer (readonly comments)
	local upper_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(upper_buf, 0, -1, false, result.lines)
	vim.bo[upper_buf].modifiable = false
	vim.bo[upper_buf].buftype = "nofile"
	vim.bo[upper_buf].bufhidden = "wipe"
	vim.bo[upper_buf].filetype = opts.filetype or "markdown"

	-- Create lower buffer (editable input)
	local lower_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, { "" })
	vim.bo[lower_buf].buftype = "nofile"
	vim.bo[lower_buf].bufhidden = "wipe"
	vim.bo[lower_buf].filetype = opts.filetype or "markdown"
	vim.b[lower_buf].fude_comment = true

	-- Border definitions: upper has no bottom, lower connects
	local upper_border = { "╭", "─", "╮", "│", "", "", "", "│" }
	local lower_border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" }

	-- Open upper window
	local upper_win = vim.api.nvim_open_win(upper_buf, false, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = upper_height,
		style = "minimal",
		border = upper_border,
		title = " Thread ",
		title_pos = "center",
	})
	vim.wo[upper_win].wrap = true
	vim.wo[upper_win].cursorline = false

	-- Open lower window
	local lower_win = vim.api.nvim_open_win(lower_buf, true, {
		relative = "editor",
		row = dim.row + upper_height,
		col = dim.col,
		width = dim.width,
		height = lower_height,
		style = "minimal",
		border = lower_border,
		title = " Reply ",
		title_pos = "center",
		footer = " <CR> submit | q cancel | <Tab> switch | <C-u/d> scroll ",
		footer_pos = "center",
	})

	-- Save state
	state.reply_window = {
		upper_win = upper_win,
		upper_buf = upper_buf,
		lower_win = lower_win,
		lower_buf = lower_buf,
		closing = false,
	}

	-- Apply highlights
	local ns = state.ns_id or vim.api.nvim_create_namespace("fude")
	for _, hl in ipairs(result.hl_ranges) do
		if hl.col_start and hl.col_end then
			pcall(vim.api.nvim_buf_add_highlight, upper_buf, ns, hl.hl, hl.line, hl.col_start, hl.col_end)
		else
			pcall(vim.api.nvim_buf_add_highlight, upper_buf, ns, hl.hl, hl.line, 0, -1)
		end
	end

	setup_github_refs(upper_buf, get_repo_base_url())

	-- Helper to close both windows
	local function close_all()
		close_reply_window(state.reply_window)
	end

	-- Submit handler
	local function submit()
		local lines = vim.api.nvim_buf_get_lines(lower_buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		close_all()
		if body ~= "" and opts.on_submit then
			opts.on_submit(body)
		end
	end

	-- Cancel handler
	local function cancel()
		close_all()
	end

	-- Helper to scroll upper window from lower
	local function scroll_upper(keys)
		local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
		return function()
			if vim.api.nvim_win_is_valid(upper_win) then
				vim.api.nvim_win_call(upper_win, function()
					vim.cmd("normal! " .. termcodes)
				end)
			end
		end
	end

	-- Lower window keymaps
	vim.keymap.set("n", "<CR>", submit, { buffer = lower_buf, desc = "Submit reply" })
	vim.keymap.set("n", "q", cancel, { buffer = lower_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = lower_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(upper_win) then
			vim.api.nvim_set_current_win(upper_win)
		end
	end, { buffer = lower_buf, desc = "Go to comments" })
	vim.keymap.set(
		{ "n", "i" },
		"<C-u>",
		scroll_upper("<C-u>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread up" }
	)
	vim.keymap.set(
		{ "n", "i" },
		"<C-d>",
		scroll_upper("<C-d>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread down" }
	)

	-- Upper window keymaps
	vim.keymap.set("n", "q", cancel, { buffer = upper_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = upper_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(lower_win) then
			vim.api.nvim_set_current_win(lower_win)
		end
	end, { buffer = upper_buf, desc = "Go to input" })

	-- Autocmd: close both when one closes
	local augroup = vim.api.nvim_create_augroup("fude_reply_window", { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		pattern = tostring(upper_win) .. "," .. tostring(lower_win),
		callback = function()
			vim.schedule(function()
				close_all()
				pcall(vim.api.nvim_del_augroup_by_id, augroup)
			end)
		end,
	})

	-- Start in insert mode
	vim.cmd("startinsert")
end

return M
