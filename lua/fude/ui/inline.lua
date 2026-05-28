local M = {}

local format = require("fude.ui.format")

--- Wrap a line to fit within max_width (display cells).
--- @param line string input line
--- @param max_width number maximum display width
--- @return string[] wrapped lines
local function wrap_line(line, max_width)
	if vim.fn.strdisplaywidth(line) <= max_width then
		return { line }
	end

	local result = {}
	local current = ""
	local current_width = 0

	for char in line:gmatch(".[\128-\191]*") do
		local char_width = vim.fn.strdisplaywidth(char)
		if current_width + char_width > max_width then
			table.insert(result, current)
			current = char
			current_width = char_width
		else
			current = current .. char
			current_width = current_width + char_width
		end
	end

	if current ~= "" then
		table.insert(result, current)
	end

	return result
end

--- Format comments for inline display (virt_lines below code line).
--- Reads the current window's text width to size comment boxes, which is
--- why this lives in ui/inline.lua rather than the pure ui/format.lua.
--- @param comments table[] list of comment objects
--- @param format_date_fn fun(s: string): string
--- @param opts table|nil inline display options (see config.defaults.inline)
--- @return table { virt_lines: table[][] } virt_line chunks for nvim_buf_set_extmark
function M.format_comments_for_inline(comments, format_date_fn, opts)
	opts = opts or {}
	local show_author = opts.show_author ~= false
	local show_timestamp = opts.show_timestamp ~= false
	local hl_group = opts.hl_group or "Comment"
	local author_hl = opts.author_hl or "Title"
	local timestamp_hl = opts.timestamp_hl or "NonText"
	local border_hl = opts.border_hl or "DiagnosticInfo"
	local md_enabled = opts.markdown_highlight ~= false
	local md_hl = opts.markdown_hl or {}

	local virt_lines = {}
	local indent = "    " -- Left margin (4 chars)
	local indent_width = 4
	local right_margin = 4

	-- Calculate available text area width
	local win = vim.api.nvim_get_current_win()
	local win_width = vim.api.nvim_win_get_width(win)
	local textoff = vim.fn.getwininfo(win)[1].textoff or 0
	local text_width = win_width - textoff

	-- Max width to fit "reply from floating window" x4 = 107 chars
	local max_body_width = 107
	local max_box_width = max_body_width + 4

	-- Use smaller of max width or available window width
	local available_width = text_width - indent_width - right_margin
	local box_width = math.min(max_box_width, math.max(50, available_width))
	local body_max_width = box_width - 6

	for i, comment in ipairs(comments) do
		local is_pending = comment.is_pending

		-- Top border: ╭─ Comment ─────────────────────╮
		-- Use strdisplaywidth for correct UTF-8 width calculation
		local label = is_pending and " Comment [pending] " or " Comment "
		local corner_width = 2 -- ╭ and ╮ are 1 cell each
		local left_dash_width = 1 -- ─ after ╭
		local label_display_width = vim.fn.strdisplaywidth(label)
		local right_padding = math.max(0, box_width - corner_width - left_dash_width - label_display_width)
		local top_border = indent .. "╭─" .. label .. string.rep("─", right_padding) .. "╮"
		table.insert(virt_lines, { { top_border, border_hl } })

		-- Author/timestamp line
		if show_author or show_timestamp then
			local author = comment.user and comment.user.login or "unknown"
			local created = format_date_fn(comment.created_at)

			local header_chunks = {}
			table.insert(header_chunks, { indent .. "  ", "" })
			if show_author then
				table.insert(header_chunks, { "@" .. author, author_hl })
			end
			if show_timestamp then
				if show_author then
					table.insert(header_chunks, { " ", hl_group })
				end
				table.insert(header_chunks, { "(" .. created .. ")", timestamp_hl })
			end
			table.insert(virt_lines, header_chunks)
		end

		-- Comment body with wrapping and optional markdown highlighting
		local body = format.normalize_newlines(comment.body)
		local body_lines = vim.split(body, "\n")
		local in_code_block = false

		for _, body_line in ipairs(body_lines) do
			-- Wrap long lines
			local wrapped = wrap_line(body_line, body_max_width)
			for _, wrapped_line in ipairs(wrapped) do
				local chunks, new_in_code_block =
					format.apply_markdown_highlight_to_line(wrapped_line, in_code_block, hl_group, md_hl, md_enabled)
				in_code_block = new_in_code_block

				-- Build virt_line with indent + highlighted chunks
				local virt_line = { { indent .. "  ", "" } }
				for _, chunk in ipairs(chunks) do
					table.insert(virt_line, chunk)
				end
				table.insert(virt_lines, virt_line)
			end
		end

		-- Bottom border: ╰─────────────────────────────╯
		-- box_width - 2 for corner characters (╰ and ╯ are 1 cell each)
		local bottom_border = indent .. "╰" .. string.rep("─", box_width - 2) .. "╯"
		table.insert(virt_lines, { { bottom_border, border_hl } })

		-- Add spacing between multiple comments
		if i < #comments then
			table.insert(virt_lines, { { "", hl_group } })
		end
	end

	return { virt_lines = virt_lines }
end

return M
