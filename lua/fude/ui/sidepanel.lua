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
--- @param format_path_fn (fun(s: string): string|nil)|nil formats file path for display (nil = identity)
--- @param viewed_count number count of files with VIEWED state
--- @param current_path string|nil repo-relative path of the currently open file
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of file entries
function M.format_files_section(file_entries, width, format_path_fn, viewed_count, current_path)
	format_path_fn = format_path_fn or function(p)
		return p
	end
	viewed_count = viewed_count or 0
	local lines = { string.format(" Files (Reviewed: %d/%d)", viewed_count, #file_entries), string.rep("─", width) }
	local highlights = {
		{ 0, 0, -1, "Title" },
	}

	for _, entry in ipairs(file_entries) do
		local is_current = current_path and entry.path == current_path
		local current_icon = is_current and "▶" or " "
		local viewed = entry.viewed_icon or " "
		local status = entry.status_icon or "?"
		local adds = string.format("+%-3d", entry.additions or 0)
		local dels = string.format("-%-3d", entry.deletions or 0)
		local raw = format_path_fn(entry.path)
		local display_name = type(raw) == "string" and raw or entry.path
		local text = current_icon .. " " .. viewed .. " " .. status .. " " .. adds .. " " .. dels .. " " .. display_name
		local line_idx = #lines
		table.insert(lines, text)

		-- Current file highlight
		if is_current then
			table.insert(highlights, { line_idx, 0, #current_icon, "DiagnosticInfo" })
		end
		-- Viewed icon highlight
		local viewed_start = #current_icon + 1
		table.insert(highlights, { line_idx, viewed_start, viewed_start + #viewed, entry.viewed_hl or "Comment" })
		-- Status icon highlight
		local status_start = viewed_start + #viewed + 1
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

--- Format the files section lines as a directory tree.
--- @param tree_entries table[] entries from ui.sidepanel.tree.flatten_tree
--- @param total_file_count number total number of changed files
--- @param width number available width in columns
--- @param viewed_count number count of files with VIEWED state
--- @param current_path string|nil repo-relative path of the currently open file
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of rendered tree entries
function M.format_files_section_tree(tree_entries, total_file_count, width, viewed_count, current_path)
	viewed_count = viewed_count or 0
	local lines = { string.format(" Files (Reviewed: %d/%d)", viewed_count, total_file_count), string.rep("─", width) }
	local highlights = {
		{ 0, 0, -1, "Title" },
	}

	for _, entry in ipairs(tree_entries) do
		local indent = string.rep("  ", entry.depth)
		local line_idx = #lines

		if entry.type == "directory" then
			local viewed_all = entry.total_files > 0 and entry.viewed_files == entry.total_files
			local viewed_sign = (config.opts.signs and config.opts.signs.viewed) or "✓"
			local viewed_marker = viewed_all and (" " .. viewed_sign) or ""
			local text = indent .. entry.name .. viewed_marker
			table.insert(lines, text)

			local pos = #indent
			table.insert(highlights, { line_idx, pos, pos + #entry.name, "Directory" })
			if viewed_all then
				local viewed_hl = (config.opts.signs and config.opts.signs.viewed_hl) or "DiagnosticOk"
				local marker_start = pos + #entry.name + 1
				table.insert(highlights, { line_idx, marker_start, marker_start + #viewed_sign, viewed_hl })
			end
		else
			local f = entry.file or {}
			local is_current = current_path and entry.path == current_path
			local current_icon = is_current and "▶" or " "
			local viewed = f.viewed_icon or " "
			local status = f.status_icon or "?"
			local adds = string.format("+%-3d", f.additions or 0)
			local dels = string.format("-%-3d", f.deletions or 0)
			local text = indent
				.. current_icon
				.. " "
				.. viewed
				.. " "
				.. status
				.. " "
				.. adds
				.. " "
				.. dels
				.. " "
				.. entry.name
			table.insert(lines, text)

			local ci_start = #indent
			if is_current then
				table.insert(highlights, { line_idx, ci_start, ci_start + #current_icon, "DiagnosticInfo" })
			end
			local viewed_start = ci_start + #current_icon + 1
			table.insert(highlights, { line_idx, viewed_start, viewed_start + #viewed, f.viewed_hl or "Comment" })
			local status_start = viewed_start + #viewed + 1
			table.insert(highlights, { line_idx, status_start, status_start + #status, f.status_hl or "DiffChange" })
			local adds_start = status_start + #status + 1
			table.insert(highlights, { line_idx, adds_start, adds_start + #adds, "DiffAdd" })
			local dels_start = adds_start + #adds + 1
			table.insert(highlights, { line_idx, dels_start, dels_start + #dels, "DiffDelete" })
		end
	end

	return lines, highlights, #tree_entries
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
		local ok, err = pcall(vim.cmd, "noautocmd call nvim_win_close(" .. panel.win .. ", v:true)")
		if not ok and type(err) == "string" and err:find("Cannot close last window") then
			pcall(vim.cmd, "enew")
		end
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

	-- Build scope entries: local review shows the available local diff scopes,
	-- GitHub review shows Full PR + commits.
	local scope_entries
	if state.review_mode == "local" then
		local specs = state.local_session and require("fude.local.session").scope_specs(state.local_session) or {}
		scope_entries = scope_mod.build_local_scope_entries(specs)
	else
		local commit_entries = {}
		if #state.pr_commits > 0 then
			commit_entries = get_gh().parse_commit_entries(state.pr_commits)
		end
		scope_entries = scope_mod.build_scope_entries(
			commit_entries,
			state.base_ref or "",
			state.head_ref or "",
			state.reviewed_commits,
			state.scope,
			state.scope_commit_sha
		)
	end

	-- Build file entries (skip if repo root unavailable)
	local repo_root = panel.repo_root
	local file_entries = {}
	local viewed_count = 0
	if repo_root then
		local viewed_sign = (config.opts.signs and config.opts.signs.viewed) or "✓"
		local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)
		file_entries = files_mod.build_file_entries(
			state.changed_files or {},
			repo_root,
			files_mod.status_icons,
			state.viewed_files,
			viewed_sign,
			comment_counts
		)
		viewed_count = files_mod.count_viewed(state.viewed_files, state.changed_files or {})
	end

	-- Determine current file path for marker
	local current_path = nil
	if repo_root then
		local current_win = vim.api.nvim_get_current_win()
		local target_win = nil
		if current_win ~= panel.win and current_win ~= state.preview_win then
			local buf = vim.api.nvim_win_get_buf(current_win)
			if vim.bo[buf].buftype == "" then
				target_win = current_win
			end
		end
		target_win = target_win or M.find_target_window(panel.win)
		if target_win then
			local target_buf = vim.api.nvim_win_get_buf(target_win)
			local buf_name = vim.api.nvim_buf_get_name(target_buf)
			if buf_name and buf_name ~= "" then
				local abs_path = vim.fn.fnamemodify(buf_name, ":p")
				current_path = diff_mod.make_relative(abs_path, repo_root)
			end
		end
	end

	-- Format sections
	local scope_lines, scope_hls, scope_count = M.format_scope_section(scope_entries, width)
	local file_lines, file_hls, file_count
	local tree_entries
	if (panel.file_tree_mode or sp_opts.file_tree) == "tree" then
		local tree_mod = require("fude.ui.sidepanel.tree")
		local tree = tree_mod.build_tree(file_entries)
		tree_mod.collapse_singleton_chains(tree)
		tree_entries = tree_mod.flatten_tree(tree, state.viewed_files)
		file_lines, file_hls, file_count =
			M.format_files_section_tree(tree_entries, #file_entries, width, viewed_count, current_path)
	else
		file_lines, file_hls, file_count =
			M.format_files_section(file_entries, width, config.format_path, viewed_count, current_path)
	end

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
	panel.tree_entries = tree_entries
	panel.section_map = section_map

	-- Compute target cursor line for current file (1-based)
	panel.current_file_line = nil
	if current_path and section_map then
		local entries = tree_entries or file_entries
		for i, ent in ipairs(entries) do
			if ent.type ~= "directory" and ent.path == current_path then
				panel.current_file_line = section_map.files_entry_offset + i
				break
			end
		end
	end
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

--- Re-render the sidepanel and move cursor to the currently open file.
--- Used by BufEnter to keep the sidepanel cursor in sync with the active buffer.
function M.follow_current_file()
	local panel = config.state.sidepanel
	if not panel then
		return
	end
	if not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
		config.state.sidepanel = nil
		return
	end

	render(panel)

	if panel.current_file_line and vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_buf_is_valid(panel.buf) then
		local line_count = vim.api.nvim_buf_line_count(panel.buf)
		local target = math.min(panel.current_file_line, line_count)
		pcall(vim.api.nvim_win_set_cursor, panel.win, { target, 0 })
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
		tree_entries = nil,
		section_map = nil,
		augroup = nil,
		file_tree_mode = sp_opts.file_tree or "flat",
		repo_root = get_diff().get_repo_root(),
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
	local keymaps = config.opts.sidepanel and config.opts.sidepanel.keymaps
	if type(keymaps) ~= "table" then
		keymaps = {}
	end

	local function map(action, callback, desc)
		local lhs = keymaps[action]
		if type(lhs) ~= "string" or lhs == "" then
			return
		end
		vim.keymap.set("n", lhs, callback, { buffer = buf, desc = desc })
	end

	-- Close
	map("close", function()
		M.close()
	end, "Close side panel")

	-- Refresh (reload from GitHub)
	map("reload", function()
		local init_mod = require("fude.init")
		init_mod.reload()
	end, "Reload review data")

	-- Select / Open
	map("select", function()
		local entry_info = M.get_current_entry(panel)
		if not entry_info then
			return
		end

		if entry_info.type == "scope" then
			if config.state.review_mode == "local" then
				require("fude.local.session").set_scope(entry_info.entry.local_scope)
			else
				get_scope().apply_scope(entry_info.entry)
			end
		elseif entry_info.type == "file" then
			local filename = entry_info.entry.filename
			if filename then
				M.open_file(panel, filename)
			end
		end
	end, "Select scope or open file")

	-- Toggle reviewed/viewed
	map("toggle_reviewed", function()
		local entry_info = M.get_current_entry(panel)
		if not entry_info then
			return
		end

		if entry_info.type == "scope" then
			-- Local review scopes have no "reviewed" state; switch scope instead.
			if config.state.review_mode == "local" then
				require("fude.local.session").set_scope(entry_info.entry.local_scope)
			else
				M.toggle_scope_reviewed(panel, entry_info)
			end
		elseif entry_info.type == "file" then
			M.toggle_file_viewed(panel, entry_info)
		end
	end, "Toggle reviewed/viewed")

	map("toggle_file_tree", function()
		M.toggle_file_tree_mode(panel)
	end, "Toggle tree/flat file list")
end

--- Open a file in a non-panel, non-preview window.
--- @param panel table sidepanel state
--- @param filename string absolute file path
function M.open_file(panel, filename)
	local target_win = M.find_target_window(panel.win)
	if not target_win then
		vim.notify("fude.nvim: No source window available", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("edit " .. vim.fn.fnameescape(filename))
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
		if panel.tree_entries then
			local tree_entry = panel.tree_entries[result.index]
			if tree_entry then
				if tree_entry.type == "directory" then
					return { type = "directory", index = result.index, entry = tree_entry }
				end
				return { type = "file", index = result.index, entry = tree_entry.file, tree_entry = tree_entry }
			end
		else
			local entry = panel.file_entries[result.index]
			if entry then
				return { type = "file", index = result.index, entry = entry }
			end
		end
	end

	return nil
end

--- Find a suitable window to open files in (not the sidepanel or preview).
--- @param panel_win number sidepanel window handle
--- @return number|nil target window handle
function M.find_target_window(panel_win)
	local state = config.state
	local source_win = state.source_win
	if
		source_win
		and source_win ~= panel_win
		and source_win ~= state.preview_win
		and vim.api.nvim_win_is_valid(source_win)
	then
		return source_win
	end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= panel_win and win ~= state.preview_win then
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].buftype == "" then
				return win
			end
		end
	end
	-- Fallback: any window that isn't the panel or preview
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= panel_win and win ~= state.preview_win then
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

--- Toggle the panel's file display mode for the current panel session.
--- @param panel table|nil sidepanel state (defaults to active panel)
function M.toggle_file_tree_mode(panel)
	panel = panel or config.state.sidepanel
	if not panel then
		vim.notify("fude.nvim: Side panel is not open", vim.log.levels.WARN)
		return
	end
	panel.file_tree_mode = panel.file_tree_mode == "tree" and "flat" or "tree"
	vim.notify("fude.nvim: File list mode: " .. panel.file_tree_mode, vim.log.levels.INFO)
	M.refresh()
end

--- Toggle viewed state for a file entry. Delegates to the picker-agnostic
--- `files.apply_viewed_toggle`, which routes to the GitHub GraphQL API or the
--- local review JSONL store by review mode (so `<Tab>` works in local mode,
--- not just GitHub), then refreshes the panel.
--- @param _panel table|nil sidepanel state (unused; kept for call-site symmetry)
--- @param entry_info table { type, index, entry }
function M.toggle_file_viewed(_panel, entry_info)
	local path = entry_info.entry.path
	get_files().apply_viewed_toggle(path, function()
		M.refresh()
	end)
end

return M
