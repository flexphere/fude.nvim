local M = {}
local config = require("reviewit.config")

local ref_ns = vim.api.nvim_create_namespace("reviewit_refs")

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
local function setup_github_refs(buf, repo_url)
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

--- Refresh extmarks (virtual text) for the current buffer.
function M.refresh_extmarks()
	local state = config.state
	if not state.active then
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local diff = require("reviewit.diff")
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)

	local comments_mod = require("reviewit.comments")
	local comment_lines = comments_mod.get_comment_lines(rel_path)

	for _, line in ipairs(comment_lines) do
		local comments = comments_mod.get_comments_at(rel_path, line)
		local count = #comments

		pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, line - 1, 0, {
			virt_text = {
				{ string.format(" %s%d", config.opts.signs.comment, count), config.opts.signs.comment_hl },
			},
			virt_text_pos = "eol",
			priority = 50,
		})
	end

	-- Draft indicators
	for key, _ in pairs(state.drafts) do
		local path, sl = key:match("^(.+):(%d+):%d+$")
		if path == rel_path then
			local draft_line = tonumber(sl)
			pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, draft_line - 1, 0, {
				virt_text = {
					{ " " .. config.opts.signs.draft, config.opts.signs.draft_hl },
				},
				virt_text_pos = "eol",
				priority = 40,
			})
		end
	end
end

--- Clear all extmarks for a specific buffer.
--- @param buf number|nil buffer handle (defaults to current)
function M.clear_extmarks(buf)
	local state = config.state
	if state.ns_id then
		pcall(vim.api.nvim_buf_clear_namespace, buf or 0, state.ns_id, 0, -1)
	end
end

--- Clear extmarks across all buffers.
function M.clear_all_extmarks()
	local state = config.state
	if not state.ns_id then
		return
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_clear_namespace, buf, state.ns_id, 0, -1)
		end
	end
end

--- Open a floating window to compose a comment.
--- @param callback fun(body: string|nil) called with comment body or nil if cancelled
--- @param opts table|nil optional settings: initial_lines, title, footer, cursor_pos
function M.open_comment_input(callback, opts)
	opts = opts or {}
	local initial_lines = opts.initial_lines or { "" }
	local title = opts.title or " Review Comment "
	local footer = opts.footer or " <CR> submit | q save draft "

	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].reviewit_comment = true

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local pct_w = config.opts.float.width or 50
	local pct_h = config.opts.float.height or 50
	local width = math.floor(vim.o.columns * pct_w / 100)
	local height = math.floor(vim.o.lines * pct_h / 100)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
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
	end, { buffer = buf, desc = "Submit review comment" })

	vim.keymap.set("n", "q", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if opts.on_cancel and body ~= "" then
			opts.on_cancel(lines)
		end
		if callback then
			callback(nil)
		end
	end, { buffer = buf, desc = "Cancel review comment" })
end

--- Open a floating window to compose an approve comment.
--- @param callback fun(body: string|nil) called with comment body (may be nil for no comment)
function M.open_approve_input(callback)
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].reviewit_comment = true

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	local pct_w = config.opts.float.width or 50
	local pct_h = config.opts.float.height or 50
	local width = math.floor(vim.o.columns * pct_w / 100)
	local height = math.floor(vim.o.lines * pct_h / 100)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.opts.float.border,
		title = " Approve PR ",
		title_pos = "center",
		footer = " <CR> approve | q cancel ",
		footer_pos = "center",
	})

	vim.cmd("startinsert")

	vim.keymap.set("n", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if callback then
			callback(body ~= "" and body or nil)
		end
	end, { buffer = buf, desc = "Approve PR" })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, desc = "Cancel approve" })
end

