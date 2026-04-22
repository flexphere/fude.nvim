local M = {}
local config = require("fude.config")
local diff = require("fude.diff")

M.status_icons = {
	added = "+",
	modified = "~",
	removed = "-",
	renamed = "R",
	copied = "C",
}

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
			prompt_title = string.format("PR #%d Changed Files", state.pr_number),
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

					if entry.patch == "" then
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "(no diff)" })
						return
					end
					local lines = vim.split(entry.patch, "\n", { trimempty = false })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "diff"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
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
		title = string.format("PR #%d Changed Files", state.pr_number),
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
			if item.patch == "" then
				ctx.preview:set_lines({ "(no diff)" })
				return
			end
			local lines = vim.split(item.patch, "\n", { trimempty = false })
			ctx.preview:set_lines(lines)
			ctx.preview:highlight({ ft = "diff" })
		end,
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
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
	if not state.pr_node_id then
		vim.notify("fude.nvim: PR node ID not available", vim.log.levels.WARN)
		return
	end

	local gh_mod = require("fude.gh")
	local viewed_sign = config.opts.signs.viewed or "✓"
	local current_state = state.viewed_files[path]
	local new_state = (current_state == "VIEWED") and "UNVIEWED" or "VIEWED"
	local toggle_fn = (current_state == "VIEWED") and gh_mod.unmark_file_viewed or gh_mod.mark_file_viewed

	toggle_fn(state.pr_node_id, path, function(err)
		if err then
			vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[path] = new_state
		local v_icon, v_hl = M.viewed_icon(new_state, viewed_sign)
		on_done({
			path = path,
			viewed_state = new_state,
			viewed_icon = v_icon,
			viewed_hl = v_hl,
		})
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
	for _, entry in ipairs(raw_entries) do
		local comment_part = entry.comment_display ~= "" and (" " .. entry.comment_display) or ""
		table.insert(items, {
			filename = entry.filename,
			lnum = 1,
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
		title = string.format("PR #%d Changed Files", state.pr_number),
		items = items,
	})
	vim.cmd("copen")
end

return M
