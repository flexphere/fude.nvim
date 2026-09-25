local M = {}
local config = require("fude.config")
local diff = require("fude.diff")

local function absolute_path(filename)
	return vim.fn.fnamemodify(filename, ":p")
end

local function resolved_path(filename)
	return vim.fn.resolve(absolute_path(filename))
end

-- bufnr falls back to pattern matching; a path such as "[a].lua" must not
-- accidentally identify an existing "a.lua" buffer. Prefer an exact path so
-- aliases of the same file cannot hide the buffer the caller intends to open.
local function file_bufnr(filename)
	local path = absolute_path(filename)
	local resolved = vim.fn.resolve(path)
	local fallback = -1
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" then
			local buf_path = absolute_path(name)
			if buf_path == path then
				return buf
			end
			if fallback == -1 and vim.fn.resolve(buf_path) == resolved then
				fallback = buf
			end
		end
	end
	return fallback
end

M.status_icons = {
	added = "+",
	modified = "~",
	removed = "-",
	renamed = "R",
	copied = "C",
}

--- Build the changed-files picker title. GitHub review shows the PR number;
--- local review (no PR) uses a neutral label.
--- @param pr_number number|nil
--- @return string
function M.picker_title(pr_number)
	if pr_number then
		return string.format("PR #%d Changed Files", pr_number)
	end
	return "Local Review: Changed Files"
end

--- Resolve the diff text to preview for a changed-file entry. GitHub review
--- ships the patch with each entry; local review has no patch on the entry
--- (kept out of the reload path for cost), so it is generated on demand here
--- when the entry is actually previewed.
--- @param entry table file entry with .patch and .path
--- @return string patch text ("" when there is nothing to show)
function M.resolve_patch(entry)
	if entry.patch and entry.patch ~= "" then
		return entry.patch
	end
	local state = config.state
	if state.review_mode == "local" and state.local_session then
		local session = state.local_session
		return diff.get_review_patch(session.base_sha, entry.path, session.worktree_root) or ""
	end
	return entry.patch or ""
end

--- Find the first changed position in the first unified-diff hunk.
--- Context lines advance the new-file position; deletions use its surviving
--- boundary (or the header anchor for a zero-context, deletion-only hunk).
--- @param patch string|nil
--- @return number|nil line (may be 0 for a leading deletion)
function M.parse_first_hunk_line(patch)
	if type(patch) ~= "string" then
		return nil
	end
	local new_line
	for line in patch:gmatch("[^\n]+") do
		if new_line == nil then
			local lnum = line:match("^@@%s+%-%d+,?%d*%s+%+(%d+),?%d*%s+@@")
			if lnum then
				new_line = tonumber(lnum)
			end
		else
			local prefix = line:sub(1, 1)
			if prefix == " " then
				new_line = new_line + 1
			elseif prefix == "+" or prefix == "-" then
				return new_line
			elseif prefix ~= "\\" then
				-- Do not read a later hunk or file as part of the first hunk.
				return nil
			end
		end
	end
	return nil
end

--- Center the first change, without making an unavailable patch an open error.
--- @param win number source window
--- @param entry table changed-file entry
function M.center_first_hunk(win, entry)
	local ok, patch = pcall(M.resolve_patch, entry)
	local line = ok and M.parse_first_hunk_line(patch) or nil
	if not line or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, last)), 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zz")
	end)
end

--- Remember a source view before leaving it. Buffer existence, not this
--- cache, determines whether opening a file should center its first hunk.
--- @param buf number buffer being left
function M.save_view(buf)
	local state = config.state
	if not state.active or buf ~= vim.api.nvim_get_current_buf() or vim.bo[buf].buftype ~= "" then
		return
	end
	state.file_views[buf] = {
		view = vim.fn.winsaveview(),
		foldenable = vim.wo.foldenable,
		foldlevel = vim.wo.foldlevel,
	}
end

