local M = {}
local config = require("fude.config")

--- Build scope selection entries for the picker.
--- First entry is always "Full PR", followed by commit entries (newest first).
--- @param commit_entries table[] normalized commit entries from gh.parse_commit_entries
--- @param base_ref string base branch name
--- @param head_ref string head branch name
--- @return table[] entries array of { value, display_text, sha, is_full_pr }
function M.build_scope_entries(commit_entries, base_ref, head_ref)
	local entries = {}
	table.insert(entries, {
		value = "full_pr",
		display_text = string.format("PR全体 (%s...%s)", base_ref, head_ref),
		sha = nil,
		is_full_pr = true,
	})
	for _, c in ipairs(commit_entries) do
		table.insert(entries, {
			value = c.sha,
			display_text = string.format("%s %s (%s)", c.short_sha, c.message, c.author_name),
			sha = c.sha,
			is_full_pr = false,
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

	local scope_entries = M.build_scope_entries(commit_entries, state.base_ref, state.head_ref)

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

	pickers
		.new({}, {
			prompt_title = "Review Scope",
			finder = finders.new_table({
				results = scope_entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display_text,
						ordinal = entry.display_text,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						M.apply_scope(selection.value)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Show scope selection using vim.ui.select.
--- @param scope_entries table[] entries from build_scope_entries
function M.show_vim_select(scope_entries)
	vim.ui.select(scope_entries, {
		prompt = "Review Scope:",
		format_item = function(entry)
			return entry.display_text
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

		-- Update gitsigns base
		local has_gitsigns, gitsigns = pcall(require, "gitsigns")
		if has_gitsigns then
			gitsigns.change_base(state.base_ref, true)
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
	if status_result.code == 0 and status_result.stdout ~= "" then
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
