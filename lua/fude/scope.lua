local M = {}
local config = require("fude.config")

--- Determine the reviewed icon for a commit.
--- @param reviewed boolean whether the commit is reviewed
--- @return string icon
--- @return string hl highlight group name
function M.reviewed_icon(reviewed)
	if reviewed then
		local reviewed_hl = (config.opts and config.opts.signs and config.opts.signs.viewed_hl) or "DiagnosticOk"
		local reviewed_sign = (config.opts and config.opts.signs and config.opts.signs.viewed) or "✓"
		return reviewed_sign, reviewed_hl
	end
	return " ", "Comment"
end

--- Build scope selection entries for the picker.
--- First entry is always "Full PR", followed by commit entries in input order.
--- @param commit_entries table[] normalized commit entries from gh.parse_commit_entries
--- @param base_ref string base branch name
--- @param head_ref string head branch name
--- @param reviewed_commits table<string, boolean>|nil { [sha] = true } reviewed commit map
--- @param current_scope string|nil "full_pr" or "commit"
--- @param current_scope_sha string|nil SHA of the currently selected commit scope
--- @return table[] entries scope entry objects with index, total, and is_current fields
function M.build_scope_entries(commit_entries, base_ref, head_ref, reviewed_commits, current_scope, current_scope_sha)
	reviewed_commits = reviewed_commits or {}
	local total = #commit_entries
	local entries = {}
	table.insert(entries, {
		value = "full_pr",
		display_text = string.format("PR全体 (%s...%s)", base_ref, head_ref),
		sha = nil,
		is_full_pr = true,
		reviewed = false,
		reviewed_icon = " ",
		reviewed_hl = "Comment",
		index = nil,
		total = total,
		is_current = current_scope == "full_pr" or current_scope == nil,
	})
	for i, c in ipairs(commit_entries) do
		local is_reviewed = false
		if c.sha ~= nil then
			is_reviewed = reviewed_commits[c.sha] == true
		end
		local r_icon, r_hl = M.reviewed_icon(is_reviewed)
		local is_current = current_scope == "commit" and current_scope_sha ~= nil and c.sha == current_scope_sha
		table.insert(entries, {
			value = c.sha,
			display_text = string.format("[%d/%d] %s %s (%s)", i, total, c.short_sha, c.message, c.author_name),
			sha = c.sha,
			is_full_pr = false,
			reviewed = is_reviewed,
			reviewed_icon = r_icon,
			reviewed_hl = r_hl,
			index = i,
			total = total,
			is_current = is_current,
		})
	end
	return entries
end

--- Show the scope selection picker.
function M.select_scope()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local commit_entries
	if #state.pr_commits == 0 then
		vim.notify("fude.nvim: No commits loaded; only full PR scope is available", vim.log.levels.WARN)
		commit_entries = {}
	else
		local gh_mod = require("fude.gh")
		commit_entries = gh_mod.parse_commit_entries(state.pr_commits)
	end

	local scope_entries = M.build_scope_entries(
		commit_entries,
		state.base_ref,
		state.head_ref,
		state.reviewed_commits,
		state.scope,
		state.scope_commit_sha
	)

	if config.opts.file_list_mode == "telescope" then
		M.show_telescope(scope_entries)
	else
		M.show_vim_select(scope_entries)
	end
end