--- Open a review file, centering its first hunk only for a new buffer.
--- Restore existing buffers' views saved while the review was active.
--- @param filename string absolute file path
--- @param entry table|nil changed-file entry; otherwise resolved in the current scope
function M.open_file(filename, entry)
	local state = config.state
	local win = vim.api.nvim_get_current_win()
	M.save_view(vim.api.nvim_get_current_buf())
	local buf = file_bufnr(filename)
	-- setqflist registers unloaded buffers before any file is actually opened.
	-- Only buffers created by our list have this marker.
	local is_new = buf == -1 or vim.b[buf].fude_quickfix_unopened == true
	if not entry then
		local path = diff.to_repo_relative(filename)
		for _, file in ipairs(state.changed_files) do
			if file.path == path then
				entry = file
				break
			end
		end
	end
	if buf ~= vim.api.nvim_get_current_buf() then
		vim.cmd("edit " .. vim.fn.fnameescape(filename))
	end
	local opened_buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or -1
	local opened_name = opened_buf ~= -1 and vim.api.nvim_buf_get_name(opened_buf) or ""
	if
		config.state ~= state
		or not state.active
		or not vim.api.nvim_win_is_valid(win)
		or vim.api.nvim_get_current_win() ~= win
		or opened_name == ""
		or resolved_path(opened_name) ~= resolved_path(filename)
	then
		return
	end
	local saved = state.file_views[opened_buf] or state.file_views[buf]
	-- Finish an existing preview's rebuild before positioning the source.
	-- Its queued BufEnter callback then sees an up-to-date preview and no-ops.
	if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
		require("fude.preview").on_buf_enter()
	end
	if is_new and entry then
		M.center_first_hunk(vim.api.nvim_get_current_win(), entry)
	elseif saved then
		vim.wo.foldenable = saved.foldenable
		vim.wo.foldlevel = saved.foldlevel
		-- Reopen folds that hid rows which used to be visible. Restoring just
		-- foldlevel cannot recover folds opened individually with zo/zv.
		for _, row in ipairs({ saved.view.lnum, saved.view.topline }) do
			local start = vim.fn.foldclosed(row)
			if start >= 0 and start < row then
				vim.cmd("silent! " .. row .. "foldopen")
			end
		end
		vim.fn.winrestview(saved.view)
	end
end

--- Determine the viewed icon for a file.
--- @param viewed_state string|nil "VIEWED", "UNVIEWED", "DISMISSED", or nil
--- @param viewed_sign string character to show for viewed files
--- @return string icon
--- @return string hl highlight group name
function M.viewed_icon(viewed_state, viewed_sign)
	-- Use configured highlight for viewed files, falling back to the default
	local viewed_hl = (config.opts and config.opts.signs and config.opts.signs.viewed_hl) or "DiagnosticOk"
	if viewed_state == "VIEWED" then
		return viewed_sign, viewed_hl
	end
	return " ", "Comment"
end

--- Build comment count display string.
--- @param submitted number|nil submitted comment count
--- @param pending number|nil pending comment count
--- @param outdated number|nil outdated comment count
--- @return string display text (empty if no comments, "💬N" or "💬N(outdated:M)" otherwise)
--- @return string hl highlight group name
function M.comment_count_display(submitted, pending, outdated)
	submitted = submitted or 0
	pending = pending or 0
	outdated = outdated or 0
	local total = submitted + pending
	if total == 0 then
		return "", "Comment"
	end
	local hl = pending > 0 and "DiagnosticHint" or "DiagnosticInfo"
	if outdated > 0 then
		return string.format("💬%d(outdated:%d)", total, outdated), hl
	end
	return "💬" .. total, hl
end

--- Count files with VIEWED state among changed files.
--- @param viewed_files table<string, string>|nil { [path] = "VIEWED" | "UNVIEWED" | "DISMISSED" }
--- @param changed_files table[] list of { path, ... }
--- @return number
function M.count_viewed(viewed_files, changed_files)
	viewed_files = viewed_files or {}
	local count = 0
	for _, file in ipairs(changed_files) do
		if viewed_files[file.path] == "VIEWED" then
			count = count + 1
		end
	end
	return count
end

