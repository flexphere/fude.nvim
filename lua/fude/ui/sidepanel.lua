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
local status_labels = { added = "A", modified = "M", removed = "D", renamed = "R", copied = "C" }
-- Diff* groups often only set a background; status letters need foreground colors.
local status_highlights = {
	added = "DiagnosticOk",
	modified = "DiagnosticWarn",
	removed = "DiagnosticError",
	renamed = "DiagnosticInfo",
	copied = "DiagnosticInfo",
}

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

-- Widths use display cells; highlight columns use byte offsets.
local function truncate_display(text, width)
	if width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local budget = width - vim.fn.strdisplaywidth("…")
	if budget < 0 then
		return ""
	end
	local lo, hi = 0, vim.fn.strchars(text, true)
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid, true)) <= budget then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return vim.fn.strcharpart(text, 0, lo, true) .. "…"
end

local function file_columns(file_entries, opts)
	local columns = {
		current = vim.fn.strdisplaywidth("▶"),
		viewed = math.max(
			1,
			vim.fn.strdisplaywidth(opts.viewed_icon or "✓"),
			vim.fn.strdisplaywidth(opts.unviewed_icon or "○")
		),
		icon = math.max(
			vim.fn.strdisplaywidth(opts.directory_icon or ""),
			vim.fn.strdisplaywidth(opts.directory_closed_icon or "")
		),
		adds = 2,
		dels = 2,
	}
	for _, entry in ipairs(file_entries) do
		columns.viewed = math.max(columns.viewed, vim.fn.strdisplaywidth(entry.viewed_icon or " "))
		columns.icon = math.max(columns.icon, vim.fn.strdisplaywidth(entry.file_icon or ""))
		columns.adds = math.max(columns.adds, #string.format("+%d", entry.additions or 0))
		columns.dels = math.max(columns.dels, #string.format("-%d", entry.deletions or 0))
	end
	return columns
end

-- Flat and tree rows share the same fixed columns and right-aligned stats.
local function format_file_row(row, width, columns)
	width = math.max(0, width)
	local prefix_width = columns.current + columns.viewed + 4
	local disclosure_width = row.tree and 2 or 0
	local stats_width = columns.adds + 1 + columns.dels
	-- Do not show partial numbers when even one name cell cannot fit.
	local show_stats = row.additions ~= nil and width >= prefix_width + disclosure_width + stats_width + 2
	local limit = width - (show_stats and stats_width + 1 or 0)
	local text, highlights = "", {}
	local function append(value, hl)
		value = truncate_display(value, limit - vim.fn.strdisplaywidth(text))
		local start_col = #text
		text = text .. value
		if hl and #value > 0 then
			table.insert(highlights, { start_col, #text, hl })
		end
	end
	local function field(value, cells, hl)
		append(value, hl)
		append(string.rep(" ", math.max(0, cells - vim.fn.strdisplaywidth(value))) .. " ")
	end

	field(row.is_current and "▶" or " ", columns.current, row.is_current and "DiagnosticInfo" or nil)
	field(row.viewed or " ", columns.viewed, row.viewed_hl or "Comment")
	field(row.status or " ", 1, row.status_hl)

	local available = math.max(0, limit - vim.fn.strdisplaywidth(text) - disclosure_width)
	-- Reserve name cells before spending the remaining space on icons and indentation.
	local show_icon = columns.icon > 0 and available >= columns.icon + 5
	local icon_width = show_icon and columns.icon + 1 or 0
	local indent = math.min((row.depth or 0) * 2, math.max(0, available - icon_width - 4))
	append(string.rep(" ", indent))
	if row.tree then
		field(row.disclosure or " ", 1, row.disclosure and "Directory" or nil)
	end
	if show_icon then
		field(row.icon or "", columns.icon, row.icon_hl)
	end
	append(row.name, row.name_hl)

	if show_stats then
		limit = width
		append(string.rep(" ", width - stats_width - vim.fn.strdisplaywidth(text)))
		local adds = string.format("+%d", row.additions)
		local dels = string.format("-%d", row.deletions or 0)
		append(string.rep(" ", columns.adds - #adds))
		append(adds, "DiffAdd")
		append(" " .. string.rep(" ", columns.dels - #dels))
		append(dels, "DiffDelete")
	end
	return text, highlights
end

local function append_file_row(lines, highlights, row, width, columns)
	local text, row_hls = format_file_row(row, width, columns)
	local line_idx = #lines
	table.insert(lines, text)
	for _, hl in ipairs(row_hls) do
		table.insert(highlights, { line_idx, hl[1], hl[2], hl[3] })
	end
end

--- Format the files section lines for the sidepanel.
--- @param file_entries table[] entries from files.build_file_entries; optional file_icon/file_icon_hl
--- @param width number available width in display cells
--- @param format_path_fn (fun(s: string): string|nil)|nil formats file path for display (nil = identity)
--- @param viewed_count number count of files with VIEWED state
--- @param current_path string|nil repo-relative path of the currently open file
--- @param opts table|nil { viewed_icon?: string, unviewed_icon?: string, unviewed_hl?: string }
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of file entries
function M.format_files_section(file_entries, width, format_path_fn, viewed_count, current_path, opts)
	format_path_fn = format_path_fn or function(p)
		return p
	end
	viewed_count = viewed_count or 0
	local lines =
		{ string.format(" Files (Reviewed: %d/%d)", viewed_count, #file_entries), string.rep("─", math.max(0, width)) }
	local highlights = { { 0, 0, -1, "Title" } }
	opts = opts or {}
	local columns = file_columns(file_entries, opts)

	for _, entry in ipairs(file_entries) do
		local raw = format_path_fn(entry.path)
		append_file_row(lines, highlights, {
			is_current = current_path ~= nil and entry.path == current_path,
			viewed = entry.viewed_icon or opts.unviewed_icon or "○",
			viewed_hl = entry.viewed_hl or opts.unviewed_hl,
			status = entry.status_icon or "?",
			status_hl = entry.status_hl or "DiffChange",
			icon = entry.file_icon,
			icon_hl = entry.file_icon_hl,
			name = type(raw) == "string" and raw or entry.path,
			additions = entry.additions or 0,
			deletions = entry.deletions or 0,
		}, width, columns)
	end

	return lines, highlights, #file_entries
end

--- Format the files section lines as a directory tree.
--- @param tree_entries table[] entries from ui.sidepanel.tree.flatten_tree
--- @param total_file_count number total number of changed files
--- @param width number available width in display cells
--- @param viewed_count number count of files with VIEWED state
--- @param current_path string|nil repo-relative path of the currently open file
--- @param opts table|nil review signs/highlights, directory icons, and all_file_entries (including hidden files)
--- @return string[] lines
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
--- @return number entry_count number of rendered tree entries
function M.format_files_section_tree(tree_entries, total_file_count, width, viewed_count, current_path, opts)
	opts = opts or {}
	viewed_count = viewed_count or 0
	local lines =
		{ string.format(" Files (Reviewed: %d/%d)", viewed_count, total_file_count), string.rep("─", math.max(0, width)) }
	local highlights = { { 0, 0, -1, "Title" } }
	local file_entries = opts.all_file_entries
	if not file_entries then
		file_entries = {}
		for _, entry in ipairs(tree_entries) do
			if entry.type ~= "directory" then
				table.insert(file_entries, entry.file or {})
			end
		end
	end
	local columns = file_columns(file_entries, opts)

	for _, entry in ipairs(tree_entries) do
		local row = { name = entry.name, depth = entry.depth, tree = true }
		if entry.type == "directory" then
			row.disclosure = entry.collapsed and "▸" or "▾"
			if entry.collapsed and (entry.total_files or 0) > 0 then
				local viewed_all = entry.viewed_files == entry.total_files
				if viewed_all then
					row.viewed = opts.viewed_icon or "✓"
					row.viewed_hl = opts.viewed_hl or "DiagnosticOk"
				else
					row.viewed = opts.unviewed_icon or "○"
					row.viewed_hl = opts.unviewed_hl or "Comment"
				end
			end
			row.icon = entry.collapsed and (opts.directory_closed_icon or opts.directory_icon) or opts.directory_icon
			row.icon_hl = "Directory"
			row.name_hl = "Directory"
		else
			local f = entry.file or {}
			row.is_current = current_path ~= nil and entry.path == current_path
			row.viewed = f.viewed_icon or opts.unviewed_icon or "○"
			row.viewed_hl = f.viewed_hl or opts.unviewed_hl
			row.status = f.status_icon or "?"
			row.status_hl = f.status_hl or "DiffChange"
			row.icon = f.file_icon
			row.icon_hl = f.file_icon_hl
			row.additions = f.additions or 0
			row.deletions = f.deletions or 0
		end
		append_file_row(lines, highlights, row, width, columns)
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

--- Close the sidepanel and clean up state. When the panel is the current
--- window, focus returns to the window it was opened/focused from
--- (`panel.prev_win`); when the panel is closed from elsewhere (teardown,
--- reload), focus is left untouched.
function M.close()
	local state = config.state
	local panel = state.sidepanel
	if not panel then
		return
	end

	if panel.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, panel.augroup)
	end

	local was_focused = panel.win ~= nil and vim.api.nvim_get_current_win() == panel.win

	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		local ok, err = pcall(vim.cmd, "noautocmd call nvim_win_close(" .. panel.win .. ", v:true)")
		if not ok and type(err) == "string" and err:find("Cannot close last window") then
			pcall(vim.cmd, "enew")
		end
	end

	state.sidepanel = nil

	-- Restore focus without noautocmd so BufEnter fires and the plugin's
	-- extmark/keymap/preview state follows the newly-focused window.
	if was_focused and panel.prev_win and vim.api.nvim_win_is_valid(panel.prev_win) then
		pcall(vim.api.nvim_set_current_win, panel.prev_win)
	end
end

-- Resolve optional icons outside the row formatters. Entries are local to render.
local function add_file_icons(file_entries)
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if not ok then
		return nil
	end
	for _, entry in ipairs(file_entries) do
		local name = entry.path:match("[^/]+$") or entry.path
		local success, icon, hl = pcall(devicons.get_icon, name, name:match("%.([^%.]+)$"), { default = true })
		if success and type(icon) == "string" then
			entry.file_icon = icon
			entry.file_icon_hl = type(hl) == "string" and hl or "Normal"
		end
	end
	return "", ""
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
	local width = vim.api.nvim_win_get_width(panel.win)
	panel.rendered_width = width
	local row_opts = {
		viewed_icon = (config.opts.signs and config.opts.signs.viewed) or "✓",
		viewed_hl = (config.opts.signs and config.opts.signs.viewed_hl) or "DiagnosticOk",
		unviewed_icon = (config.opts.signs and config.opts.signs.unviewed) or "○",
		unviewed_hl = (config.opts.signs and config.opts.signs.unviewed_hl) or "Comment",
	}

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
		local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)
		file_entries = files_mod.build_file_entries(
			state.changed_files or {},
			repo_root,
			status_labels,
			state.viewed_files,
			row_opts.viewed_icon,
			comment_counts
		)
		viewed_count = files_mod.count_viewed(state.viewed_files, state.changed_files or {})
	end

	for _, entry in ipairs(file_entries) do
		entry.status_hl = status_highlights[entry.status] or "Comment"
		if (state.viewed_files or {})[entry.path] ~= "VIEWED" then
			entry.viewed_icon = row_opts.unviewed_icon
			entry.viewed_hl = row_opts.unviewed_hl
		end
	end
	if sp_opts.icons ~= false then
		row_opts.directory_icon, row_opts.directory_closed_icon = add_file_icons(file_entries)
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
		tree_entries = tree_mod.flatten_tree(tree, state.viewed_files, panel.collapsed_dirs)
		-- Hidden descendants still determine column widths, so folding does not shift other rows.
		row_opts.all_file_entries = file_entries
		file_lines, file_hls, file_count =
			M.format_files_section_tree(tree_entries, #file_entries, width, viewed_count, current_path, row_opts)
	else
		file_lines, file_hls, file_count =
			M.format_files_section(file_entries, width, config.format_path, viewed_count, current_path, row_opts)
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
			local contains_current = ent.type == "directory"
				and ent.collapsed
				and current_path:sub(1, #ent.path + 1) == ent.path .. "/"
			if (ent.type ~= "directory" and ent.path == current_path) or contains_current then
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

--- Expand a file's ancestors after explicit next/previous-file navigation.
--- Other directory folds and the focused window are left unchanged.
--- @param path string repo-relative file path
function M.reveal_file(path)
	local panel = config.state.sidepanel
	if
		not panel
		or panel.file_tree_mode ~= "tree"
		or not panel.collapsed_dirs
		or not panel.win
		or not vim.api.nvim_win_is_valid(panel.win)
	then
		return
	end
	local changed = false
	for directory in pairs(panel.collapsed_dirs) do
		if path:sub(1, #directory + 1) == directory .. "/" then
			panel.collapsed_dirs[directory] = nil
			changed = true
		end
	end
	if changed then
		M.follow_current_file()
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

	local prev_win = vim.api.nvim_get_current_win()
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
		-- Top-level split: keep the panel at the tabpage edge regardless of
		-- which window is focused (e.g. the right pane of a diff layout).
		win = -1,
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
		collapsed_dirs = {},
		section_map = nil,
		augroup = nil,
		file_tree_mode = sp_opts.file_tree or "flat",
		repo_root = get_diff().get_repo_root(),
		prev_win = prev_win,
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

	vim.api.nvim_create_autocmd("WinResized", {
		group = augroup,
		callback = function()
			-- The event pattern names only the first resized window, not necessarily the panel.
			if
				config.state.sidepanel == panel
				and vim.api.nvim_win_is_valid(win)
				and vim.api.nvim_win_get_width(win) ~= panel.rendered_width
			then
				M.refresh()
			end
		end,
		desc = "fude.nvim: Realign file rows after panel resize",
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

--- Toggle the sidepanel: open it when closed, focus it when open but
--- unfocused, and close it when it is the current window. A panel living
--- in another tabpage is reopened in the current one instead of focused
--- (nvim_set_current_win would otherwise switch tabs).
function M.toggle()
	local panel = config.state.sidepanel
	if panel and panel.win and vim.api.nvim_win_is_valid(panel.win) then
		if vim.api.nvim_win_get_tabpage(panel.win) ~= vim.api.nvim_get_current_tabpage() then
			M.open() -- closes the panel in the other tab, then opens one here
		elseif vim.api.nvim_get_current_win() == panel.win then
			M.close()
		else
			panel.prev_win = vim.api.nvim_get_current_win()
			vim.api.nvim_set_current_win(panel.win)
		end
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

	-- First registration of a key wins: when a user maps an action to a key
	-- that is also another action's default (e.g. select = "j" vs the
	-- next_entry default "j"), the action registered first keeps the key
	-- instead of being silently overwritten. The registration order below is
	-- the priority order documented in doc/fude.txt (`sidepanel.keymaps`), so
	-- keep the two in sync.
	local used_lhs = {}
	local function map(action, callback, desc)
		local lhs = keymaps[action]
		if type(lhs) ~= "string" or lhs == "" or used_lhs[lhs] then
			return
		end
		used_lhs[lhs] = true
		vim.keymap.set("n", lhs, callback, { buffer = buf, desc = desc })
	end

	-- Select / Open
	map("select", function()
		local entry_info = M.get_current_entry(panel)
		if not entry_info then
			return
		end

		if entry_info.type == "scope" then
			if config.state.review_mode == "local" then
				if require("fude.local.session").set_scope(entry_info.entry.local_scope) then
					M.open_first_file()
				end
			else
				get_scope().apply_scope(entry_info.entry, M.open_first_file)
			end
		elseif entry_info.type == "directory" then
			panel.collapsed_dirs[entry_info.entry.path] = not entry_info.entry.collapsed or nil
			M.refresh()
		elseif entry_info.type == "file" then
			local filename = entry_info.entry.filename
			if filename then
				M.open_file(panel, filename, entry_info.entry)
			end
		end
	end, "Select scope, toggle directory, or open file")

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

	-- Refresh (reload from GitHub)
	map("reload", function()
		local init_mod = require("fude.init")
		init_mod.reload()
	end, "Reload review data")

	-- Close
	map("close", function()
		M.close()
	end, "Close side panel")

	-- Entry-wise cursor movement includes directories, which accept `select`.
	-- Headers, separators, and blank lines are skipped.
	map("next_entry", function()
		M.move_to_adjacent_entry(panel, 1, vim.v.count1)
	end, "Move to next selectable entry")
	map("prev_entry", function()
		M.move_to_adjacent_entry(panel, -1, vim.v.count1)
	end, "Move to previous selectable entry")
end

--- Build the sorted 1-based list of panel lines that accept `select`.
--- Includes directory rows; excludes headers, separators, and blank lines.
--- @param section_map table from build_sidepanel_content
--- @return number[] lines ascending 1-based line numbers
function M.build_selectable_lines(section_map)
	local lines = {}
	for line_0 = section_map.scope_start, section_map.scope_end do
		table.insert(lines, line_0 + 1)
	end
	for line_0 = section_map.files_start, section_map.files_end do
		table.insert(lines, line_0 + 1)
	end
	return lines
end

--- Find the selectable line `count` steps from cursor_line in the given
--- direction. Does not wrap: a count past the edge clamps to the last
--- selectable line that way; returns nil when there is nothing further.
--- Index-based (one scan), so a huge count (`9999j`) costs the same as 1.
--- @param cursor_line number 1-based current line
--- @param selectable_lines number[] ascending 1-based lines from build_selectable_lines
--- @param direction number 1 (down) or -1 (up)
--- @param count number|nil steps to move (defaults to 1)
--- @return number|nil line
function M.find_adjacent_selectable_line(cursor_line, selectable_lines, direction, count)
	count = count or 1
	if direction > 0 then
		for i, line in ipairs(selectable_lines) do
			if line > cursor_line then
				return selectable_lines[math.min(i + count - 1, #selectable_lines)]
			end
		end
	else
		for i = #selectable_lines, 1, -1 do
			if selectable_lines[i] < cursor_line then
				return selectable_lines[math.max(i - count + 1, 1)]
			end
		end
	end
	return nil
end

--- Move the panel cursor `count` selectable entries in `direction`.
--- Stops at the edges (no wrap).
--- @param panel table sidepanel state
--- @param direction number 1 (down) or -1 (up)
--- @param count number|nil repeat count (defaults to 1)
function M.move_to_adjacent_entry(panel, direction, count)
	if not panel.section_map or not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
		return
	end
	local selectable = M.build_selectable_lines(panel.section_map)
	local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
	local target = M.find_adjacent_selectable_line(cursor_line, selectable, direction, count)
	if target then
		pcall(vim.api.nvim_win_set_cursor, panel.win, { target, 0 })
	end
end

--- Open a file in a non-panel, non-preview window.
--- @param panel table sidepanel state
--- @param filename string absolute file path
--- @param entry table|nil changed-file entry
function M.open_file(panel, filename, entry)
	local target_win = M.find_target_window(panel.win)
	if not target_win then
		vim.notify("fude.nvim: No source window available", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_set_current_win(target_win)
	get_files().open_file(filename, entry)
end

--- Find the first openable file entry in the Files section (display order).
--- In tree mode the leading entries can be directory rows, so the first
--- non-directory entry's file is returned. Files with status "removed" are
--- skipped — they no longer exist on disk, so opening one would create a
--- phantom empty buffer.
--- @param file_entries table[]|nil flat file entries
--- @param tree_entries table[]|nil tree entries (takes precedence when non-nil)
--- @return table|nil file entry
function M.find_first_file_entry(file_entries, tree_entries)
	if tree_entries then
		for _, entry in ipairs(tree_entries) do
			if entry.type ~= "directory" and entry.file and entry.file.status ~= "removed" then
				return entry.file
			end
		end
		return nil
	end
	for _, entry in ipairs(file_entries or {}) do
		if entry.status ~= "removed" then
			return entry
		end
	end
	return nil
end

--- Open the first file of the Files section (used after a scope switch).
--- Reads the panel from config.state at call time (not a captured table) so a
--- panel closed and reopened while an async scope switch was in flight is
--- still found. Safe to call from async callbacks: no-ops when the session
--- has ended, the panel is gone, the user has moved focus away from the panel
--- while the switch was in flight, or no window is available to open into
--- (the scope switch itself succeeded, so no warning is shown).
function M.open_first_file()
	if not config.state.active then
		return
	end
	local panel = config.state.sidepanel
	if not panel or not panel.win or not vim.api.nvim_win_is_valid(panel.win) then
		return
	end
	-- Staleness guard: auto-open only while the user is still in the panel.
	if vim.api.nvim_get_current_win() ~= panel.win then
		return
	end
	if not M.find_target_window(panel.win) then
		return
	end
	local entry
	if panel.file_tree_mode == "tree" and panel.collapsed_dirs and next(panel.collapsed_dirs) then
		-- Scope selection must still open the first file when every directory is folded.
		entry = M.find_first_file_entry(get_files().build_navigation_order(panel.file_entries, true))
	else
		entry = M.find_first_file_entry(panel.file_entries, panel.tree_entries)
	end
	if entry and entry.filename then
		-- pcall: :edit can fail (e.g. E37 with 'nohidden' + modified buffer);
		-- on the GitHub path this runs inside a gh callback, where an
		-- uncaught error would surface as a bare stack trace.
		local ok, err = pcall(M.open_file, panel, entry.filename, entry)
		if not ok then
			vim.notify("fude.nvim: Could not open " .. entry.filename .. ": " .. tostring(err), vim.log.levels.WARN)
			return
		end
	end
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
	local tab_wins = vim.api.nvim_tabpage_list_wins(0)
	local source_win = state.source_win
	if
		source_win
		and source_win ~= panel_win
		and source_win ~= state.preview_win
		and vim.api.nvim_win_is_valid(source_win)
		and vim.tbl_contains(tab_wins, source_win)
	then
		return source_win
	end

	for _, win in ipairs(tab_wins) do
		if win ~= panel_win and win ~= state.preview_win then
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].buftype == "" then
				return win
			end
		end
	end
	-- Fallback: any window that isn't the panel or preview
	for _, win in ipairs(tab_wins) do
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