--- Show comments in a floating window.
--- @param comments table[] list of comment objects from GitHub API
function M.show_comments_float(comments)
	local lines = {}
	local hl_ranges = {}

	for i, comment in ipairs(comments) do
		local author = comment.user and comment.user.login or "unknown"
		local created = config.format_date(comment.created_at)

		local header = string.format("@%s  %s", author, created)
		table.insert(lines, header)
		table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })

		for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
			table.insert(lines, body_line)
		end

		if i < #comments then
			table.insert(lines, "")
			table.insert(lines, string.rep("-", 40))
			table.insert(lines, "")
		end
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local pct_w = config.opts.float.width or 50
	local pct_h = config.opts.float.height or 50
	local width = math.floor(vim.o.columns * pct_w / 100)
	local height = math.floor(vim.o.lines * pct_h / 100)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.opts.float.border,
		title = string.format(" Comments (%d) ", #comments),
		title_pos = "center",
		footer = " r reply | q close ",
		footer_pos = "center",
	})

	local ns = config.state.ns_id
	for _, hl in ipairs(hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
	end

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "r", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("reviewit.comments").reply_to_comment(last_comment.id)
		end
	end, { buffer = buf })

	setup_github_refs(buf, get_repo_base_url())
end

--- Show PR overview in a floating window.
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- @param opts table { on_new_comment: fun(), on_refresh: fun() }
function M.show_overview_float(pr_info, issue_comments, opts)
	local lines = {}
	local hl_ranges = {}

	-- PR header
	local title = string.format("PR #%d: %s", pr_info.number or 0, pr_info.title or "")
	table.insert(lines, title)
	table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })

	local author = pr_info.author and pr_info.author.login or "unknown"
	table.insert(lines, string.format("State: %s    Author: @%s", pr_info.state or "UNKNOWN", author))

	local labels = {}
	if pr_info.labels then
		for _, label in ipairs(pr_info.labels) do
			table.insert(labels, label.name or label)
		end
	end
	if #labels > 0 then
		table.insert(lines, "Labels: " .. table.concat(labels, ", "))
	end

	table.insert(lines, string.format("Base: %s <- %s", pr_info.baseRefName or "", pr_info.headRefName or ""))
	table.insert(lines, pr_info.url or "")

	-- Description
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	local desc_header_line = #lines
	table.insert(lines, "DESCRIPTION")
	table.insert(hl_ranges, { line = desc_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 50))

	local body = pr_info.body or ""
	if body == "" then
		table.insert(lines, "(no description)")
	else
		for _, body_line in ipairs(vim.split(body, "\n")) do
			table.insert(lines, body_line)
		end
	end

	-- Comments
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	local comments_header_line = #lines
	table.insert(lines, string.format("COMMENTS (%d)", #issue_comments))
	table.insert(hl_ranges, { line = comments_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 50))

	if #issue_comments == 0 then
		table.insert(lines, "(no comments)")
	else
		for i, comment in ipairs(issue_comments) do
			local comment_author = comment.user and comment.user.login or "unknown"
			local created = config.format_date(comment.created_at)

			table.insert(lines, "")
			local header = string.format("@%s  %s", comment_author, created)
			table.insert(lines, header)
			table.insert(hl_ranges, { line = #lines - 1, hl = "Special" })

			for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
				table.insert(lines, body_line)
			end

			if i < #issue_comments then
				table.insert(lines, "")
				table.insert(lines, string.rep("-", 30))
			end
		end
	end

	-- Footer
	table.insert(lines, "")
	table.insert(lines, " c: new comment  R: refresh  q: close")
	table.insert(hl_ranges, { line = #lines - 1, hl = "Comment" })

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local ov = config.opts.overview or {}
	local pct_w = ov.width or 80
	local pct_h = ov.height or 80
	local width = math.floor(vim.o.columns * pct_w / 100)
	local height = math.min(#lines + 2, math.floor(vim.o.lines * pct_h / 100))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.opts.float.border,
		title = " PR Overview ",
		title_pos = "center",
	})

	vim.wo[win].wrap = true

	local ns = config.state.ns_id or vim.api.nvim_create_namespace("reviewit")
	for _, hl in ipairs(hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
	end

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "c", function()
		vim.api.nvim_win_close(win, true)
		if opts.on_new_comment then
			opts.on_new_comment()
		end
	end, { buffer = buf, desc = "New PR comment" })

	vim.keymap.set("n", "R", function()
		vim.api.nvim_win_close(win, true)
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = buf, desc = "Refresh PR overview" })

	setup_github_refs(buf, get_repo_base_url(pr_info.url))
end

return M