--- Build normalized file entries from changed files list.
--- @param changed_files table[] list of { path, status, additions, deletions, patch }
--- @param repo_root string repository root directory
--- @param icons table status-to-icon map
--- @param viewed_files table<string, string>|nil path-to-viewed-state map
--- @param viewed_sign string|nil character for viewed indicator
--- @param comment_counts table<string, { submitted: number, pending: number, outdated: number }>|nil counts
--- @return table[] entries
function M.build_file_entries(changed_files, repo_root, icons, viewed_files, viewed_sign, comment_counts)
	viewed_files = viewed_files or {}
	viewed_sign = viewed_sign or "✓"
	comment_counts = comment_counts or {}
	local entries = {}
	for _, file in ipairs(changed_files) do
		local v_icon, v_hl = M.viewed_icon(viewed_files[file.path], viewed_sign)
		local counts = comment_counts[file.path] or {}
		local submitted = tonumber(counts.submitted) or 0
		local pending = tonumber(counts.pending) or 0
		local outdated = tonumber(counts.outdated) or 0
		local c_display, c_hl = M.comment_count_display(submitted, pending, outdated)
		table.insert(entries, {
			path = file.path,
			filename = repo_root .. "/" .. file.path,
			patch = file.patch or "",
			status = file.status,
			status_icon = icons[file.status] or "?",
			status_hl = file.status == "added" and "DiffAdd" or file.status == "removed" and "DiffDelete" or "DiffChange",
			additions = file.additions or 0,
			deletions = file.deletions or 0,
			viewed_icon = v_icon,
			viewed_hl = v_hl,
			comment_count = submitted + pending,
			comment_display = c_display,
			comment_hl = c_hl,
		})
	end
	return entries
end

--- Build the ordered file list used for next/prev navigation.
--- In flat mode the changed_files order is used as-is. In tree mode the order
--- is made to match the sidepanel's tree rendering (directories then files, each
--- sorted alphabetically, depth-first) so navigation follows what is displayed.
--- @param changed_files table[] list of { path, ... }
--- @param tree_mode boolean whether to use the sidepanel tree order
--- @return table[] ordered list of file entries (each has .path)
function M.build_navigation_order(changed_files, tree_mode)
	if not tree_mode then
		return changed_files
	end
	local tree_mod = require("fude.ui.sidepanel.tree")
	local tree = tree_mod.build_tree(changed_files)
	tree_mod.collapse_singleton_chains(tree)
	local entries = tree_mod.flatten_tree(tree)
	local ordered = {}
	for _, entry in ipairs(entries) do
		if entry.type == "file" then
			table.insert(ordered, entry.file or { path = entry.path })
		end
	end
	return ordered
end

--- Index of `path` in a navigation-ordered file list, or nil when it is absent
--- (including when there is no current path at all).
--- @param files table[] list of { path, ... }
--- @param path string|nil repo-relative path
--- @return number|nil
local function index_of_path(files, path)
	if not path then
		return nil
	end
	for i, file in ipairs(files) do
		if file.path == path then
			return i
		end
	end
	return nil
end

--- Find the index of the next/prev changed file relative to the current path.
--- Wraps around at the edges. If the current path is not in the list, returns
--- the first entry for "next" and the last for "prev".
--- @param changed_files table[] list of { path, ... }
--- @param current_path string|nil repo-relative path of the current buffer (nil if not in repo)
--- @param direction "next"|"prev"
--- @return number|nil index 1-based index into changed_files, or nil if list is empty
function M.find_adjacent_file_index(changed_files, current_path, direction)
	local total = #changed_files
	if total == 0 then
		return nil
	end

	local current_idx = index_of_path(changed_files, current_path)

	if not current_idx then
		return direction == "prev" and total or 1
	end

	if direction == "next" then
		return (current_idx % total) + 1
	end
	return ((current_idx - 2) % total) + 1
end

--- Whether a changed file is a target for unviewed navigation: not marked as viewed,
--- and still present in the working tree. Files deleted by the PR are excluded because
--- they cannot be opened (`:edit` would create an empty buffer for a path that no
--- longer exists), matching how `ui/sidepanel.find_first_file_entry` skips them. They
--- would otherwise be hit on every wrap-around, since a deleted file is rarely viewed.
--- @param file table { path, status, ... }
--- @param viewed_files table<string, string> { [path] = "VIEWED" | "UNVIEWED" | "DISMISSED" }
--- @return boolean
local function is_unviewed_target(file, viewed_files)
	return file.status ~= "removed" and viewed_files[file.path] ~= "VIEWED"
end

--- Whether any changed file is a target for unviewed navigation. Callers use this to
--- bail out before moving the cursor or switching windows.
--- @param changed_files table[] list of { path, status, ... }
--- @param viewed_files table<string, string>|nil
--- @return boolean
function M.has_unviewed_target(changed_files, viewed_files)
	viewed_files = viewed_files or {}
	for _, file in ipairs(changed_files) do
		if is_unviewed_target(file, viewed_files) then
			return true
		end
	end
	return false
