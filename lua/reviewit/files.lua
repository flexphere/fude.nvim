local M = {}
local config = require("reviewit.config")
local diff = require("reviewit.diff")

M.status_icons = {
	added = "+",
	modified = "~",
	removed = "-",
	renamed = "R",
	copied = "C",
}

--- Build normalized file entries from changed files list.
--- @param changed_files table[] list of { path, status, additions, deletions, patch }
--- @param repo_root string repository root directory
--- @param icons table status-to-icon map
--- @return table[] entries
function M.build_file_entries(changed_files, repo_root, icons)
	local entries = {}
	for _, file in ipairs(changed_files) do
		table.insert(entries, {
			path = file.path,
			filename = repo_root .. "/" .. file.path,
			patch = file.patch or "",
			status_icon = icons[file.status] or "?",
			status_hl = file.status == "added" and "DiffAdd" or file.status == "removed" and "DiffDelete" or "DiffChange",
			additions = file.additions or 0,
			deletions = file.deletions or 0,
		})
	end
	return entries
end

--- Show changed files list using the configured mode.
function M.show()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if #state.changed_files == 0 then
		vim.notify("reviewit.nvim: No changed files loaded", vim.log.levels.INFO)
		return
	end

	if config.opts.file_list_mode == "quickfix" then
		M.show_quickfix()
	else
		M.show_telescope()
	end
end

--- Show changed files in a Telescope picker.
function M.show_telescope()
	local state = config.state
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("reviewit.nvim: telescope.nvim not found, falling back to quickfix", vim.log.levels.WARN)
		M.show_quickfix()
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local previewers = require("telescope.previewers")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 2 },
			{ width = 5 },
			{ width = 5 },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		return displayer({
			{ entry.status_icon, entry.status_hl },
			{ "+" .. entry.additions, "DiffAdd" },
			{ "-" .. entry.deletions, "DiffDelete" },
			entry.value,
		})
	end

	local raw_entries = M.build_file_entries(state.changed_files, repo_root, M.status_icons)
	local entries = {}
	for _, entry in ipairs(raw_entries) do
		entry.value = entry.path
		entry.ordinal = entry.path
		entry.display = make_display
		table.insert(entries, entry)
	end

	pickers
		.new({}, {
			prompt_title = string.format("PR #%d Changed Files", state.pr_number),
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Diff",
				define_preview = function(self, entry)
					if entry.patch == "" then
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "(no diff)" })
						return
					end
					local lines = vim.split(entry.patch, "\n", { trimempty = false })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "diff"
				end,
			}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
					end
				end)
				return true
			end,
		})
		:find()
end

--- Show changed files in the quickfix list.
function M.show_quickfix()
	local state = config.state
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local raw_entries = M.build_file_entries(state.changed_files, repo_root, M.status_icons)
	local items = {}
	for _, entry in ipairs(raw_entries) do
		table.insert(items, {
			filename = entry.filename,
			lnum = 1,
			text = string.format("[%s] +%d -%d  %s", entry.status_icon, entry.additions, entry.deletions, entry.path),
		})
	end

	vim.fn.setqflist({}, " ", {
		title = string.format("PR #%d Changed Files", state.pr_number),
		items = items,
	})
	vim.cmd("copen")
end

return M
