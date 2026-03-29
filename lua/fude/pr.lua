local M = {}
local config = require("fude.config")
local diff = require("fude.diff")
local format = require("fude.ui.format")
local gh = require("fude.gh")

--- Template search directory names (for multiple templates).
local TEMPLATE_DIRS = {
	".github/PULL_REQUEST_TEMPLATE",
	"PULL_REQUEST_TEMPLATE",
	"docs/PULL_REQUEST_TEMPLATE",
}

--- Template search file names (for single template).
local TEMPLATE_FILES = {
	".github/pull_request_template.md",
	".github/PULL_REQUEST_TEMPLATE.md",
	"pull_request_template.md",
	"PULL_REQUEST_TEMPLATE.md",
	"docs/pull_request_template.md",
	"docs/PULL_REQUEST_TEMPLATE.md",
}

-- Session-local draft storage for PR creation.
-- Persists across open/close cycles within a single Neovim session.
local draft = nil -- { title_lines: string[], body_lines: string[] } | nil

--- Save the current PR creation draft.
--- @param title_lines string[]
--- @param body_lines string[]
function M.save_draft(title_lines, body_lines)
	draft = { title_lines = title_lines, body_lines = body_lines }
end

--- Get the current PR creation draft.
--- @return table|nil { title_lines: string[], body_lines: string[] }
function M.get_draft()
	return draft
end

--- Clear the PR creation draft.
function M.clear_draft()
	draft = nil
end

--- Build the list of paths to search for PR templates.
--- @param repo_root string repository root directory
--- @return table { dirs: string[], files: string[] }
function M.build_template_search_paths(repo_root)
	local dirs = {}
	for _, d in ipairs(TEMPLATE_DIRS) do
		table.insert(dirs, repo_root .. "/" .. d)
	end
	local files = {}
	for _, f in ipairs(TEMPLATE_FILES) do
		table.insert(files, repo_root .. "/" .. f)
	end
	return { dirs = dirs, files = files }
end

--- Build picker entries for template selection (including draft if available).
--- @param templates string[] list of template file paths
--- @param has_draft boolean whether a draft exists
--- @return table[] entries with display, value, and is_draft fields
function M.build_picker_entries(templates, has_draft)
	local entries = {}
	if has_draft then
		table.insert(entries, { display = "(draft)", value = "__draft__", is_draft = true })
	end
	for _, t in ipairs(templates) do
		table.insert(entries, { display = vim.fn.fnamemodify(t, ":t"), value = t, is_draft = false })
	end
	return entries
end

--- Parse title and body from PR buffer contents.
--- @param title_lines string[] lines from title buffer
--- @param body_lines string[] lines from body buffer
--- @param opts table|nil options: { trim_body: boolean (default true) }
--- @return table { title: string, body: string }
function M.parse_pr_buffer(title_lines, body_lines, opts)
	opts = opts or {}
	local trim_body = opts.trim_body == nil or opts.trim_body
	local title = vim.trim(table.concat(title_lines, " "))
	local body = table.concat(body_lines, "\n")
	if trim_body then
		body = vim.trim(body)
	end
	return { title = title, body = body }
end

--- Find PR template files in the repository.
--- @return string[] list of absolute paths to template files
function M.find_templates()
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return {}
	end

	local paths = M.build_template_search_paths(repo_root)
	local templates = {}

	-- Check template directories first (multiple templates)
	for _, dir in ipairs(paths.dirs) do
		if vim.fn.isdirectory(dir) == 1 then
			local files = vim.fn.glob(dir .. "/*.md", false, true)
			for _, f in ipairs(files) do
				table.insert(templates, f)
			end
		end
	end

	if #templates > 0 then
		return templates
	end

	-- Fall back to single template files
	for _, file in ipairs(paths.files) do
		if vim.fn.filereadable(file) == 1 then
			table.insert(templates, file)
			return templates
		end
	end

	return templates
end