end

--- Find the index of the next/prev *unviewed* changed file relative to the current
--- path. Walks the navigation order in `direction` and returns the first entry that
--- `is_unviewed_target` accepts, wrapping around at the edges. The current file is
--- reached last, so it is returned only when it is the sole unviewed file. Returns nil
--- when the list is empty or holds no unviewed target.
--- @param files table[] navigation-ordered list of { path, status, ... }
--- @param current_path string|nil repo-relative path of the current buffer (nil if not in repo)
--- @param direction "next"|"prev"
--- @param viewed_files table<string, string>|nil { [path] = "VIEWED" | "UNVIEWED" | "DISMISSED" }
--- @return number|nil index 1-based index into files, or nil when there is nowhere to go
function M.find_adjacent_unviewed_index(files, current_path, direction, viewed_files)
	local total = #files
	if total == 0 then
		return nil
	end
	viewed_files = viewed_files or {}

	local current_idx = index_of_path(files, current_path)

	-- With no current file, start just outside the list so the first step lands on
	-- the first entry for "next" and the last one for "prev".
	local start = current_idx or (direction == "next" and 0 or total + 1)
	local step = direction == "next" and 1 or -1
	for i = 1, total do
		local idx = ((start - 1 + step * i) % total) + 1
		if is_unviewed_target(files[idx], viewed_files) then
			return idx
		end
	end
	return nil
end

