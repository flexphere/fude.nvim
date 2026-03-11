local M = {}
local config = require("fude.config")

--- Get the namespace ID for flash/highlight extmarks.
--- Uses config.state.ns_id so existing cleanup paths (clear_extmarks, clear_all_extmarks) cover these.
--- @return number
local function get_flash_ns()
	return config.state.ns_id or vim.api.nvim_create_namespace("fude")
end

--- Flash highlight a line temporarily.
--- @param line number 1-indexed line number
function M.flash_line(line)
	local buf = vim.api.nvim_get_current_buf()
	local ns = get_flash_ns()
	local flash_opts = config.opts.flash or {}
	local duration = flash_opts.duration or 200
	local hl_group = flash_opts.hl_group or "Visual"

	local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
		line_hl_group = hl_group,
		priority = 100,
	})

	vim.defer_fn(function()
		pcall(vim.api.nvim_buf_del_extmark, buf, ns, extmark_id)
	end, duration)
end

-- Store current comment line highlight info
local comment_line_highlight = {
	buf = nil,
	extmark_ids = {},
}

--- Highlight lines persistently (for comment viewing).
--- @param buf number buffer handle
--- @param start_line number 1-indexed start line number
--- @param end_line number 1-indexed end line number
function M.highlight_comment_lines(buf, start_line, end_line)
	M.clear_comment_line_highlight()

	-- Ensure line numbers are valid
	start_line = tonumber(start_line)
	end_line = tonumber(end_line)
	if not start_line or not end_line then
		return
	end

	local ns = get_flash_ns()
	local flash_opts = config.opts.flash or {}
	local hl_group = flash_opts.hl_group or "Visual"

	comment_line_highlight.buf = buf
	comment_line_highlight.extmark_ids = {}

	for line_num = start_line, end_line do
		local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line_num - 1, 0, {
			line_hl_group = hl_group,
			priority = 100,
		})
		table.insert(comment_line_highlight.extmark_ids, extmark_id)
	end
end

--- Clear the persistent comment line highlight.
function M.clear_comment_line_highlight()
	if comment_line_highlight.buf then
		local ns = get_flash_ns()
		for _, extmark_id in ipairs(comment_line_highlight.extmark_ids) do
			pcall(vim.api.nvim_buf_del_extmark, comment_line_highlight.buf, ns, extmark_id)
		end
	end
	comment_line_highlight.buf = nil
	comment_line_highlight.extmark_ids = {}
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

	local style = config.get_comment_style()

	for _, line in ipairs(comment_lines) do
		local comments = comments_mod.get_comments_at(rel_path, line)

		if style == "inline" then
			-- Inline mode: display full comment content below the line
			-- Build arrays only when needed for inline display
			local all_comments_for_display = {}
			for _, c in ipairs(comments) do
				if state.pending_review_id and c.pull_request_review_id == state.pending_review_id then
					local pc = vim.tbl_extend("force", {}, c)
					pc.is_pending = true
					table.insert(all_comments_for_display, pc)
				else
					table.insert(all_comments_for_display, c)
				end
			end

			if #all_comments_for_display > 0 then
				local format = require("fude.ui.format")
				local inline_opts = config.opts.inline or {}
				local result = format.format_comments_for_inline(all_comments_for_display, config.format_date, inline_opts)
				pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, line - 1, 0, {
					virt_lines = result.virt_lines,
					virt_lines_above = false,
					priority = 50,
				})
			end
		else
			-- virtualText mode: display indicators at end of line (original behavior)
			-- Only compute counts, avoid building arrays
			local submitted_count = 0
			local has_pending = false
			for _, c in ipairs(comments) do
				if state.pending_review_id and c.pull_request_review_id == state.pending_review_id then
					has_pending = true
				else
					submitted_count = submitted_count + 1
				end
			end

			if submitted_count > 0 then
				pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, line - 1, 0, {
					virt_text = {
						{ string.format(" %s%d", config.opts.signs.comment, submitted_count), config.opts.signs.comment_hl },
					},
					virt_text_pos = "eol",
					priority = 50,
				})
			end
			if has_pending then
				pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, line - 1, 0, {
					virt_text = {
						{ " " .. config.opts.signs.pending, config.opts.signs.pending_hl },
					},
					virt_text_pos = "eol",
					priority = 45,
				})
			end
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

-- Namespace for inline hint extmarks (separate from main extmarks)
local hint_ns = nil
local function get_hint_ns()
	if not hint_ns then
		hint_ns = vim.api.nvim_create_namespace("fude_inline_hint")
	end
	return hint_ns
end

-- Track current hint state
local current_hint = {
	buf = nil,
	line = nil,
	extmark_id = nil,
}

-- Cache for keymaps (avoid repeated keymap lookups on CursorMoved)
local cached_view_comment_keymap = nil
local cached_toggle_style_keymap = nil
local keymap_cache_initialized = false

-- Cache for repo root (avoid repeated git command on CursorMoved)
local cached_repo_root = nil

--- Clear the inline hint extmark.
function M.clear_inline_hint()
	if current_hint.buf and current_hint.extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, current_hint.buf, get_hint_ns(), current_hint.extmark_id)
	end
	current_hint.buf = nil
	current_hint.line = nil
	current_hint.extmark_id = nil
end