--- Show scope selection in a Telescope picker.
--- @param scope_entries table[] entries from build_scope_entries
function M.show_telescope(scope_entries)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(scope_entries)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local previewers = require("telescope.previewers")

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 2 },
			{ width = 2 },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		local current_icon = entry.is_current and "▶" or " "
		local current_hl = entry.is_current and "DiagnosticInfo" or "Comment"
		return displayer({
			{ current_icon, current_hl },
			{ entry.reviewed_icon, entry.reviewed_hl },
			entry.display_text,
		})
	end

	local entries = {}
	for _, entry in ipairs(scope_entries) do
		entry.display = make_display
		entry.ordinal = entry.display_text
		table.insert(entries, entry)
	end

	local state = config.state
	local files_mod = require("fude.files")
	local gh_mod = require("fude.gh")
	local preview_cache = {}
	local inflight = {}
	local preview_ns = vim.api.nvim_create_namespace("fude_scope_preview")

	pickers
		.new({}, {
			prompt_title = "Review Scope",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Changed Files",
				define_preview = function(self, entry)
					local bufnr = self.state.bufnr

					local function apply_preview(files)
						if not vim.api.nvim_buf_is_valid(bufnr) then
							return
						end
						local lines, hls = M.format_scope_preview_lines(files, files_mod.status_icons, config.format_path)
						vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
						vim.api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
						for _, hl in ipairs(hls) do
							vim.api.nvim_buf_add_highlight(bufnr, preview_ns, hl[4], hl[1], hl[2], hl[3])
						end
					end

					if entry.is_full_pr then
						self.state.current_sha = nil
						local files = {}
						for _, f in ipairs(state.changed_files) do
							table.insert(files, {
								filename = f.path,
								status = f.status,
								additions = f.additions,
								deletions = f.deletions,
							})
						end
						apply_preview(files)
						return
					end

					local sha = entry.sha
					if not sha then
						return
					end

					self.state.current_sha = sha

					if preview_cache[sha] then
						apply_preview(preview_cache[sha])
						return
					end

					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })
					vim.api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)

					if inflight[sha] then
						return
					end
					inflight[sha] = true

					gh_mod.get_commit_files(sha, function(err, raw_files)
						inflight[sha] = nil
						if err then
							if vim.api.nvim_buf_is_valid(bufnr) and self.state.current_sha == sha then
								vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Error: " .. err })
							end
							return
						end
						local files = {}
						for _, f in ipairs(raw_files or {}) do
							table.insert(files, {
								filename = f.filename,
								status = f.status,
								additions = f.additions,
								deletions = f.deletions,
							})
						end
						preview_cache[sha] = files
						if self.state.current_sha == sha then
							apply_preview(files)
						end
					end)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						M.apply_scope(selection)
					end
				end)

				map("i", "<Tab>", function()
					M.toggle_reviewed_in_picker(prompt_bufnr)
				end)
				map("n", "<Tab>", function()
					M.toggle_reviewed_in_picker(prompt_bufnr)
				end)

				return true
			end,
		})
		:find()
end

--- Toggle reviewed state for the selected commit in the Telescope picker.
--- @param prompt_bufnr number
function M.toggle_reviewed_in_picker(prompt_bufnr)
	local action_state = require("telescope.actions.state")
	local selection = action_state.get_selected_entry()
	if not selection or selection.is_full_pr then
		return
	end

	local sha = selection.sha
	if not sha then
		return
	end

	local state = config.state
	if state.reviewed_commits[sha] then
		state.reviewed_commits[sha] = nil
	else
		state.reviewed_commits[sha] = true
	end

	local is_reviewed = state.reviewed_commits[sha] == true
	local r_icon, r_hl = M.reviewed_icon(is_reviewed)
	selection.reviewed = is_reviewed
	selection.reviewed_icon = r_icon
	selection.reviewed_hl = r_hl

	local picker = action_state.get_current_picker(prompt_bufnr)
	if picker then
		picker:refresh(nil, { reset_prompt = false })
	end
end

--- Show scope selection using vim.ui.select.
--- @param scope_entries table[] entries from build_scope_entries
function M.show_vim_select(scope_entries)
	vim.ui.select(scope_entries, {
		prompt = "Review Scope:",
		format_item = function(entry)
			local current = entry.is_current and "▶" or " "
			return current .. " " .. entry.reviewed_icon .. " " .. entry.display_text
		end,
	}, function(choice)
		if choice then
			M.apply_scope(choice)
		end
	end)
end

--- Apply the selected scope.
--- @param entry table scope entry with { sha, is_full_pr }
function M.apply_scope(entry)
	if entry.is_full_pr then
		M.apply_full_pr_scope()
	else
		M.apply_commit_scope(entry.sha)
	end
end

--- Apply full PR scope (restore to original HEAD).
function M.apply_full_pr_scope()
	local state = config.state
	if state.scope == "full_pr" then
		vim.notify("fude.nvim: Already reviewing full PR", vim.log.levels.INFO)
		return
	end

	-- Restore original HEAD (prefer branch name to avoid detached HEAD)
	local checkout_target = state.original_head_ref or state.original_head_sha
	if checkout_target then
		local result = vim.system({ "git", "checkout", checkout_target }, { text = true }):wait()
		if result.code ~= 0 then
			vim.notify("fude.nvim: Failed to restore HEAD: " .. (result.stderr or ""), vim.log.levels.ERROR)
			return
		end
	end

	-- Refetch PR files (update state only on success)
	local previous_scope_sha = state.scope_commit_sha
	local gh_mod = require("fude.gh")
	gh_mod.get_pr_files(state.pr_number, function(err, files)
		if err then
			vim.notify("fude.nvim: Failed to fetch PR files: " .. err, vim.log.levels.ERROR)
			-- Rollback: restore previous commit checkout
			if previous_scope_sha then
				vim.system({ "git", "checkout", previous_scope_sha }, { text = true }):wait()
			end
			return
		end

		state.scope = "full_pr"
		state.scope_commit_sha = nil
		state.scope_commit_index = nil
		state.changed_files = {}
		for _, f in ipairs(files) do
			table.insert(state.changed_files, {
				path = f.filename,
				status = f.status,
				additions = f.additions,
				deletions = f.deletions,
				patch = f.patch,
			})
		end

		-- Reset global gitsigns base (clearing commit scope base)
		-- Then compute merge_base_sha and apply per-buffer base
		local has_gitsigns, gitsigns = pcall(require, "gitsigns")
		if has_gitsigns then
			gitsigns.reset_base(true)
		end

		local init_mod = require("fude.init")
		init_mod.compute_merge_base(state.base_ref)

		-- Apply per-buffer base to all loaded buffers
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
				init_mod.apply_gitsigns_base_for_buffer(bufnr)
			end
		end

		-- Refresh preview if open
		M.refresh_preview()

		vim.notify(
			string.format("fude.nvim: Scope → PR全体 (%s...%s)", state.base_ref, state.head_ref),
			vim.log.levels.INFO
		)
	end)