--- Move to the next/prev changed file in the PR.
--- @param direction "next"|"prev"
--- @param unviewed_only boolean|nil skip files already marked as viewed
local function goto_adjacent(direction, unviewed_only)
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if #state.changed_files == 0 then
		vim.notify("fude.nvim: No changed files loaded", vim.log.levels.INFO)
		return
	end

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	-- Checked before the window switch below: bailing out afterwards would drag the
	-- user out of the side panel only to report that there is nowhere to go.
	if unviewed_only and not M.has_unviewed_target(state.changed_files, state.viewed_files) then
		vim.notify("fude.nvim: No unviewed files", vim.log.levels.INFO)
		return
	end

	local panel = state.sidepanel
	if panel and panel.win == vim.api.nvim_get_current_win() then
		local target_win = require("fude.ui.sidepanel").find_target_window(panel.win)
		if not target_win then
			vim.notify("fude.nvim: No source window available", vim.log.levels.WARN)
			return
		end
		vim.api.nvim_set_current_win(target_win)
	end

	local tree_mode = ((panel and panel.file_tree_mode) or config.opts.sidepanel.file_tree) == "tree"
	local nav_files = M.build_navigation_order(state.changed_files, tree_mode)

	local current_path = diff.make_relative(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p"), repo_root)
	local idx
	if unviewed_only then
		-- has_unviewed_target above already ruled out the nil case; the guard below
		-- keeps the notification in one place rather than reporting it twice.
		idx = M.find_adjacent_unviewed_index(nav_files, current_path, direction, state.viewed_files)
	else
		idx = M.find_adjacent_file_index(nav_files, current_path, direction)
	end
	if not idx then
		return
	end

	local target = nav_files[idx]
	M.open_file(repo_root .. "/" .. target.path, target)
	if config.state == state and state.active then
		require("fude.ui.sidepanel").reveal_file(target.path)
	end
end

--- Open the first openable changed file in navigation order (used after a scope
--- switch). Leaves the side panel, the diff preview, a floating window, or a
--- special buffer for a source window first. Removed files are skipped, as in
--- `ui/sidepanel.open_first_file`.
function M.open_first_file()
	local state = config.state
	if not state.active then
		return
	end
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local sidepanel = require("fude.ui.sidepanel")
	local panel = state.sidepanel
	local tree_mode = ((panel and panel.file_tree_mode) or config.opts.sidepanel.file_tree) == "tree"
	local target = sidepanel.find_first_file_entry(M.build_navigation_order(state.changed_files, tree_mode))
	if not target then
		return
	end

	-- The switch can be triggered from a float (comment viewer etc.) or a special
	-- buffer (quickfix, help); :edit there would replace that UI with the file.
	local current_win = vim.api.nvim_get_current_win()
	local panel_win = panel and panel.win
	if
		current_win == panel_win
		or current_win == state.preview_win
		or vim.api.nvim_win_get_config(current_win).relative ~= ""
		or vim.bo[vim.api.nvim_win_get_buf(current_win)].buftype ~= ""
	then
		local target_win = sidepanel.find_target_window(panel_win)
		if not target_win then
			return
		end
		vim.api.nvim_set_current_win(target_win)
	end

	-- pcall: this runs inside a gh callback, where an :edit failure (e.g. E37)
	-- would otherwise surface as a bare stack trace.
	local ok, err = pcall(M.open_file, repo_root .. "/" .. target.path, target)
	if not ok then
		vim.notify("fude.nvim: Could not open " .. target.path .. ": " .. tostring(err), vim.log.levels.WARN)
		return
	end
	if config.state == state and state.active then
		sidepanel.reveal_file(target.path)
	end
end

--- Move to the next changed file in the PR (wraps around).
function M.next_file()
	goto_adjacent("next")
end

--- Move to the previous changed file in the PR (wraps around).
function M.prev_file()
	goto_adjacent("prev")
end

--- Move to the next changed file not yet marked as viewed (wraps around).
function M.next_unviewed_file()
	goto_adjacent("next", true)
end

--- Move to the previous changed file not yet marked as viewed (wraps around).
function M.prev_unviewed_file()
	goto_adjacent("prev", true)
end

--- Show changed files list using the configured mode.
function M.show()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if #state.changed_files == 0 then
		vim.notify("fude.nvim: No changed files loaded", vim.log.levels.INFO)
		return
	end

	if config.opts.file_list_mode == "quickfix" then
		M.show_quickfix()
	elseif config.opts.file_list_mode == "snacks" then
		M.show_snacks()
	else
		M.show_telescope()
	end
end

--- Show changed files in a Telescope picker.
function M.show_telescope()
	local state = config.state
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim not found, falling back to quickfix", vim.log.levels.WARN)
		M.show_quickfix()
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local previewers = require("telescope.previewers")
	local ui = require("fude.ui")
	local comments_data = require("fude.comments.data")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local viewed_sign = config.opts.signs.viewed or "✓"
	local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 2 },
			{ width = 2 },
			{ width = 5 },
			{ width = 5 },
			{ width = 18 },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		return displayer({
			{ entry.viewed_icon, entry.viewed_hl },
			{ entry.status_icon, entry.status_hl },
			{ "+" .. entry.additions, "DiffAdd" },
			{ "-" .. entry.deletions, "DiffDelete" },
			{ entry.comment_display, entry.comment_hl },
			entry.value,
		})
	end

	local raw_entries = M.build_file_entries(
		state.changed_files,
		repo_root,
		M.status_icons,
		state.viewed_files,
		viewed_sign,
		comment_counts
	)
	local format_path = config.format_path
	local entries = {}
	for _, entry in ipairs(raw_entries) do
		entry.value = format_path(entry.path)
		entry.ordinal = entry.path
		entry.display = make_display
		table.insert(entries, entry)
	end

	local function create_picker(initial_entries)
		return pickers.new({}, {
			prompt_title = M.picker_title(state.pr_number),
			finder = finders.new_table({
				results = initial_entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Diff",
				get_buffer_by_name = function(_, entry)
					return entry.path
				end,
				define_preview = function(self, entry)
					ui.sync_preview_buffer(self)

					local patch = M.resolve_patch(entry)
					if patch == "" then
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "(no diff)" })
						return
					end
					local lines = vim.split(patch, "\n", { trimempty = false })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "diff"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						M.open_file(selection.filename, selection)
					end
				end)

				map("i", "<Tab>", function()
					M.toggle_viewed_in_telescope(prompt_bufnr)
				end)
				map("n", "<Tab>", function()
					M.toggle_viewed_in_telescope(prompt_bufnr)
				end)

				return true
			end,
		})
	end

	create_picker(entries):find()
end

