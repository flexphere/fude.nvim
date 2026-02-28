local M = {}
local config = require("reviewit.config")
local diff = require("reviewit.diff")

local opening = false

--- Open a preview window showing the base branch version of the current file.
--- @param source_win number window handle of the file being viewed
function M.open_preview(source_win)
	local state = config.state
	if not state.active or opening then
		return
	end

	opening = true

	local source_buf = vim.api.nvim_win_get_buf(source_win)
	local filepath = vim.api.nvim_buf_get_name(source_buf)
	local rel_path = diff.to_repo_relative(filepath)

	if not rel_path then
		M.close_preview()
		opening = false
		return
	end

	local content, _ = diff.get_base_content(state.base_ref, rel_path)

	M.close_preview()

	if not content then
		content = "-- [reviewit.nvim] New file: does not exist in " .. state.base_ref
	end

	local preview_buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(content, "\n", { trimempty = false })
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)

	vim.bo[preview_buf].modifiable = false
	vim.bo[preview_buf].readonly = true
	vim.bo[preview_buf].buftype = "nofile"
	vim.bo[preview_buf].bufhidden = "wipe"

	local ft = vim.bo[source_buf].filetype
	if ft and ft ~= "" then
		vim.bo[preview_buf].filetype = ft
	end

	-- Use noautocmd to prevent BufEnter cascades
	vim.cmd("noautocmd call nvim_set_current_win(" .. source_win .. ")")
	vim.cmd("noautocmd vsplit")
	local preview_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(preview_win, preview_buf)

	vim.wo[preview_win].number = true
	vim.wo[preview_win].relativenumber = false
	vim.wo[preview_win].signcolumn = "no"
	vim.wo[preview_win].winfixwidth = true

	pcall(vim.api.nvim_buf_set_name, preview_buf, "[base] " .. rel_path)

	state.preview_win = preview_win
	state.preview_buf = preview_buf
	state.source_win = source_win

	-- Enable diff mode on both windows
	vim.cmd("noautocmd call nvim_set_current_win(" .. preview_win .. ")")
	vim.cmd("diffthis")
	if config.opts.diff_filler_char then
		vim.wo[preview_win].fillchars = "diff:" .. config.opts.diff_filler_char
	end
	vim.cmd("noautocmd call nvim_set_current_win(" .. source_win .. ")")
	vim.cmd("diffthis")
	if config.opts.diff_filler_char then
		vim.wo[source_win].fillchars = "diff:" .. config.opts.diff_filler_char
	end

	-- Create preview-specific autocmds
	local preview_augroup = vim.api.nvim_create_augroup("ReviewitPreview", { clear = true })

	vim.api.nvim_create_autocmd("BufEnter", {
		group = preview_augroup,
		callback = function()
			vim.schedule(function()
				M.on_buf_enter()
			end)
		end,
		desc = "reviewit.nvim: Update diff preview",
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = preview_augroup,
		callback = function(args)
			local closed_win = tonumber(args.match)
			if closed_win == state.source_win then
				M.close_preview()
			end
		end,
		desc = "reviewit.nvim: Clean up preview on source close",
	})

	opening = false
end

--- Close the preview window and clean up diff mode.
function M.close_preview()
	local state = config.state

	pcall(vim.api.nvim_del_augroup_by_name, "ReviewitPreview")

	-- diffoff! resets diff mode for all windows in the current tab
	vim.cmd("diffoff!")

	if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
		vim.cmd("noautocmd call nvim_win_close(" .. state.preview_win .. ", v:true)")
	end

	state.preview_win = nil
	state.preview_buf = nil
end

--- Determine whether the preview should be opened for the given context.
--- @param active boolean whether review mode is active
--- @param is_opening boolean whether a preview is currently being opened
--- @param win number current window handle
--- @param preview_win number|nil handle of the existing preview window
--- @param buftype string buffer type of the current buffer
--- @param filepath string file path of the current buffer
--- @return boolean
function M.should_open_preview(active, is_opening, win, preview_win, buftype, filepath)
	if not active or is_opening then
		return false
	end
	if win == preview_win then
		return false
	end
	if buftype ~= "" then
		return false
	end
	if filepath == "" then
		return false
	end
	return true
end

--- BufEnter handler: update the preview for the newly entered buffer.
function M.on_buf_enter()
	local state = config.state
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	if
		M.should_open_preview(
			state.active,
			opening,
			win,
			state.preview_win,
			vim.bo[buf].buftype,
			vim.api.nvim_buf_get_name(buf)
		)
	then
		M.open_preview(win)
	end
end

return M