--- Open the PR float with explicit title and body content.
--- @param title_lines string[]|nil initial title lines (default: {""})
--- @param body_lines string[]|nil initial body lines (default: {""})
--- @param opts table|nil { mode: "create"|"edit", footer: string, from_draft: boolean, on_submit: fun(...) }
function M.open_pr_float(title_lines, body_lines, opts)
	title_lines = title_lines or { "" }
	body_lines = body_lines or { "" }
	opts = opts or {}
	local mode = opts.mode or "create"
	local is_edit = mode == "edit"

	-- Create title buffer (editable, single line)
	local title_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, title_lines)
	vim.bo[title_buf].buftype = "nofile"
	vim.bo[title_buf].bufhidden = "wipe"

	-- Create body buffer (editable, multi-line)
	local body_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, body_lines)
	vim.bo[body_buf].buftype = "nofile"
	vim.bo[body_buf].bufhidden = "wipe"
	vim.bo[body_buf].filetype = "markdown"

	-- Calculate dimensions
	local dim = require("fude.ui").calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float and config.opts.float.width or 50,
		config.opts.float and config.opts.float.height or 50
	)

	-- Title pane: fixed 1-line height; +1 accounts for the top border row
	local title_height = 1
	local body_height = math.max(3, dim.height - title_height - 1)

	-- Border definitions: upper has no bottom, lower connects
	local upper_border = { "╭", "─", "╮", "│", "", "", "", "│" }
	local lower_border = { "├", "─", "┤", "│", "╯", "─", "╰", "│" }

	-- Determine footer text
	local footer_text = opts.footer
	if not footer_text then
		if is_edit then
			footer_text = " <CR> update | q cancel "
		elseif opts.from_draft then
			footer_text = " <CR> create draft | q cancel (draft restored) "
		else
			footer_text = " <CR> create draft | q cancel "
		end
	end

	-- Open title window (focused)
	local title_win = vim.api.nvim_open_win(title_buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = title_height,
		style = "minimal",
		border = upper_border,
		title = " PR Title ",
		title_pos = "center",
	})

	-- Open body window (not focused)
	local body_win = vim.api.nvim_open_win(body_buf, false, {
		relative = "editor",
		row = dim.row + title_height + 1,
		col = dim.col,
		width = dim.width,
		height = body_height,
		style = "minimal",
		border = lower_border,
		title = " PR Body ",
		title_pos = "center",
		footer = footer_text,
		footer_pos = "center",
	})
	vim.wo[body_win].wrap = true

	-- Close helper
	local closing = false
	local function close_all()
		if closing then
			return
		end
		closing = true
		pcall(vim.api.nvim_win_close, title_win, true)
		pcall(vim.api.nvim_win_close, body_win, true)
	end

	-- Submit handler
	local function submit()
		local t_lines = vim.api.nvim_buf_get_lines(title_buf, 0, -1, false)
		local b_lines = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
		local parsed = M.parse_pr_buffer(t_lines, b_lines, { trim_body = not is_edit })

		if parsed.title == "" then
			vim.notify("fude.nvim: PR title is required", vim.log.levels.WARN)
			return
		end

		-- Use custom submit handler if provided
		if opts.on_submit then
			if is_edit then
				-- Edit mode: let the handler close the float on success.
				-- On failure the float stays open so the user can retry.
				opts.on_submit(parsed.title, parsed.body, close_all)
			else
				close_all()
				opts.on_submit(parsed.title, parsed.body)
			end
			return
		end

		close_all()

		-- Default: create draft PR
		-- Save draft before attempting to create PR
		M.save_draft(t_lines, b_lines)

		vim.notify("fude.nvim: Creating draft PR...", vim.log.levels.INFO)

		gh.create_draft_pr(parsed.title, parsed.body, function(err, data)
			if err then
				vim.notify("fude.nvim: " .. err .. " (draft saved)", vim.log.levels.ERROR)
				return
			end
			-- Success: clear the draft
			M.clear_draft()
			local url = data and data.url or ""
			vim.notify("fude.nvim: Draft PR created: " .. url, vim.log.levels.INFO)
		end)
	end

	-- Cancel handler
	local function cancel()
		close_all()
	end

	-- Helper to scroll body window from title
	local function scroll_body(keys)
		local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
		return function()
			if vim.api.nvim_win_is_valid(body_win) then
				vim.api.nvim_win_call(body_win, function()
					vim.cmd("normal! " .. termcodes)
				end)
			end
		end
	end

	local submit_desc = is_edit and "Update PR" or "Create draft PR"

	-- Title buffer keymaps
	vim.keymap.set("n", "<CR>", submit, { buffer = title_buf, desc = submit_desc })
	vim.keymap.set("n", "q", cancel, { buffer = title_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(body_win) then
			vim.api.nvim_set_current_win(body_win)
		end
	end, { buffer = title_buf, desc = "Go to body" })
	vim.keymap.set(
		{ "n", "i" },
		"<C-u>",
		scroll_body("<C-u>"),
		{ buffer = title_buf, nowait = true, desc = "Scroll body up" }
	)
	vim.keymap.set(
		{ "n", "i" },
		"<C-d>",
		scroll_body("<C-d>"),
		{ buffer = title_buf, nowait = true, desc = "Scroll body down" }
	)

	-- Body buffer keymaps
	vim.keymap.set("n", "<CR>", submit, { buffer = body_buf, desc = submit_desc })
	vim.keymap.set("n", "q", cancel, { buffer = body_buf, desc = "Cancel" })
	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(title_win) then
			vim.api.nvim_set_current_win(title_win)
		end
	end, { buffer = body_buf, desc = "Go to title" })

	-- Autocmd: close both when one closes
	local augroup = vim.api.nvim_create_augroup("fude_pr_float_" .. title_win, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		pattern = { tostring(title_win), tostring(body_win) },
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == title_win or closed_win == body_win then
				close_all()
				vim.api.nvim_del_augroup_by_id(augroup)
			end
		end,
	})

	-- Start in insert mode
	vim.cmd("startinsert")