end

--- Apply commit scope (checkout specific commit).
--- @param sha string commit SHA
function M.apply_commit_scope(sha)
	local state = config.state

	-- Save original HEAD if not yet saved
	if not state.original_head_sha then
		local result = vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait()
		if result.code == 0 then
			state.original_head_sha = vim.trim(result.stdout)
		end
	end

	-- Check for uncommitted changes
	local status_result = vim.system({ "git", "status", "--porcelain" }, { text = true }):wait()
	if status_result.code ~= 0 then
		vim.notify("fude.nvim: Failed to check git status: " .. (status_result.stderr or ""), vim.log.levels.ERROR)
		return
	end
	if status_result.stdout ~= "" then
		vim.notify(
			"fude.nvim: Uncommitted changes detected. Please commit or stash before switching scope.",
			vim.log.levels.ERROR
		)
		return
	end

	-- Checkout the commit
	local previous_scope = state.scope
	local previous_scope_sha = state.scope_commit_sha
	local result = vim.system({ "git", "checkout", sha }, { text = true }):wait()
	if result.code ~= 0 then
		vim.notify("fude.nvim: Failed to checkout commit: " .. (result.stderr or ""), vim.log.levels.ERROR)
		return
	end

	-- Fetch commit files (update state only on success)
	local gh_mod = require("fude.gh")
	gh_mod.get_commit_files(sha, function(err, files)
		if err then
			vim.notify("fude.nvim: Failed to fetch commit files: " .. err, vim.log.levels.ERROR)
			-- Rollback: restore previous checkout
			local rollback_target = state.original_head_ref or state.original_head_sha
			if previous_scope == "commit" and previous_scope_sha then
				rollback_target = previous_scope_sha
			end
			if rollback_target then
				vim.system({ "git", "checkout", rollback_target }, { text = true }):wait()
			end
			return
		end

		state.scope = "commit"
		state.scope_commit_sha = sha
		state.scope_commit_index = M.find_commit_index(state.pr_commits, sha)
		state.changed_files = {}
		for _, f in ipairs(files) do
			table.insert(state.changed_files, {
				path = f.filename,
				status = f.status,
				additions = f.additions,
				deletions = f.deletions,
				patch = f.patch,
			})
		end

		-- Update gitsigns base to parent commit
		local has_gitsigns, gitsigns = pcall(require, "gitsigns")
		if has_gitsigns then
			gitsigns.change_base(sha .. "^", true)
		end

		-- Refresh preview if open
		M.refresh_preview()

		local short_sha = sha:sub(1, 7)
		vim.notify(string.format("fude.nvim: Scope → commit %s", short_sha), vim.log.levels.INFO)
	end)
end

--- Find the 1-based index of a commit SHA in raw pr_commits.
--- @param pr_commits table[] raw commit objects from GitHub API
--- @param sha string commit SHA to find
--- @return number|nil index 1-based index, nil if not found
function M.find_commit_index(pr_commits, sha)
	for i, c in ipairs(pr_commits) do
		if c.sha == sha then
			return i
		end
	end
	return nil
end

--- Format the scope label for statusline display.
--- @param scope string "full_pr" or "commit"
--- @param scope_commit_index number|nil 1-based index of current commit
--- @param total_commits number total number of PR commits
--- @return string label e.g. "Scope: PR" or "Scope: 3/10"
function M.format_scope_label(scope, scope_commit_index, total_commits)
	if scope == "commit" and scope_commit_index then
		return string.format("Scope: %d/%d", scope_commit_index, total_commits)
	end
	return "Scope: PR"
