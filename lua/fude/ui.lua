local M = {}
local config = require("fude.config")
local format = require("fude.ui.format")
local inline = require("fude.ui.inline")
local extmarks = require("fude.ui.extmarks")
local data = require("fude.comments.data")
local util = require("fude.util")

local ref_ns = vim.api.nvim_create_namespace("fude_refs")

-- Re-export format functions (facade)
M.calculate_float_dimensions = format.calculate_float_dimensions
M.format_line_range = format.format_line_range
M.build_range_start_marker = format.build_range_start_marker
M.format_comments_for_display = format.format_comments_for_display
M.build_comment_avatar_position = format.build_comment_avatar_position
M.build_comments_float_title = format.build_comments_float_title
M.normalize_check = format.normalize_check
M.format_check_status = format.format_check_status
M.deduplicate_checks = format.deduplicate_checks
M.sort_checks = format.sort_checks
M.build_checks_summary = format.build_checks_summary
M.format_review_status = format.format_review_status
M.COMMENTED_MARK = format.COMMENTED_MARK
M.build_reviewers_list = format.build_reviewers_list
M.build_centered_lines = format.build_centered_lines
M.build_re_request_candidates = format.build_re_request_candidates
M.build_reviewer_entries = format.build_reviewer_entries
M.COPILOT_REVIEWER = format.COPILOT_REVIEWER
M.is_copilot_login = format.is_copilot_login
M.reviewer_display_name = format.reviewer_display_name
M.build_label_entries = format.build_label_entries
M.format_toggle_entry = format.format_toggle_entry
M.format_reviewer_mark = format.format_reviewer_mark
M.build_reviewers_summary = format.build_reviewers_summary
M.calculate_overview_layout = format.calculate_overview_layout
M.calculate_overview_full_width = format.calculate_overview_full_width
M.calculate_comments_height = format.calculate_comments_height
M.calculate_reply_window_dimensions = format.calculate_reply_window_dimensions
M.format_reply_comments_for_display = format.format_reply_comments_for_display
M.build_overview_left_lines = format.build_overview_left_lines
M.build_overview_right_lines = format.build_overview_right_lines
M.build_overview_ci_lines = format.build_overview_ci_lines
M.calculate_comment_browser_layout = format.calculate_comment_browser_layout
M.format_comment_browser_list = format.format_comment_browser_list
M.format_comment_browser_thread = format.format_comment_browser_thread
M.find_comment_index_at_line = format.find_comment_index_at_line
M.format_comments_for_inline = inline.format_comments_for_inline
M.parse_markdown_line = format.parse_markdown_line
M.build_highlighted_chunks = format.build_highlighted_chunks
M.apply_markdown_highlight_to_line = format.apply_markdown_highlight_to_line

-- Re-export extmark functions (facade)
M.flash_line = extmarks.flash_line
M.highlight_comment_lines = extmarks.highlight_comment_lines
M.clear_comment_line_highlight = extmarks.clear_comment_line_highlight
M.refresh_extmarks = extmarks.refresh_extmarks
M.clear_extmarks = extmarks.clear_extmarks
M.clear_all_extmarks = extmarks.clear_all_extmarks
M.refresh_visible_extmarks = extmarks.refresh_visible_extmarks
M.setup_inline_hint_autocmd = extmarks.setup_inline_hint_autocmd
M.teardown_inline_hint_autocmd = extmarks.teardown_inline_hint_autocmd

--- Compare current buffer lines against original lines (trimmed) and return
--- whether they differ. Used to decide if a discard confirmation should be shown.
--- nil/empty `original_lines` is treated as empty input.
--- @param current_lines string[]
--- @param original_lines string[]|nil
--- @return boolean
function M.should_confirm_discard(current_lines, original_lines)
	local function normalize(lines)
		if not lines then
			return ""
		end
		return vim.trim(table.concat(lines, "\n"))
	end
	return normalize(current_lines) ~= normalize(original_lines)
end

--- Choices shown when closing a comment buffer that has unsaved changes and
--- local drafts are enabled.
local DRAFT_CLOSE_CHOICES = { "Save draft & close", "Discard & close", "Keep editing" }

--- Prompt for how to close a dirty input buffer and route the decision.
--- When `allow_draft` is true a 3-way choice (save draft / discard / keep) is
--- shown; otherwise a plain Yes/No discard confirmation (the pre-draft UX).
--- Prompt texts default to the comment wording; callers for other content
--- (e.g. the PR float) pass their own via `prompts`.
--- @param allow_draft boolean
--- @param on_save fun() chosen "save draft & close"
--- @param on_discard fun() chosen "discard & close"
--- @param prompts { unsaved?: string, discard?: string }|nil prompt overrides
function M.prompt_close_decision(allow_draft, on_save, on_discard, prompts)
	prompts = prompts or {}
	if allow_draft then
		vim.ui.select(DRAFT_CLOSE_CHOICES, { prompt = prompts.unsaved or "Unsaved comment:" }, function(choice)
			if choice == DRAFT_CLOSE_CHOICES[1] then
				on_save()
			elseif choice == DRAFT_CLOSE_CHOICES[2] then
				on_discard()
			end
		end)
	else
		vim.ui.select({ "Yes", "No" }, { prompt = prompts.discard or "Discard comment?" }, function(choice)
			if choice == "Yes" then
				on_discard()
			end
		end)
	end