--- Show changed files in a snacks.picker.
function M.show_snacks()
	local state = config.state
	local has_snacks, snacks_picker = pcall(require, "snacks.picker")
	if not has_snacks then
		vim.notify("fude.nvim: snacks.nvim not found, falling back to quickfix", vim.log.levels.WARN)
		M.show_quickfix()
		return
	end

	local comments_data = require("fude.comments.data")
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local viewed_sign = config.opts.signs.viewed or "✓"
	local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)
	local format_path = config.format_path

	local raw_entries = M.build_file_entries(
		state.changed_files,
		repo_root,
		M.status_icons,
		state.viewed_files,
		viewed_sign,
		comment_counts
	)
	for _, entry in ipairs(raw_entries) do
		entry.text = format_path(entry.path)
	end

	snacks_picker.pick({
		source = "fude_changed_files",
		title = M.picker_title(state.pr_number),
		items = raw_entries,
		format = function(item, _)
			return {
				{ item.viewed_icon .. " ", item.viewed_hl },
				{ item.status_icon .. " ", item.status_hl },
				{ "+" .. item.additions .. " ", "DiffAdd" },
				{ "-" .. item.deletions .. " ", "DiffDelete" },
				{ (item.comment_display ~= "" and (item.comment_display .. " ") or ""), item.comment_hl },
				{ item.text },
			}
		end,
		preview = function(ctx)
			local item = ctx.item
			if not item then
				return
			end
			ctx.preview:reset()
			ctx.preview:minimal()
			local patch = M.resolve_patch(item)
			if patch == "" then
				ctx.preview:set_lines({ "(no diff)" })
				return
			end
			local lines = vim.split(patch, "\n", { trimempty = false })
			ctx.preview:set_lines(lines)
			ctx.preview:highlight({ ft = "diff" })
		end,
		confirm = function(picker, item)
			picker:close()
			if item then
				M.open_file(item.filename, item)
			end
		end,
		actions = {
			toggle_viewed = function(picker, item)
				M.toggle_viewed_in_snacks(picker, item)
			end,
		},
		win = {
			input = {
				keys = {
					["<Tab>"] = { "toggle_viewed", mode = { "i", "n" } },
				},
			},
			list = {
				keys = {
					["<Tab>"] = "toggle_viewed",
				},
			},
		},
	})
end

--- Snacks adapter for the viewed-state toggle.
--- Delegates state mutation to apply_viewed_toggle, then updates the current
--- item's display fields and refreshes the picker via picker:refresh() which
--- preserves cursor position (picker:find() alone resets selection to top).
--- @param picker snacks.Picker
--- @param item table|nil current picker item
function M.toggle_viewed_in_snacks(picker, item)
	if not item then
		return
	end

	M.apply_viewed_toggle(item.path, function(updated)
		item.viewed_icon = updated.viewed_icon
		item.viewed_hl = updated.viewed_hl
		if picker and picker.refresh then
			pcall(picker.refresh, picker)
		end
	end)
end

--- Toggle the viewed state for a file via GitHub GraphQL API.
--- Picker-agnostic core mutator. Updates state.viewed_files on success, then
--- invokes on_done with the updated display fields. If gh returns an error,
--- notifies and does NOT invoke on_done.
--- @param path string repo-relative file path
--- @param on_done fun(updated: { path: string, viewed_state: string, viewed_icon: string, viewed_hl: string })
function M.apply_viewed_toggle(path, on_done)
	local state = config.state
	local viewed_sign = config.opts.signs.viewed or "✓"
	local current_state = state.viewed_files[path]
	local new_state = (current_state == "VIEWED") and "UNVIEWED" or "VIEWED"

	local function finish()
		local v_icon, v_hl = M.viewed_icon(new_state, viewed_sign)
		on_done({
			path = path,
			viewed_state = new_state,
			viewed_icon = v_icon,
			viewed_hl = v_hl,
		})
	end

	-- Local review: persist to the JSONL store (no GitHub round-trip).
	if state.review_mode == "local" then
		require("fude.comments.local_sync").set_viewed(path, new_state == "VIEWED", function(err)
			if err then
				vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
				return
			end
			finish()
		end)
		return
	end

	if not state.pr_node_id then
		vim.notify("fude.nvim: PR node ID not available", vim.log.levels.WARN)
		return
	end

	local gh_mod = require("fude.gh")
	local toggle_fn = (current_state == "VIEWED") and gh_mod.unmark_file_viewed or gh_mod.mark_file_viewed

	toggle_fn(state.pr_node_id, path, function(err)
		if err then
			vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[path] = new_state
		finish()
	end)
end