end

--- Find the next scope index (wraps around).
--- Index 0 = Full PR, 1..total = commits.
--- @param current_scope string "full_pr" or "commit"
--- @param current_index number|nil current commit index (1-based)
--- @param total number total number of commits
--- @return number next_index 0 for full_pr, 1..total for commits
function M.find_next_scope_index(current_scope, current_index, total)
	if total == 0 then
		return 0
	end
	if current_scope == "full_pr" then
		return 1
	end
	local idx = current_index or 0
	if idx >= total then
		return 0
	end
	return idx + 1
end

--- Find the previous scope index (wraps around).
--- Index 0 = Full PR, 1..total = commits.
--- @param current_scope string "full_pr" or "commit"
--- @param current_index number|nil current commit index (1-based)
--- @param total number total number of commits
--- @return number prev_index 0 for full_pr, 1..total for commits
function M.find_prev_scope_index(current_scope, current_index, total)
	if total == 0 then
		return 0
	end
	if current_scope == "full_pr" then
		return total
	end
	local idx = current_index or 0
	if idx <= 1 then
		return 0
	end
	return idx - 1
end

--- Get the statusline label for the current scope.
--- @return string label e.g. "Scope: PR" or "Scope: 3/10"
function M.statusline()
	local state = config.state
	if not state.active then
		return ""
	end
	local total = #state.pr_commits
	return M.format_scope_label(state.scope, state.scope_commit_index, total)
end

--- Move to the next scope.
function M.next_scope()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local gh_mod = require("fude.gh")
	local commit_entries = gh_mod.parse_commit_entries(state.pr_commits)
	local total = #commit_entries
	local next_idx = M.find_next_scope_index(state.scope, state.scope_commit_index, total)

	if next_idx == 0 then
		M.apply_full_pr_scope()
	else
		local entry = commit_entries[next_idx]
		if entry and entry.sha then
			M.apply_commit_scope(entry.sha)
		end
	end
end

--- Move to the previous scope.
function M.prev_scope()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local gh_mod = require("fude.gh")
	local commit_entries = gh_mod.parse_commit_entries(state.pr_commits)
	local total = #commit_entries
	local prev_idx = M.find_prev_scope_index(state.scope, state.scope_commit_index, total)

	if prev_idx == 0 then
		M.apply_full_pr_scope()
	else
		local entry = commit_entries[prev_idx]
		if entry and entry.sha then
			M.apply_commit_scope(entry.sha)
		end
	end
end

--- Format preview lines for a scope entry's changed files.
--- @param files table[] array of { filename, status, additions, deletions }
--- @param status_icons table<string, string> status-to-icon map
--- @param format_path_fn fun(s: string): string|nil formats file path for display (nil = identity)
--- @return string[] lines formatted lines for the previewer
--- @return table[] highlights { { line_0idx, col_start, col_end, hl_group } }
function M.format_scope_preview_lines(files, status_icons, format_path_fn)
	format_path_fn = format_path_fn or function(p)
		return p
	end
	if #files == 0 then
		return { "No changed files" }, {}
	end
	local lines = { string.format("Changed files: %d", #files), "" }
	local highlights = {}
	for _, f in ipairs(files) do
		local icon = (status_icons and status_icons[f.status]) or "?"
		local adds = f.additions or 0
		local dels = f.deletions or 0
		local add_part = string.format("+%-4d", adds)
		local del_part = string.format("-%-4d", dels)
		local raw = format_path_fn(f.filename)
		local display_name = type(raw) == "string" and raw or f.filename
		local line = "  " .. icon .. " " .. add_part .. " " .. del_part .. " " .. display_name
		local line_idx = #lines -- 0-indexed

		local status_hl = f.status == "added" and "DiffAdd" or f.status == "removed" and "DiffDelete" or "DiffChange"
		table.insert(highlights, { line_idx, 2, 3, status_hl })
		table.insert(highlights, { line_idx, 4, 4 + #add_part, "DiffAdd" })
		local del_start = 4 + #add_part + 1
		table.insert(highlights, { line_idx, del_start, del_start + #del_part, "DiffDelete" })

		table.insert(lines, line)
	end
	return lines, highlights
end

--- Refresh the preview window if it is currently open.
function M.refresh_preview()
	local state = config.state
	local preview = require("fude.preview")
	if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
		local source_win = state.source_win
		preview.close_preview()
		if source_win and vim.api.nvim_win_is_valid(source_win) then
			preview.open_preview(source_win)
		end
	end
end

return M