--- Convert internal keymap lhs to human-readable format.
--- Replaces the resolved leader key with <leader> for display.
--- @param lhs string raw lhs from nvim_get_keymap
--- @return string human-readable keymap
local function format_keymap_for_display(lhs)
	local leader = vim.g.mapleader or "\\"
	-- If starts with the leader character, replace with <leader>
	if lhs:sub(1, #leader) == leader then
		return "<leader>" .. lhs:sub(#leader + 1)
	end
	-- Use keytrans for other special keys
	return vim.fn.keytrans(lhs)
end

--- Search keymaps for a command pattern.
--- @param pattern string pattern to search for in rhs
--- @param desc_pattern string|nil pattern to search for in desc (optional)
--- @return string|nil keymap string if found, nil otherwise
local function search_keymap_for_command(pattern, desc_pattern)
	local keymaps = vim.api.nvim_get_keymap("n")
	for _, km in ipairs(keymaps) do
		local rhs = km.rhs or ""
		-- Check if rhs contains the pattern
		if rhs:find(pattern) then
			return format_keymap_for_display(km.lhs)
		end
		-- Check callback-based keymaps by checking desc
		if desc_pattern and km.callback and km.desc and km.desc:find(desc_pattern) then
			return format_keymap_for_display(km.lhs)
		end
	end
	-- Also check buffer-local keymaps
	local buf_keymaps = vim.api.nvim_buf_get_keymap(0, "n")
	for _, km in ipairs(buf_keymaps) do
		local rhs = km.rhs or ""
		if rhs:find(pattern) then
			return format_keymap_for_display(km.lhs)
		end
		if desc_pattern and km.callback and km.desc and km.desc:find(desc_pattern) then
			return format_keymap_for_display(km.lhs)
		end
	end
	return nil
end

--- Initialize keymap caches.
local function init_keymap_cache()
	if not keymap_cache_initialized then
		cached_view_comment_keymap = search_keymap_for_command("FudeReviewViewComment", "View.*comment")
		cached_toggle_style_keymap = search_keymap_for_command("FudeReviewToggleCommentStyle", "Toggle.*style")
		keymap_cache_initialized = true
	end
end

--- Find keybinding for FudeReviewViewComment command (cached).
--- @return string|nil keymap string if found, nil otherwise
local function find_view_comment_keymap()
	init_keymap_cache()
	return cached_view_comment_keymap
end

--- Find keybinding for FudeReviewToggleCommentStyle command (cached).
--- @return string|nil keymap string if found, nil otherwise
local function find_toggle_style_keymap()
	init_keymap_cache()
	return cached_toggle_style_keymap
end

--- Update inline hint based on cursor position.
--- Shows a tip when cursor is on a comment line (in both virtualText and inline modes).
function M.update_inline_hint()
	local state = config.state
	if not state.active then
		M.clear_inline_hint()
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)

	-- Use cached repo root to avoid git command on every CursorMoved
	if not cached_repo_root then
		local diff = require("fude.diff")
		cached_repo_root = diff.get_repo_root()
	end
	if not cached_repo_root then
		M.clear_inline_hint()
		return
	end

	local diff = require("fude.diff")
	local rel_path = diff.make_relative(vim.fn.fnamemodify(filepath, ":p"), cached_repo_root)
	if not rel_path then
		M.clear_inline_hint()
		return
	end

	local cursor_line = vim.fn.line(".")
	local comments_mod = require("fude.comments")
	local comments = comments_mod.get_comments_at(rel_path, cursor_line)

	-- If no comments on this line, clear hint
	if #comments == 0 then
		M.clear_inline_hint()
		return
	end

	-- If hint already shown for this line, do nothing
	if current_hint.buf == buf and current_hint.line == cursor_line then
		return
	end

	-- Clear previous hint
	M.clear_inline_hint()

	-- Build hint text with available keymaps
	local ns = get_hint_ns()
	local view_keymap = find_view_comment_keymap()
	local toggle_keymap = find_toggle_style_keymap()

	local hints = {}
	-- View comment hint
	if view_keymap then
		table.insert(hints, view_keymap .. ": view/reply/edit/delete")
	else
		table.insert(hints, ":FudeReviewViewComment")
	end
	-- Toggle style hint
	if toggle_keymap then
		table.insert(hints, toggle_keymap .. ": toggle comment style")
	else
		table.insert(hints, ":FudeReviewToggleCommentStyle")
	end

	local hint_text = "💡 " .. table.concat(hints, " | ")
	local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, cursor_line - 1, 0, {
		virt_text = { { hint_text, "DiagnosticHint" } },
		virt_text_pos = "eol",
		priority = 200,
	})

	current_hint.buf = buf
	current_hint.line = cursor_line
	current_hint.extmark_id = extmark_id
end

-- Autocmd group for inline hint
local hint_augroup = nil

--- Setup autocmd for inline hint updates.
function M.setup_inline_hint_autocmd()
	if hint_augroup then
		return
	end
	hint_augroup = vim.api.nvim_create_augroup("fude_inline_hint", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = hint_augroup,
		callback = function()
			M.update_inline_hint()
		end,
	})
end

--- Teardown autocmd for inline hint.
function M.teardown_inline_hint_autocmd()
	if hint_augroup then
		pcall(vim.api.nvim_del_augroup_by_id, hint_augroup)
		hint_augroup = nil
	end
	M.clear_inline_hint()
	-- Clear caches for next session
	cached_view_comment_keymap = nil
	cached_toggle_style_keymap = nil
	keymap_cache_initialized = false
	cached_repo_root = nil
end

return M
