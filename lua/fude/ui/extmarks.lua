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
		local submitted_count = 0
		local has_pending = false
		local submitted_comments = {}
		local pending_comments = {}

		for _, c in ipairs(comments) do
			if state.pending_review_id and c.pull_request_review_id == state.pending_review_id then
				has_pending = true
				local pc = vim.tbl_extend("force", {}, c)
				pc.is_pending = true
				table.insert(pending_comments, pc)
			else
				submitted_count = submitted_count + 1
				table.insert(submitted_comments, c)
			end
		end

		if style == "inline" then
			-- Inline mode: display full comment content below the line
			local all_comments_for_display = {}
			for _, c in ipairs(submitted_comments) do
				table.insert(all_comments_for_display, c)
			end
			for _, c in ipairs(pending_comments) do
				table.insert(all_comments_for_display, c)
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

return M