end

--- Open the float from a draft selection.
--- @private
local function open_from_draft()
	local d = M.get_draft()
	if d then
		M.open_pr_float(d.title_lines, d.body_lines, { from_draft = true })
	end
end

--- Open the float from a template file.
--- @param path string template file path
--- @param default_title string|nil default title from first commit
--- @private
local function open_from_template(path, default_title)
	local lines = vim.fn.readfile(path)
	local title_lines = default_title and { default_title } or nil
	M.open_pr_float(title_lines, lines)
end

--- Get default PR title from first commit message (lazy helper).
--- @return string|nil default_title
local function get_default_title()
	local default_branch = diff.get_default_branch()
	if default_branch then
		return diff.get_first_commit_subject(default_branch)
	end
	return nil
end

--- Show PR creation flow: find templates, select if multiple, open float.
--- When a draft exists, it is shown as a selectable option alongside templates.
function M.create()
	local repo_root = diff.get_repo_root()
	if not repo_root then
		vim.notify("fude.nvim: Not in a git repository", vim.log.levels.ERROR)
		return
	end

	local templates = M.find_templates()
	local has_draft = M.get_draft() ~= nil
	local total = #templates + (has_draft and 1 or 0)

	if total == 0 then
		-- No templates, no draft: open with empty body
		local default_title = get_default_title()
		local title_lines = default_title and { default_title } or nil
		M.open_pr_float(title_lines, { "" })
	elseif total == 1 and not has_draft then
		-- Single template, no draft: read and open
		local default_title = get_default_title()
		open_from_template(templates[1], default_title)
	elseif total == 1 and has_draft then
		-- Only draft, no templates: open from draft
		open_from_draft()
	else
		-- Multiple options: show picker with draft + templates
		local entries = M.build_picker_entries(templates, has_draft)
		M.select_template(entries, function(selected)
			if not selected then
				return
			end
			if selected == "__draft__" then
				open_from_draft()
			else
				-- Lazy: only fetch default title when template is selected
				local default_title = get_default_title()
				open_from_template(selected, default_title)
			end
		end)
	end
end

--- Show template/draft picker using Telescope or vim.ui.select.
--- @param entries table[] entries from build_picker_entries
--- @param callback fun(selected: string|nil) receives entry value or nil
function M.select_template(entries, callback)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		-- Fallback to vim.ui.select
		local items = {}
		for _, e in ipairs(entries) do
			table.insert(items, e.display)
		end
		vim.ui.select(items, {
			prompt = "Select PR template:",
		}, function(_, idx)
			if idx then
				callback(entries[idx].value)
			else
				callback(nil)
			end
		end)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "PR Templates",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry.value,
						display = entry.display,
						ordinal = entry.display,
						is_draft = entry.is_draft,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Preview",
				get_buffer_by_name = function(_, entry)
					return entry.value
				end,
				define_preview = function(self, entry)
					require("fude.ui").sync_preview_buffer(self)

					local lines
					if entry.is_draft then
						local d = M.get_draft()
						if d then
							lines = {}
							table.insert(lines, "Title: " .. table.concat(d.title_lines, " "))
							table.insert(lines, "")
							for _, line in ipairs(d.body_lines) do
								table.insert(lines, line)
							end
						else
							lines = { "" }
						end
					else
						lines = vim.fn.readfile(entry.value)
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						callback(selection.value)
					else
						callback(nil)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Edit the current PR's title and body.
--- Uses state.pr_number when review mode is active, otherwise detects via gh pr view.
--- Resolves PR number upfront to avoid detached HEAD issues with both get/edit.
function M.edit()
	local pr_number = config.state.active and config.state.pr_number or nil

	vim.notify("fude.nvim: Loading PR...", vim.log.levels.INFO)

	local function do_edit(num)
		gh.get_pr_title_body(num, function(err, data)
			vim.schedule(function()
				if err then
					vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
					return
				end

				local body_lines = vim.split(format.normalize_newlines(data.body), "\n", { plain = true })
				M.open_pr_float({ data.title }, body_lines, {
					mode = "edit",
					footer = " <CR> update | q cancel ",
					on_submit = function(title, body, close_float)
						vim.notify("fude.nvim: Updating PR...", vim.log.levels.INFO)
						gh.edit_pr(num, title, body, function(edit_err)
							vim.schedule(function()
								if edit_err then
									vim.notify("fude.nvim: " .. edit_err, vim.log.levels.ERROR)
								else
									close_float()
									vim.notify("fude.nvim: PR updated", vim.log.levels.INFO)
								end
							end)
						end)
					end,
				})
			end)
		end)
	end

	if pr_number then
		do_edit(pr_number)
	else
		-- Resolve PR number first (handles detached HEAD via get_pr_info)
		gh.get_pr_info(function(err, info)
			if err then
				vim.schedule(function()
					vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
				end)
				return
			end
			do_edit(info.number)
		end)
	end
end

return M
