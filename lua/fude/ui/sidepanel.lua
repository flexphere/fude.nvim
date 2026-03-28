local M = {}
local config = require("fude.config")

-- Lazy requires
local function get_scope()
	return require("fude.scope")
end
local function get_files()
	return require("fude.files")
end
local function get_gh()
	return require("fude.gh")
end
local function get_diff()
	return require("fude.diff")
end

-- Dedicated namespace for sidepanel highlights (avoids collision with refresh_extmarks)
local sidepanel_ns = vim.api.nvim_create_namespace("fude_sidepanel")

--- Truncate a string to fit within a given display width.
--- Handles multi-byte and wide (CJK) characters correctly.
--- @param text string input text
--- @param max_width number maximum display width
--- @return string truncated text (with "…" suffix if truncated)
function M.truncate_to_width(text, max_width)
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	-- Binary search for the right character count
	local char_len = vim.fn.strchars(text)
	local lo, hi = 0, char_len
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		local sub = vim.fn.strcharpart(text, 0, mid)
		if vim.fn.strdisplaywidth(sub) <= max_width - 1 then -- -1 for "…"
			lo = mid
		else
			hi = mid - 1
		end
	end
	return vim.fn.strcharpart(text, 0, lo) .. "…"
end

--- Format the scope section lines for the sidepanel.
--- @param scope_entries table[] entries from scope.build_scope_entries
--- @param width number available width in columns
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of scope entries
function M.format_scope_section(scope_entries, width)
	local lines = { " Review Scope", string.rep("─", width) }
	local highlights = {
		{ 0, 0, -1, "Title" },
	}

	for _, entry in ipairs(scope_entries) do
		local current_icon = entry.is_current and "▶" or " "
		local reviewed_icon = entry.reviewed_icon or " "
		local text = current_icon .. " " .. reviewed_icon .. " " .. entry.display_text
		text = M.truncate_to_width(text, width)
		local line_idx = #lines
		table.insert(lines, text)

		-- Current scope highlight
		if entry.is_current then
			table.insert(highlights, { line_idx, 0, #current_icon, "DiagnosticInfo" })
		end
		-- Reviewed icon highlight
		local reviewed_start = #current_icon + 1
		local reviewed_end = reviewed_start + #reviewed_icon
		if entry.reviewed_hl then
			table.insert(highlights, { line_idx, reviewed_start, reviewed_end, entry.reviewed_hl })
		end
	end

	return lines, highlights, #scope_entries
end

--- Format the files section lines for the sidepanel.
--- @param file_entries table[] entries from files.build_file_entries
--- @param width number available width in columns
--- @param format_path_fn fun(s: string): string formats file path for display
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of file entries
function M.format_files_section(file_entries, width, format_path_fn)
	format_path_fn = format_path_fn or function(p)
		return p
	end
	local lines = { string.format(" Files (%d)", #file_entries), string.rep("─", width) }
	local highlights = {
		{ 0, 0, -1, "Title" },
	}

	for _, entry in ipairs(file_entries) do
		local viewed = entry.viewed_icon or " "
		local status = entry.status_icon or "?"
		local adds = string.format("+%-3d", entry.additions or 0)
		local dels = string.format("-%-3d", entry.deletions or 0)
		local raw = format_path_fn(entry.path)
		local display_name = type(raw) == "string" and raw or entry.path
		local text = " " .. viewed .. " " .. status .. " " .. adds .. " " .. dels .. " " .. display_name
		text = M.truncate_to_width(text, width)
		local line_idx = #lines
		table.insert(lines, text)

		-- Viewed icon highlight
		table.insert(highlights, { line_idx, 1, 1 + #viewed, entry.viewed_hl or "Comment" })
		-- Status icon highlight
		local status_start = 1 + #viewed + 1
		table.insert(highlights, { line_idx, status_start, status_start + #status, entry.status_hl or "DiffChange" })
		-- Additions highlight
		local adds_start = status_start + #status + 1
		table.insert(highlights, { line_idx, adds_start, adds_start + #adds, "DiffAdd" })
		-- Deletions highlight
		local dels_start = adds_start + #adds + 1
		table.insert(highlights, { line_idx, dels_start, dels_start + #dels, "DiffDelete" })
	end

	return lines, highlights, #file_entries
end

--- Build the full sidepanel buffer content from scope and files sections.
--- @param scope_lines string[]
--- @param scope_hls table[]
--- @param scope_count number
--- @param file_lines string[]
--- @param file_hls table[]
--- @param file_count number
--- @return string[] lines combined lines
--- @return table[] highlights combined highlights (line indices adjusted)
--- @return table section_map { scope_start, scope_end, files_start, files_end, scope_entry_offset, files_entry_offset }
function M.build_sidepanel_content(scope_lines, scope_hls, scope_count, file_lines, file_hls, file_count)
	local lines = {}
	local highlights = {}

	-- Scope section
	local scope_offset = 0
	for _, l in ipairs(scope_lines) do
		table.insert(lines, l)
	end
	for _, hl in ipairs(scope_hls) do
		table.insert(highlights, { hl[1] + scope_offset, hl[2], hl[3], hl[4] })
	end

	-- Blank line separator
	table.insert(lines, "")

	-- Files section
	local files_offset = #lines
	for _, l in ipairs(file_lines) do
		table.insert(lines, l)
	end
	for _, hl in ipairs(file_hls) do
		table.insert(highlights, { hl[1] + files_offset, hl[2], hl[3], hl[4] })
	end

	-- Section map: header (1 line) + separator (1 line) = 2 lines before entries
	local scope_entry_offset = 2 -- 0-indexed: entries start at line 2
	local files_entry_offset = files_offset + 2 -- entries start 2 lines after files_offset

	local section_map = {
		scope_start = scope_entry_offset, -- 0-indexed first scope entry line
		scope_end = scope_entry_offset + scope_count - 1, -- 0-indexed last scope entry line
		files_start = files_entry_offset, -- 0-indexed first file entry line
		files_end = files_entry_offset + file_count - 1, -- 0-indexed last file entry line
		scope_entry_offset = scope_entry_offset,
		files_entry_offset = files_entry_offset,
	}

	return lines, highlights, section_map
end

--- Resolve which entry the cursor is on.
--- @param cursor_line number 1-based cursor line
--- @param section_map table from build_sidepanel_content
--- @return table|nil { type = "scope"|"file", index = N (1-based) } or nil if on header/separator/blank
function M.resolve_entry_at_cursor(cursor_line, section_map)
	local line_0 = cursor_line - 1 -- Convert to 0-indexed

	if line_0 >= section_map.scope_start and line_0 <= section_map.scope_end then
		return { type = "scope", index = line_0 - section_map.scope_start + 1 }
	end

	if line_0 >= section_map.files_start and line_0 <= section_map.files_end then
		return { type = "file", index = line_0 - section_map.files_start + 1 }
	end

	return nil
end

--- Close the sidepanel and clean up state.
function M.close()
	local state = config.state
	local panel = state.sidepanel
	if not panel then
		return
	end

	if panel.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, panel.augroup)
	end

	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		vim.cmd("noautocmd call nvim_win_close(" .. panel.win .. ", v:true)")
	end

	state.sidepanel = nil
end

--- Render the sidepanel content into the buffer.
--- @param panel table sidepanel state
local function render(panel)
	local state = config.state
	local scope_mod = get_scope()
	local files_mod = get_files()
	local diff_mod = get_diff()
	local comments_data = require("fude.comments.data")

	local sp_opts = config.opts.sidepanel or {}
	local width = math.max(20, sp_opts.width or 40)

	-- Build scope entries
	local commit_entries = {}
	if #state.pr_commits > 0 then
		commit_entries = get_gh().parse_commit_entries(state.pr_commits)
	end
	local scope_entries = scope_mod.build_scope_entries(
		commit_entries,
		state.base_ref or "",
		state.head_ref or "",
		state.reviewed_commits,
		state.scope,
		state.scope_commit_sha
	)

	-- Build file entries
	local repo_root = diff_mod.get_repo_root()
	local viewed_sign = (config.opts.signs and config.opts.signs.viewed) or "✓"
	local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)
	local file_entries = files_mod.build_file_entries(
		state.changed_files or {},
		repo_root or "",
		files_mod.status_icons,
		state.viewed_files,
		viewed_sign,
		comment_counts
	)

	-- Format sections
	local scope_lines, scope_hls, scope_count = M.format_scope_section(scope_entries, width)
	local file_lines, file_hls, file_count = M.format_files_section(file_entries, width, config.format_path)
	local lines, highlights, section_map =
		M.build_sidepanel_content(scope_lines, scope_hls, scope_count, file_lines, file_hls, file_count)

	-- Update buffer
	local buf = panel.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	-- Apply highlights (using dedicated namespace to avoid refresh_extmarks clearing them)
	vim.api.nvim_buf_clear_namespace(buf, sidepanel_ns, 0, -1)
	for _, hl in ipairs(highlights) do
		pcall(vim.api.nvim_buf_add_highlight, buf, sidepanel_ns, hl[4], hl[1], hl[2], hl[3])
	end

	-- Store entries and map for keymap handlers
	panel.scope_entries = scope_entries
	panel.file_entries = file_entries
	panel.section_map = section_map
end

--- Refresh the sidepanel content (re-render with current state).
function M.refresh()
	local panel = config.state.sidepanel
	if not panel then
		return
	end
	if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
		config.state.sidepanel = nil
		return
	end

	-- Save cursor position
	local cursor = vim.api.nvim_win_get_cursor(panel.win)

	render(panel)

	-- Restore cursor position (clamped to new line count)
	if vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_buf_is_valid(panel.buf) then
		local line_count = vim.api.nvim_buf_line_count(panel.buf)
		local new_row = math.min(cursor[1], line_count)
		pcall(vim.api.nvim_win_set_cursor, panel.win, { new_row, cursor[2] })
	end
end

--- Open the sidepanel.
function M.open()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	-- Close existing panel
	M.close()

	local sp_opts = config.opts.sidepanel or {}
	local width = math.max(20, sp_opts.width or 40)
	local position = sp_opts.position or "left"

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	-- Create split window
	local split_dir = position == "right" and "right" or "left"
	local win = vim.api.nvim_open_win(buf, true, {
		split = split_dir,
		width = width,
	})

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].spell = false
	vim.wo[win].list = false

	pcall(vim.api.nvim_buf_set_name, buf, "[fude] Panel")

	-- Save state
	local panel = {
		win = win,
		buf = buf,
		scope_entries = {},
		file_entries = {},
		section_map = nil,
		augroup = nil,
	}
	state.sidepanel = panel

	-- WinClosed autocmd
	local augroup = vim.api.nvim_create_augroup("fude_sidepanel_" .. win, { clear = true })
	panel.augroup = augroup
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == win then
				M.close()
			end
		end,
	})

	-- Render content
	render(panel)

	-- Place cursor on first scope entry
	if panel.section_map then
		pcall(vim.api.nvim_win_set_cursor, win, { panel.section_map.scope_start + 1, 0 })
	end

	-- Setup keymaps
	M.setup_keymaps(panel)
end

--- Toggle the sidepanel open or closed.
function M.toggle()
	local panel = config.state.sidepanel
	if panel and panel.win and vim.api.nvim_win_is_valid(panel.win) then
		M.close()
	else
		M.open()
	end
end

--- Setup keymaps for the sidepanel buffer.
--- @param panel table sidepanel state
function M.setup_keymaps(panel)
	local buf = panel.buf

	-- Close
	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, desc = "Close side panel" })

	-- Refresh (reload from GitHub)
	vim.keymap.set("n", "R", function()
		local init_mod = require("fude.init")
		init_mod.reload()
	end, { buffer = buf, desc = "Reload review data" })

	-- Select / Open
	vim.keymap.set("n", "<CR>", function()
		local entry_info = M.get_current_entry(panel)
		if not entry_info then
			return
		end

		if entry_info.type == "scope" then
			local scope_mod = get_scope()
			scope_mod.apply_scope(entry_info.entry)
		elseif entry_info.type == "file" then
			local filename = entry_info.entry.filename
			if filename then
				-- Move to a non-panel window before opening the file
				local target_win = M.find_target_window(panel.win)
				if target_win then
					vim.api.nvim_set_current_win(target_win)
				end
				vim.cmd("edit " .. vim.fn.fnameescape(filename))
			end
		end
	end, { buffer = buf, desc = "Select scope or open file" })

	-- Tab: toggle reviewed/viewed
	vim.keymap.set("n", "<Tab>", function()
		local entry_info = M.get_current_entry(panel)
		if not entry_info then
			return
		end

		if entry_info.type == "scope" then
			M.toggle_scope_reviewed(panel, entry_info)
		elseif entry_info.type == "file" then
			M.toggle_file_viewed(panel, entry_info)
		end
	end, { buffer = buf, desc = "Toggle reviewed/viewed" })
end

--- Get the entry under the cursor.
--- @param panel table sidepanel state
--- @return table|nil { type, index, entry }
function M.get_current_entry(panel)
	if not panel.section_map then
		return nil
	end
	if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
	local result = M.resolve_entry_at_cursor(cursor_line, panel.section_map)
	if not result then
		return nil
	end

	if result.type == "scope" then
		local entry = panel.scope_entries[result.index]
		if entry then
			return { type = "scope", index = result.index, entry = entry }
		end
	elseif result.type == "file" then
		local entry = panel.file_entries[result.index]
		if entry then
			return { type = "file", index = result.index, entry = entry }
		end
	end

	return nil
end

--- Find a suitable window to open files in (not the sidepanel or preview).
--- @param panel_win number sidepanel window handle
--- @return number|nil target window handle
function M.find_target_window(panel_win)
	local state = config.state
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= panel_win and win ~= state.preview_win then
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].buftype == "" then
				return win
			end
		end
	end
	-- Fallback: any window that isn't the panel
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= panel_win then
			return win
		end
	end
	return nil
end

--- Toggle reviewed state for a scope entry.
--- @param panel table sidepanel state
--- @param entry_info table { type, index, entry }
function M.toggle_scope_reviewed(_panel, entry_info)
	local entry = entry_info.entry
	if entry.is_full_pr then
		return
	end
	local sha = entry.sha
	if not sha then
		return
	end

	local state = config.state
	if state.reviewed_commits[sha] then
		state.reviewed_commits[sha] = nil
	else
		state.reviewed_commits[sha] = true
	end

	M.refresh()
end

--- Toggle viewed state for a file entry.
--- @param panel table sidepanel state
--- @param entry_info table { type, index, entry }
function M.toggle_file_viewed(_panel, entry_info)
	local state = config.state
	if not state.pr_node_id then
		vim.notify("fude.nvim: PR node ID not available", vim.log.levels.WARN)
		return
	end

	local entry = entry_info.entry
	local path = entry.path
	local current_state = state.viewed_files[path]
	local gh_mod = get_gh()
	local captured_state = config.state

	if current_state == "VIEWED" then
		gh_mod.unmark_file_viewed(state.pr_node_id, path, function(err)
			if config.state ~= captured_state then
				return
			end
			if err then
				vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
				return
			end
			state.viewed_files[path] = "UNVIEWED"
			M.refresh()
		end)
	else
		gh_mod.mark_file_viewed(state.pr_node_id, path, function(err)
			if config.state ~= captured_state then
				return
			end
			if err then
				vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
				return
			end
			state.viewed_files[path] = "VIEWED"
			M.refresh()
		end)
	end
end

return M