end

--- If the buffer differs from `original_lines`, prompt how to close it
--- (optionally offering to save a local draft) and run the matching handler.
--- When not dirty (or the buffer is gone) it closes immediately without
--- touching any existing draft.
--- @param buf number
--- @param original_lines string[]|nil
--- @param opts { allow_draft?: boolean, on_save_draft?: fun(text: string), on_discard?: fun(), on_close: fun() }
function M.confirm_close_with_draft(buf, original_lines, opts)
	opts = opts or {}
	local function close()
		if opts.on_close then
			opts.on_close()
		end
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		close()
		return
	end
	local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if not M.should_confirm_discard(current, original_lines) then
		close()
		return
	end
	M.prompt_close_decision(opts.allow_draft, function()
		if opts.on_save_draft then
			opts.on_save_draft(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		end
		close()
	end, function()
		if opts.on_discard then
			opts.on_discard()
		end
		close()
	end)
end

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

--- Snapshot the review state that decides whether a shown comment is on
--- GitHub. UIs take it when they render comments and pass it to
--- `open_comment_in_browser`: they can stay open across `:FudeReviewStop`,
--- whose `reset_state()` clears `pending_review_id`, so reading the live state
--- on `o` would open an unpublished pending comment's URL.
--- @return { pending_review_id: number|nil, is_local: boolean, pr_url: string|nil }
function M.capture_open_context()
	local state = config.state
	return {
		pending_review_id = state.pending_review_id,
		is_local = state.review_mode == "local",
		pr_url = state.pr_url,
	}
end

--- Open a comment's GitHub page, or explain why it has none (local review,
--- pending review, no comment under the cursor).
--- @param comment table|nil
--- @param ctx table from capture_open_context, taken when the comment was shown
function M.open_comment_in_browser(comment, ctx)
	util.open_url(data.find_comment_url(comment, ctx.pending_review_id, ctx.is_local))
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
--- @param callback fun(body: string|nil, action: string) called with comment body or nil if cancelled
--- @param opts table|nil optional settings: initial_lines, title, footer, cursor_pos,
---   pick_submit_kind (fun(cb: fun(kind: string|nil))): asked on <CR> with a non-empty
---   body; cb(kind) closes the input and passes kind as the action, cb(nil) keeps it open
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

	local function finish(action)
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if not callback then
			return
		end
		if action == "submit" or action == "review" or action == "single" then
			local body = vim.trim(text)
			callback(body ~= "" and body or nil, action)
		elseif action == "draft" then
			callback(text, "draft")
		else
			callback(nil, action)
		end
	end

	vim.keymap.set("n", "<CR>", function()
		local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		if not opts.pick_submit_kind or body == "" then
			finish("submit")
			return
		end
		-- Ask before closing so cancelling the choice keeps the input open.
		opts.pick_submit_kind(function(kind)
			if kind and vim.api.nvim_win_is_valid(win) then
				finish(kind)
			end
		end)
	end, { buffer = buf, desc = "Save" })

	local function close_input()
		local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if not M.should_confirm_discard(current, initial_lines) then
			finish("cancel")
			return
		end
		M.prompt_close_decision(opts.allow_draft, function()
			finish("draft")
		end, function()
			finish("discard")
		end)
	end

	vim.keymap.set("n", "q", close_input, { buffer = buf, desc = "Cancel" })
	vim.keymap.set("n", "<Esc>", close_input, { buffer = buf, desc = "Cancel" })
end

