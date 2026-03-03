local M = {}
local config = require("fude.config")

local ref_ns = vim.api.nvim_create_namespace("fude_refs")

--- Get repository base URL (e.g. "https://github.com/owner/repo").
--- @param pr_url string|nil PR URL to extract from
--- @return string|nil
function M.get_repo_base_url(pr_url)
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
function M.setup_github_refs(buf, repo_url, line_urls)
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

--- Calculate centered float window dimensions from percentage-based sizes.
--- @param columns number screen width
--- @param screen_lines number screen height
--- @param pct_w number width percentage (0-100)
--- @param pct_h number height percentage (0-100)
--- @return table { width: number, height: number, row: number, col: number }
function M.calculate_float_dimensions(columns, screen_lines, pct_w, pct_h)
	local width = math.floor(columns * pct_w / 100)
	local height = math.floor(screen_lines * pct_h / 100)
	local row = math.floor((screen_lines - height) / 2)
	local col = math.floor((columns - width) / 2)
	return { width = width, height = height, row = row, col = col }
end

--- Format comment objects into display lines and highlight ranges.
--- @param comments table[] list of comment objects
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comments_for_display(comments, format_date_fn)
	local lines = {}
	local hl_ranges = {}
	for i, comment in ipairs(comments) do
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
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
	return { lines = lines, hl_ranges = hl_ranges }
end

--- Refresh extmarks (virtual text) for the current buffer.
function M.refresh_extmarks()
	local state = config.state
	if not state.active then
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local diff = require("fude.diff")
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)

	local comments_mod = require("fude.comments")
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

	-- Pending comment indicators (GitHub pending review)
	for key, _ in pairs(state.pending_comments) do
		local parsed = comments_mod.parse_draft_key(key)
		if parsed and parsed.type == "comment" and parsed.path == rel_path then
			pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, parsed.start_line - 1, 0, {
				virt_text = {
					{ " " .. config.opts.signs.pending, config.opts.signs.pending_hl },
				},
				virt_text_pos = "eol",
				priority = 45,
			})
		end
	end

	-- Draft indicators (local drafts, lower priority than pending)
	local comments_parse = comments_mod.parse_draft_key
	local comments_find = comments_mod.find_comment_by_id
	for key, _ in pairs(state.drafts) do
		-- Skip if this key is already in pending_comments
		if state.pending_comments[key] then
			goto draft_continue
		end

		local parsed = comments_parse(key)
		if not parsed then
			goto draft_continue
		end

		local draft_path, draft_line
		if parsed.type == "comment" then
			draft_path = parsed.path
			draft_line = parsed.start_line
		elseif parsed.type == "reply" then
			local found = comments_find(parsed.comment_id, state.comment_map or {})
			if found then
				draft_path = found.path
				draft_line = found.line
			end
		end

		if draft_path == rel_path and draft_line then
			pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, draft_line - 1, 0, {
				virt_text = {
					{ " " .. config.opts.signs.draft, config.opts.signs.draft_hl },
				},
				virt_text_pos = "eol",
				priority = 40,
			})
		end

		::draft_continue::
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
--- @param opts table|nil optional settings: initial_lines, title, footer, cursor_pos, submit_on_enter, on_save
function M.open_comment_input(callback, opts)
	opts = opts or {}
	local submit_on_enter = opts.submit_on_enter or false
	local initial_lines = opts.initial_lines or { "" }
	local title = opts.title or " Review Comment "
	local default_footer = submit_on_enter and " <CR> submit | q save draft " or " <CR> save draft | q cancel "
	local footer = opts.footer or default_footer

	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].fude_comment = true

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local dim = M.calculate_float_dimensions(
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
		if not submit_on_enter then
			-- Draft mode: save draft via on_save callback
			if opts.on_save and body ~= "" then
				opts.on_save(lines)
			end
		end
		if callback then
			callback(body ~= "" and body or nil)
		end
	end, { buffer = buf, desc = submit_on_enter and "Submit" or "Save draft" })

	vim.keymap.set("n", "q", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if submit_on_enter then
			-- Submit mode: save draft on cancel
			if opts.on_save and body ~= "" then
				opts.on_save(lines)
			end
		end
		-- In draft mode (default), q cancels without saving
		if callback then
			callback(nil)
		end
	end, { buffer = buf, desc = submit_on_enter and "Save draft" or "Cancel" })
end

--- Show comments in a floating window.
--- @param comments table[] list of comment objects from GitHub API
function M.show_comments_float(comments)
	local result = M.format_comments_for_display(comments, config.format_date)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local dim = M.calculate_float_dimensions(
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
		footer = " r reply | q close ",
		footer_pos = "center",
	})

	local ns = config.state.ns_id
	for _, hl in ipairs(result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
	end

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "r", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("fude.comment_actions").reply_to_comment(last_comment.id)
		end
	end, { buffer = buf })

	local km = config.opts.keymaps
	if km.next_comment then
		vim.keymap.set("n", km.next_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comment_actions").next_comment()
		end, { buffer = buf })
	end
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comment_actions").prev_comment()
		end, { buffer = buf })
	end

	M.setup_github_refs(buf, M.get_repo_base_url())
end

return M