--- Telescope adapter for the viewed-state toggle.
--- Reads the current selection, delegates state mutation to apply_viewed_toggle,
--- then applies the returned display fields to the entry and refreshes the
--- picker while preserving the selected row.
--- @param prompt_bufnr number
function M.toggle_viewed_in_telescope(prompt_bufnr)
	local action_state = require("telescope.actions.state")
	local selection = action_state.get_selected_entry()
	if not selection then
		return
	end

	local function refresh_picker_preserving_selection()
		local picker = action_state.get_current_picker(prompt_bufnr)
		if picker then
			local row = picker:get_selection_row()
			picker:refresh(nil, { reset_prompt = false })
			-- Delay to ensure picker:refresh() internal rendering completes before restoring selection
			vim.defer_fn(function()
				pcall(picker.set_selection, picker, row)
			end, 10)
		end
	end

	M.apply_viewed_toggle(selection.path, function(updated)
		selection.viewed_icon = updated.viewed_icon
		selection.viewed_hl = updated.viewed_hl
		refresh_picker_preserving_selection()
	end)
end

--- Install a file-list Enter action without losing an existing quickfix mapping.
local function setup_quickfix_keymap(buf)
	local previous = vim.fn.maparg("<CR>", "n", false, true)
	if previous.desc == "Open review file" then
		return
	end
	local opts = { buffer = buf, desc = "Open review file" }
	local function open_entry()
		local list = vim.fn.getqflist({ context = 0, items = 0 })
		if not config.state.active or type(list.context) ~= "table" or not list.context.fude_files then
			-- Let Neovim run the original mapping (including expr/script-local
			-- mappings), or its built-in action, for every other list.
			vim.keymap.del("n", "<CR>", { buffer = buf })
			if previous.buffer == 1 then
				vim.fn.mapset("n", false, previous)
			end
			local enter = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
			local ok, err = pcall(vim.cmd, "normal " .. enter)
			if vim.api.nvim_buf_is_valid(buf) then
				vim.keymap.set("n", "<CR>", open_entry, opts)
			end
			if not ok then
				error(err)
			end
			return
		end
		local index = vim.api.nvim_win_get_cursor(0)[1]
		local item = list.items[index]
		if not item or not vim.api.nvim_buf_is_valid(item.bufnr) then
			return
		end
		local win = require("fude.ui.sidepanel").find_target_window(vim.api.nvim_get_current_win())
		if not win then
			return
		end
		local filename = vim.api.nvim_buf_get_name(item.bufnr)
		vim.fn.setqflist({}, "a", { idx = index })
		vim.api.nvim_set_current_win(win)
		M.open_file(filename)
	end
	vim.keymap.set("n", "<CR>", open_entry, opts)
end

--- Show changed files in the quickfix list.
function M.show_quickfix()
	local state = config.state
	local comments_data = require("fude.comments.data")
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local viewed_sign = config.opts.signs.viewed or "✓"
	local comment_counts = comments_data.build_file_comment_counts(state.comments, state.pending_comments)
	local raw_entries = M.build_file_entries(
		state.changed_files,
		repo_root,
		M.status_icons,
		state.viewed_files,
		viewed_sign,
		comment_counts
	)
	local format_path = config.format_path
	local items = {}
	local new_files = {}
	for _, entry in ipairs(raw_entries) do
		if file_bufnr(entry.filename) == -1 then
			table.insert(new_files, entry.filename)
		end
		local comment_part = entry.comment_display ~= "" and (" " .. entry.comment_display) or ""
		table.insert(items, {
			filename = entry.filename,
			lnum = 0,
			text = string.format(
				"[%s] [%s] +%d -%d%s  %s",
				entry.viewed_icon,
				entry.status_icon,
				entry.additions,
				entry.deletions,
				comment_part,
				format_path(entry.path)
			),
		})
	end

	vim.fn.setqflist({}, " ", {
		title = M.picker_title(state.pr_number),
		items = items,
		context = { fude_files = true },
	})
	for _, filename in ipairs(new_files) do
		local buf = file_bufnr(filename)
		if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
			vim.b[buf].fude_quickfix_unopened = true
			-- Any real read, including one outside fude, consumes the marker.
			-- Buffer-local autocmds are also removed when the buffer is wiped.
			vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
				buffer = buf,
				once = true,
				callback = function()
					vim.b[buf].fude_quickfix_unopened = nil
				end,
			})
		end
	end
	vim.cmd("copen")
	setup_quickfix_keymap(vim.api.nvim_get_current_buf())
end

return M