--- Show comments in a floating window.
--- @param comments table[] list of comment objects from GitHub API
--- @param opts table|nil { source_buf?: number, source_start_line?: number, source_end_line?: number }
function M.show_comments_float(comments, opts)
	opts = opts or {}

	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)
	-- The separator spans the window width.
	local result = format.format_comments_for_display(comments, config.format_date, dim.width)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	-- Lets `close_comment_ui` find viewer floats: they show working-tree
	-- comments, which the local commit scope must not keep on screen.
	vim.b[buf].fude_comment_view = true
	-- Comment authors' avatars (images.comment)
	require("fude.ui.avatars").place(buf, result.avatar_positions)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = dim.height,
		style = "minimal",
		border = config.opts.float.border,
		title = format.build_comments_float_title(comments, config.opts.resolved),
		title_pos = "center",
		footer = " r reply | e edit | d delete | R resolve | + react | o open | q close ",
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

	-- Redraw the comments in place (after a reaction changed), keeping the
	-- cursor where it is.
	local function rerender()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		result = format.format_comments_for_display(comments, config.format_date, dim.width)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
		vim.bo[buf].modifiable = false
		if ns then
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
			for _, hl in ipairs(result.hl_ranges) do
				pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
			end
		end
		local avatars = require("fude.ui.avatars")
		avatars.clear(buf)
		avatars.place(buf, result.avatar_positions)
		vim.api.nvim_buf_clear_namespace(buf, ref_ns, 0, -1)
		setup_github_refs(buf, get_repo_base_url())
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

	-- The comment on the cursor line, or nil on a separator / blank line
	local function comment_on_cursor_line()
		local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1 -- 0-indexed
		local index = format.find_comment_index_at_line(result.comment_ranges, cursor_line)
		return index and comments[index] or nil
	end

	-- e/d/R fall back to the last comment off any comment's lines
	local function find_comment_at_cursor()
		return comment_on_cursor_line() or comments[#comments]
	end

	vim.keymap.set("n", "e", function()
		local target = find_comment_at_cursor()
		if target then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").edit_comment(target.id)
		end
	end, { buffer = buf, desc = "Edit comment" })

	vim.keymap.set("n", "d", function()
		local target = find_comment_at_cursor()
		if target then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").delete_comment(target.id)
		end
	end, { buffer = buf, desc = "Delete comment" })

	vim.keymap.set("n", "R", function()
		local target = find_comment_at_cursor()
		-- A nil id would make toggle_resolve fall back to the source line,
		-- which may hold another thread.
		if target and target.id ~= nil then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").toggle_resolve(target.id)
		end
	end, { buffer = buf, desc = "Toggle thread resolved" })

	-- The float stays open: the browser takes focus, and the comment is still
	-- here to act on when the user comes back. Unlike e/d/R there is no
	-- fallback to the last comment, so a separator line opens nothing rather
	-- than another comment's page (same as the comment browser and overview).
	local open_ctx = M.capture_open_context()
	vim.keymap.set("n", "o", function()
		M.open_comment_in_browser(comment_on_cursor_line(), open_ctx)
	end, { buffer = buf, desc = "Open comment on GitHub" })

	-- Like o, only the comment under the cursor: the float stays open and
	-- shows the new reactions. :FudeReviewReact runs the same here.
	local reactions = require("fude.reactions")
	local function react()
		reactions.pick(comment_on_cursor_line(), open_ctx, rerender)
	end
	vim.keymap.set("n", "+", react, { buffer = buf, desc = "Add/remove a reaction" })
	reactions.set_buffer_handler(buf, react)

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

--- The overview's split-pane layout for the current screen and
--- `config.opts.overview`, shared by the overview and its loading placeholder
--- so the two are placed alike.
--- @return table from format.calculate_overview_layout
local function overview_layout()
	local ov = config.opts.overview or {}
	return format.calculate_overview_layout(
		vim.o.columns,
		vim.o.lines,
		ov.width or 80,
		ov.height or 80,
		ov.right_width or 30
	)
end

--- Text of the overview's loading placeholder, left pane.
M.OVERVIEW_LOADING_TEXT = "Loading PR overview…"
--- Text of the overview's loading placeholder, right pane.
M.OVERVIEW_LOADING_RIGHT_TEXT = "Loading…"

--- Start a spinner: `on_frame(frame)` runs on every tick of the toggle
--- picker's spinner interval, the frame index advancing through its frames.
--- @param on_frame fun(frame: number)
--- @return fun() stop stops the timer (idempotent)
local function start_spinner(on_frame)
	local toggle_picker = require("fude.ui.toggle_picker")
	local timer = vim.uv.new_timer()
	if not timer then
		return function() end
	end
	local frame = 1
	timer:start(
		toggle_picker.LOADING_INTERVAL_MS,
		toggle_picker.LOADING_INTERVAL_MS,
		vim.schedule_wrap(function()
			if not timer then
				return
			end
			frame = frame % #toggle_picker.LOADING_FRAMES + 1
			on_frame(frame)
		end)
	)
	return function()
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
	end
end

--- Namespace of the spinner frames drawn over loading rows.
local spinner_ns = vim.api.nvim_create_namespace("fude_spinner")

--- Draw spinner frames over loading rows: `rows` is a list of
--- `{ buf, row (0-indexed), col (byte) }` whose text already holds a mark of
--- the same width at `col`. The frame is an overlay extmark, so the buffer
--- text never changes: rewriting it every frame would fire buffer change
--- events (`on_lines`) that other plugins react to, e.g. by scheduling a
--- treesitter parse of a buffer that `q` wipes before it runs. The previous
--- frames of `bufs` are dropped first.
--- @param bufs number[]
--- @param rows table[]
--- @param mark string
local function draw_spinner_frames(bufs, rows, mark)
	local toggle_picker = require("fude.ui.toggle_picker")
	for _, buf in ipairs(bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, spinner_ns, 0, -1)
		end
	end
	for _, row in ipairs(rows) do
		if vim.api.nvim_buf_is_valid(row[1]) then
			pcall(vim.api.nvim_buf_set_extmark, row[1], spinner_ns, row[2], row[3], {
				virt_text = { { mark, toggle_picker.LOADING_HL } },
				virt_text_pos = "overlay",
				invalidate = true,
			})
		end
	end
end

--- Open the placeholder shown while the overview's PR data is being fetched
--- (two gh calls, which can take a while): the overview's two panes at the
--- same position and size as the overview itself, the left one titled like
--- it, each holding a loading text in its middle after the toggle picker's
--- spinner, which a timer advances until the placeholder closes. `q` /
--- `<Esc>` close both, which overview.show reads as "do not show the overview
--- after all"; closing either pane by other means closes the other too.
--- @return table handle { close: fun(), is_open: fun(): boolean, is_spinning: fun(): boolean }
function M.open_overview_loading()
	local toggle_picker = require("fude.ui.toggle_picker")
	local layout = overview_layout()
	local border = config.opts.float.border

	local function scratch_buf(lines)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		return buf
	end
	-- One centred spinner line per pane
	local panes = {
		{ text = M.OVERVIEW_LOADING_TEXT, size = layout.left },
		{ text = M.OVERVIEW_LOADING_RIGHT_TEXT, size = layout.right },
	}
	for _, pane in ipairs(panes) do
		local line = toggle_picker.format_loading_mark(1) .. " " .. pane.text
		local lines, row, col =
			format.build_centered_lines(line, vim.fn.strdisplaywidth(line), pane.size.width, pane.size.height)
		pane.buf = scratch_buf(lines)
		pane.row = row
		pane.prefix = string.rep(" ", col)
	end
	local left_buf, right_buf = panes[1].buf, panes[2].buf

	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		row = layout.left.row,
		col = layout.left.col,
		width = layout.left.width,
		height = layout.left.height,
		style = "minimal",
		border = border,
		title = " PR Overview ",
		title_pos = "center",
	})
	local right_win = vim.api.nvim_open_win(right_buf, false, {
		relative = "editor",
		row = layout.right.row,
		col = layout.right.col,
		width = layout.right.width,
		height = layout.right.height,
		style = "minimal",
		border = border,
	})
	-- The text is written once: the mark coloured like the toggle picker's
	-- spinner and the text grey; the frames are drawn over the mark.
	local ns = config.state.ns_id or vim.api.nvim_create_namespace("fude")
	local first_mark = toggle_picker.format_loading_mark(1)
	local spinner_rows = {}
	for _, pane in ipairs(panes) do
		local mark_end = #pane.prefix + #first_mark
		pcall(vim.api.nvim_buf_add_highlight, pane.buf, ns, toggle_picker.LOADING_HL, pane.row, #pane.prefix, mark_end)
		pcall(vim.api.nvim_buf_add_highlight, pane.buf, ns, "Comment", pane.row, mark_end, -1)
		table.insert(spinner_rows, { pane.buf, pane.row, #pane.prefix })
	end
	local function render(frame)
		draw_spinner_frames({ left_buf, right_buf }, spinner_rows, toggle_picker.format_loading_mark(frame))
	end
	render(1)
	local stop_spinner = start_spinner(render)
	local spinning = true

	local handle = {}
	function handle.is_open()
		return vim.api.nvim_win_is_valid(left_win)
	end
	--- Whether the spinner timer is still running (false once closed).
	function handle.is_spinning()
		return spinning
	end
	local closing = false
	function handle.close()
		if closing then
			return
		end
		closing = true
		stop_spinner()
		spinning = false
		pcall(vim.api.nvim_win_close, left_win, true)
		pcall(vim.api.nvim_win_close, right_win, true)
	end
	-- Closing one pane (q, :q, :only) closes the other
	local augroup = vim.api.nvim_create_augroup("fude_overview_loading_" .. left_win, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		pattern = { tostring(left_win), tostring(right_win) },
		callback = function()
			handle.close()
			vim.api.nvim_del_augroup_by_id(augroup)
		end,
	})
	for _, buf in ipairs({ left_buf, right_buf }) do
		vim.keymap.set("n", "q", handle.close, { buffer = buf, desc = "Cancel the PR overview" })
		vim.keymap.set("n", "<Esc>", handle.close, { buffer = buf, desc = "Cancel the PR overview" })
	end
	return handle
end

--- Background colour the overview floats are drawn on: NormalFloat, else
--- Normal, else black / white by 'background' (a transparent colour scheme).
--- @return string hex colour
local function overview_base_bg()
	for _, name in ipairs({ "NormalFloat", "Normal" }) do
		local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
		if hl.bg then
			return string.format("#%06x", hl.bg)
		end
	end
	return vim.o.background == "light" and "#ffffff" or "#000000"
end

--- Define the highlight groups of the overview's label pills (see
--- format.calculate_label_colors). Redefined on every render, since a
--- colour scheme change clears them.
--- @param label_colors string[] normalized `rrggbb` label colours
local function define_label_hls(label_colors)
	if not label_colors or #label_colors == 0 then
		return
	end
	local base_bg = overview_base_bg()
	for _, hex in ipairs(label_colors) do
		local colors = format.calculate_label_colors(hex, base_bg, vim.o.background)
		local name_hl, cap_hl = format.build_label_hl_names(hex)
		if colors and name_hl then
			vim.api.nvim_set_hl(0, name_hl, { fg = colors.fg, bg = colors.bg, bold = true })
			vim.api.nvim_set_hl(0, cap_hl, { fg = colors.bg })
		end
	end
end
M._define_label_hls = define_label_hls

--- Show PR overview in a split-pane floating window.
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- @param opts table { on_menu: fun()|nil, on_refresh: fun()|nil, on_re_request: fun()|nil }
---   (on_menu runs on `C`: the Comment / Reviewer / Label menu)
--- @return table handle { is_open: fun(): boolean, set_checks: fun(checks: table[]|nil, failed: boolean|nil) }
---   `pr_info.statusCheckRollup` nil means the checks are still being fetched: CI STATUS then shows a
---   spinner until `set_checks` rewrites the section in place (`failed` for a fetch that failed), or
---   the failure row when `pr_info.checks_failed` is already set.
function M.show_overview_float(pr_info, issue_comments, opts)
	local toggle_picker = require("fude.ui.toggle_picker")
	local ov = config.opts.overview or {}
	local toggle_key = type(ov.keymaps) == "table" and ov.keymaps.toggle_right_pane or nil
	local loading_opts = {
		loading_mark = toggle_picker.format_loading_mark(1),
		loading_hl = toggle_picker.LOADING_HL,
		toggle_right_pane_key = toggle_key,
	}
	local function build_left()
		return format.build_overview_left_lines(pr_info, issue_comments, config.format_date, loading_opts)
	end
	local function build_right()
		return format.build_overview_right_lines(pr_info, {
			loading_mark = loading_opts.loading_mark,
			loading_hl = loading_opts.loading_hl,
			checks_failed = pr_info.checks_failed == true,
			labels_width = overview_layout().right.width,
			display_width = vim.fn.strdisplaywidth,
		})
	end
	-- Rebuilt by set_comments / set_reviewers / set_checks as the parts that
	-- load after the body arrive; the mappings below read the current ones.
	local left_result = build_left()
	local right_result = build_right()
	-- Kept as one table: the gx mapping reads it, and set_checks refills it
	local check_urls = right_result.check_urls

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

	-- Author, reviewer, assignee and comment author avatars, drawn as their
	-- downloads finish (each kind a no-op unless images.overview turns it
	-- on, and all without snacks.nvim image support)
	local avatars = require("fude.ui.avatars")
	avatars.place(left_buf, left_result.avatar_positions)
	avatars.place(right_buf, right_result.avatar_positions)

	-- Calculate split-pane layout. The panes always take the layout's full
	-- height, not the content's: a short PR must not shrink the window that
	-- replaces the loading placeholder of the same size.
	local layout = overview_layout()
	local row = layout.left.row

	-- Open left window (focused)
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		row = row,
		col = layout.left.col,
		width = layout.left.width,
		height = layout.left.height,
		style = "minimal",
		border = config.opts.float.border,
		title = " PR Overview ",
		title_pos = "center",
	})
	vim.wo[left_win].wrap = true
	vim.wo[left_win].foldenable = true
	vim.wo[left_win].foldmethod = "expr"
	vim.wo[left_win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
	vim.wo[left_win].foldlevel = 99

	-- Open right window (not focused)
	local right_win = vim.api.nvim_open_win(right_buf, false, {
		relative = "editor",
		row = row,
		col = layout.right.col,
		width = layout.right.width,
		height = layout.right.height,
		style = "minimal",
		border = config.opts.float.border,
	})
	vim.wo[right_win].wrap = true
	vim.wo[right_win].foldenable = true
	vim.wo[right_win].foldmethod = "expr"
	vim.wo[right_win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
	vim.wo[right_win].foldlevel = 99

	-- Apply highlights
	local ns = config.state.ns_id or vim.api.nvim_create_namespace("fude")
	local url_hl = vim.api.nvim_get_hl(0, { name = "Underlined", link = false })
	vim.api.nvim_set_hl(0, "ReviewFileCount", { fg = url_hl.fg })
	vim.api.nvim_set_hl(0, "ReviewCommitCount", { fg = url_hl.fg })
	define_label_hls(right_result.label_colors)
	for _, hl in ipairs(left_result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, hl.col_start or 0, hl.col_end or -1)
	end
	local function highlight_right(hl_ranges)
		for _, hl in ipairs(hl_ranges) do
			pcall(vim.api.nvim_buf_add_highlight, right_buf, ns, hl.hl, hl.line, hl.col_start or 0, hl.col_end or -1)
		end
	end
	highlight_right(right_result.hl_ranges)

	-- One spinner for every section still loading (COMMENTS on the left,
	-- REVIEWERS and CI STATUS on the right); it stops once none is left. The
	-- rows hold the first frame as text; later frames are drawn over it.
	local function loading_rows()
		local rows = {}
		if left_result.loading_row then
			table.insert(rows, { left_buf, left_result.loading_row, 0 })
		end
		if right_result.reviewers_loading_row then
			table.insert(rows, { right_buf, right_result.reviewers_loading_row, 0 })
		end
		if right_result.loading_row then
			table.insert(rows, { right_buf, right_result.loading_row, 0 })
		end
		return rows
	end
	local current_frame = 1
	local function draw_frame(frame)
		current_frame = frame
		draw_spinner_frames({ left_buf, right_buf }, loading_rows(), toggle_picker.format_loading_mark(frame))
	end
	local stop_spinner = function() end
	--- After a section was filled in: redraw the remaining frames where the
	--- loading rows now are, or stop when none is left.
	local function update_spinner()
		draw_frame(current_frame)
		if #loading_rows() == 0 then
			stop_spinner()
			stop_spinner = function() end
		end
	end
	if #loading_rows() > 0 then
		stop_spinner = start_spinner(draw_frame)
	end

	-- Set section marks (left pane only)
	local marks = ov.marks or { description = "d", comments = "c" }
	local function set_marks()
		for section, mark in pairs(marks) do
			local line = left_result.sections[section]
			if line and mark then
				vim.api.nvim_buf_set_mark(left_buf, mark, line, 0, {})
			end
		end
	end
	set_marks()

	-- Close both windows helper
	local closing = false
	local function close_both()
		if closing then
			return
		end
		closing = true
		stop_spinner()
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
		if opts.on_menu then
			opts.on_menu()
		end
	end, { buffer = left_buf, desc = "Write a PR comment or edit reviewers / labels" })

	vim.keymap.set("n", "R", function()
		close_both()
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = left_buf, desc = "Refresh PR overview" })

	vim.keymap.set("n", "r", function()
		close_both()
		if opts.on_re_request then
			opts.on_re_request()
		end
	end, { buffer = left_buf, desc = "Re-request review" })

	-- `o` opens the comment under the cursor, or the PR anywhere else (body,
	-- frontmatter, headings). The overview stays open.
	-- PR-level comments are never pending; the snapshot only keeps the review
	-- mode the overview was opened in
	local open_ctx = M.capture_open_context()
	local function open_pr()
		util.open_url(pr_info.url, "No PR URL to open")
	end
	vim.keymap.set("n", "o", function()
		local line = vim.api.nvim_win_get_cursor(left_win)[1] - 1
		local index = format.find_comment_index_at_line(left_result.comment_ranges, line)
		if index and issue_comments then
			M.open_comment_in_browser(issue_comments[index], open_ctx)
		else
			open_pr()
		end
	end, { buffer = left_buf, desc = "Open comment or PR on GitHub" })
	vim.keymap.set("n", "o", open_pr, { buffer = right_buf, desc = "Open PR on GitHub" })

	-- Hide the right pane so the left one (the PR body) takes the whole
	-- width, and show it again. The window is hidden rather than closed:
	-- closing either pane closes the overview (WinClosed below).
	local right_hidden = false
	local function toggle_right_pane()
		right_hidden = not right_hidden
		if right_hidden and vim.api.nvim_get_current_win() == right_win then
			vim.api.nvim_set_current_win(left_win)
		end
		pcall(vim.api.nvim_win_set_config, right_win, { hide = right_hidden })
		pcall(vim.api.nvim_win_set_config, left_win, {
			relative = "editor",
			row = row,
			col = layout.left.col,
			width = right_hidden and format.calculate_overview_full_width(layout) or layout.left.width,
			height = layout.left.height,
		})
	end
	if toggle_key then
		for _, buf in ipairs({ left_buf, right_buf }) do
			vim.keymap.set("n", toggle_key, toggle_right_pane, { buffer = buf, desc = "Hide/show the right pane" })
		end
	end

	-- Tab to switch between panes (nothing to switch to while the right one is hidden)
	vim.keymap.set("n", "<Tab>", function()
		if not right_hidden then
			vim.api.nvim_set_current_win(right_win)
		end
	end, { buffer = left_buf, desc = "Switch to right pane" })

	vim.keymap.set("n", "<Tab>", function()
		vim.api.nvim_set_current_win(left_win)
	end, { buffer = right_buf, desc = "Switch to left pane" })

	-- Section jump keymaps (left pane)
	local section_lines = {}
	local function collect_sections()
		section_lines = {}
		for _, line in pairs(left_result.sections) do
			table.insert(section_lines, line)
		end
		table.sort(section_lines)
	end
	collect_sections()

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

	-- Comment navigation keymaps (left pane only — navigate between issue
	-- comments, which may still be loading when the overview opens)
	local km = config.opts.keymaps
	if km.next_comment then
		vim.keymap.set("n", km.next_comment, function()
			local comment_lines = left_result.comment_positions
			if #comment_lines == 0 then
				return
			end
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
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			local comment_lines = left_result.comment_positions
			if #comment_lines == 0 then
				return
			end
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

	vim.keymap.set("n", "r", function()
		close_both()
		if opts.on_re_request then
			opts.on_re_request()
		end
	end, { buffer = right_buf, desc = "Re-request review" })

	-- GitHub refs for both panes
	setup_github_refs(left_buf, get_repo_base_url(pr_info.url))
	setup_github_refs(right_buf, get_repo_base_url(pr_info.url), check_urls)

	local handle = {}
	function handle.is_open()
		return vim.api.nvim_win_is_valid(left_win) and vim.api.nvim_buf_is_valid(right_buf)
	end
	local function set_lines(buf, start, lines)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(buf, ns, start, -1)
	end
	local function refill_check_urls(urls)
		for line in pairs(check_urls) do
			check_urls[line] = nil
		end
		for line, url in pairs(urls) do
			check_urls[line] = url
		end
		vim.api.nvim_buf_clear_namespace(right_buf, ref_ns, 0, -1)
		setup_github_refs(right_buf, get_repo_base_url(pr_info.url), check_urls)
	end

	--- Fill in the PR-level comments. COMMENTS is the end of the left pane
	--- (with the footer), so the frontmatter and the body above it stay as
	--- they are; the avatars are drawn again with the comment authors'.
	--- @param comments table[]
	--- Rebuild the left pane from line `start` (0-indexed) on.
	--- @param start number
	local function rewrite_left(start)
		left_result = build_left()
		set_lines(left_buf, start, vim.list_slice(left_result.lines, start + 1))
		for _, hl in ipairs(left_result.hl_ranges) do
			if hl.line >= start then
				pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, hl.col_start or 0, hl.col_end or -1)
			end
		end
		set_marks()
		collect_sections()
		vim.api.nvim_buf_clear_namespace(left_buf, ref_ns, 0, -1)
		setup_github_refs(left_buf, get_repo_base_url(pr_info.url))
		avatars.clear(left_buf)
		avatars.place(left_buf, left_result.avatar_positions)
	end

	function handle.set_comments(comments)
		issue_comments = comments
		if handle.is_open() then
			rewrite_left(left_result.comments_start)
		end
		update_spinner()
	end

	--- Redraw the whole left pane (the PR's own reactions, under its body,
	--- move everything below them).
	function handle.refresh_left()
		if handle.is_open() then
			rewrite_left(0)
		end
		update_spinner()
	end

	--- Rebuild the right pane once the reviewers (already on `pr_info`)
	--- arrived: REVIEWERS is its first section, so everything below moves.
	function handle.set_reviewers()
		if handle.is_open() then
			right_result = build_right()
			set_lines(right_buf, 0, right_result.lines)
			define_label_hls(right_result.label_colors)
			highlight_right(right_result.hl_ranges)
			avatars.clear(right_buf)
			avatars.place(right_buf, right_result.avatar_positions)
			refill_check_urls(right_result.check_urls)
		end
		update_spinner()
	end

	--- Rewrite the CI STATUS section with the fetched checks (or the failure
	--- row). The section is the end of the right pane, so nothing above it
	--- moves (avatars, folds of the other sections).
	--- @param checks table[]|nil
	--- @param failed boolean|nil
	function handle.set_checks(checks, failed)
		if handle.is_open() then
			local ci = format.build_overview_ci_lines(checks, right_result.ci_start, { checks_failed = failed })
			set_lines(right_buf, right_result.ci_start, ci.lines)
			highlight_right(ci.hl_ranges)
			right_result.loading_row = nil
			refill_check_urls(ci.check_urls)
		end
		update_spinner()
	end

	-- `+` reacts to the PR-level comment under the cursor, and to the PR
	-- itself (its body) anywhere else, like `o`; the right pane always means
	-- the PR. The left pane is redrawn with the new reactions.
	local reactions = require("fude.reactions")
	local function react_to_pr()
		reactions.pick_pr(pr_info, open_ctx, function()
			handle.refresh_left()
		end)
	end
	local function react_in_left()
		local line = vim.api.nvim_win_get_cursor(left_win)[1] - 1
		local index = format.find_comment_index_at_line(left_result.comment_ranges, line)
		local comment = index and issue_comments and issue_comments[index] or nil
		if not comment then
			react_to_pr()
			return
		end
		reactions.pick(comment, open_ctx, function()
			handle.set_comments(issue_comments)
		end)
	end
	vim.keymap.set(
		"n",
		"+",
		react_in_left,
		{ buffer = left_buf, desc = "Add/remove a reaction on the comment or the PR" }
	)
	vim.keymap.set("n", "+", react_to_pr, { buffer = right_buf, desc = "Add/remove a reaction on the PR" })
	-- :FudeReviewReact in either pane does what `+` does there
	reactions.set_buffer_handler(left_buf, react_in_left)
	reactions.set_buffer_handler(right_buf, react_to_pr)

	return handle
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

--- Whether a buffer holds text (any non-blank line).
--- @param buf number|nil
--- @return boolean
local function buf_has_text(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:match("%S") then
			return true
		end
	end
	return false
end

--- Whether a comment input somewhere holds unsent text: a single-pane input
--- float (`open_comment_input`, marked `b:fude_comment`) shown in a window,
--- the reply/edit window's lower pane, or the comment browser's lower pane.
--- The local commit scope refuses to switch while this is true, because its
--- teardown (`close_comment_ui`) wipes those buffers and the backend would
--- refuse the submit anyway — either way the text would be lost.
--- @return boolean
function M.has_unsent_comment_input()
	local state = config.state
	if state.reply_window and state.reply_window.upper_win and buf_has_text(state.reply_window.lower_buf) then
		return true
	end
	if state.comment_browser and buf_has_text(state.comment_browser.lower_buf) then
		return true
	end
	for _, buf in ipairs(M.comment_input_buffers()) do
		if buf_has_text(buf) then
			return true
		end
	end
	return false
end

--- Loaded buffers carrying the buffer variable `flag` that are shown in some
--- window of *any* tabpage — `bufwinid` only searches the current tab,
--- `win_findbuf` searches them all.
--- @param flag string buffer variable name
--- @return integer[] bufs
local function visible_buffers_with(flag)
	local bufs = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf][flag] and #vim.fn.win_findbuf(buf) > 0 then
			table.insert(bufs, buf)
		end
	end
	return bufs
end

--- Single-pane comment input buffers (`open_comment_input`, marked
--- `b:fude_comment`) shown in any tabpage.
--- @return integer[] bufs
function M.comment_input_buffers()
	return visible_buffers_with("fude_comment")
end

--- Comment viewer floats (`show_comments_float`, marked `b:fude_comment_view`)
--- shown in any tabpage.
--- @return integer[] bufs
function M.comment_view_buffers()
	return visible_buffers_with("fude_comment_view")
end

--- Close every open comment UI that shows or takes comments: the reply/edit
--- window, the comment browser, the viewer floats and the single-pane input
--- floats, in any tab. The local commit scope calls this on entry, since the
--- comments they show anchor to a working tree that is no longer checked out
--- and a submit from them would be refused by the backend after the float has
--- already closed. Inputs holding text never get here
--- (`has_unsent_comment_input` blocks first).
function M.close_comment_ui()
	local state = config.state
	if state.reply_window and state.reply_window.upper_win then
		close_reply_window(state.reply_window)
	end
	require("fude.ui.comment_browser").close()
	for _, list in ipairs({ M.comment_view_buffers(), M.comment_input_buffers() }) do
		for _, buf in ipairs(list) do
			for _, win in ipairs(vim.fn.win_findbuf(buf)) do
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
	end
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

	-- Calculate dimensions
	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)
	-- Format thread for upper pane (separator spans the window width)
	local result = format.format_reply_comments_for_display(thread, config.format_date, dim.width)

	-- Split height: lower prefers 12 lines, but clamp to dim.height while keeping upper >= 3 lines
	local min_upper_height = 3
	local desired_lower_height = 12
	local max_lower_height = math.max(1, dim.height - min_upper_height)
	local lower_height = math.min(desired_lower_height, max_lower_height)
	local upper_height = dim.height - lower_height

	-- Create upper buffer (readonly thread)
	local upper_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(upper_buf, 0, -1, false, result.lines)
	vim.bo[upper_buf].modifiable = false
	vim.bo[upper_buf].buftype = "nofile"
	vim.bo[upper_buf].bufhidden = "wipe"
	vim.bo[upper_buf].filetype = "markdown"
	require("fude.ui.avatars").place(upper_buf, result.avatar_positions)

	-- Create lower buffer (editable, pre-filled with comment body)
	local lower_buf = vim.api.nvim_create_buf(false, true)
	local original_lines = opts.initial_lines or vim.split(format.normalize_newlines(comment.body), "\n")
	vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, original_lines)
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
		M.confirm_close_with_draft(lower_buf, original_lines, {
			allow_draft = opts.allow_draft,
			on_save_draft = opts.on_save_draft,
			on_discard = opts.on_discard_draft,
			on_close = close_all,
		})
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

	-- Calculate dimensions
	local dim = format.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)
	-- Format comments (separator spans the window width)
	local result = format.format_reply_comments_for_display(comments, config.format_date, dim.width)

	-- Split height: lower prefers 12 lines, but clamp to dim.height while keeping upper >= 3 lines
	local min_upper_height = 3
	local desired_lower_height = 12
	local max_lower_height = math.max(1, dim.height - min_upper_height)
	local lower_height = math.min(desired_lower_height, max_lower_height)
	local upper_height = dim.height - lower_height

	-- Create upper buffer (readonly comments)
	local upper_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(upper_buf, 0, -1, false, result.lines)
	vim.bo[upper_buf].modifiable = false
	vim.bo[upper_buf].buftype = "nofile"
	vim.bo[upper_buf].bufhidden = "wipe"
	vim.bo[upper_buf].filetype = opts.filetype or "markdown"
	require("fude.ui.avatars").place(upper_buf, result.avatar_positions)

	-- Create lower buffer (editable input)
	local lower_buf = vim.api.nvim_create_buf(false, true)
	local original_lines = opts.initial_lines or { "" }
	vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, original_lines)
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
		M.confirm_close_with_draft(lower_buf, original_lines, {
			allow_draft = opts.allow_draft,
			on_save_draft = opts.on_save_draft,
			on_discard = opts.on_discard_draft,
			on_close = close_all,
		})
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
