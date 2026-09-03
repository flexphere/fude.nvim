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

--- Expand a leading "~/" (or a bare "~") in an attachment path to the home
--- directory. Deliberately not vim.fn.expand(), which also runs backtick
--- expressions as shell commands and expands globs/braces — attachment paths
--- can come from pasted or templated text and must be treated as data.
--- gh matches body references against --attach paths literally, so the same
--- expanded path must be used in both the body and the --attach argument.
--- @param path string
--- @return string
local function expand_home(path)
	local home = vim.uv.os_homedir()
	if home and (path == "~" or vim.startswith(path, "~/")) then
		return home .. path:sub(2)
	end
	return path
end

--- Format a link destination for the rewritten body. gh parses the body as
--- CommonMark, where a bare destination cannot contain whitespace — such a
--- reference is not recognized and gh appends the upload instead of rewriting
--- it — so a path with whitespace is written in the angle-bracket form.
--- @param path string
--- @return string
local function format_attachment_destination(path)
	if path:find("%s") then
		return "<" .. path .. ">"
	end
	return path
end

--- Extract local attachment paths (file:// scheme) from a PR body.
--- Only inline markdown link/image destinations — `](file://...)` or the
--- angle-bracket form `](<file://...>)` — are treated as attachments; lines
--- inside fenced code blocks (``` or ~~~) are skipped (inline code spans are
--- not recognized). Paths may contain spaces (the destination is rewritten in
--- the CommonMark `<...>` form) but not `)`. The file:// prefix is stripped
--- from the body so the remaining path matches the --attach argument (gh
--- rewrites matching body references to the uploaded URL). Different
--- spellings of the same file (e.g. "./x.png" and "x.png") are rewritten to
--- the first-seen spelling so gh receives a single --attach flag.
--- @param body string PR body
--- @param expand_fn nil|fun(path: string): string path expansion applied to each extracted path (e.g. "~" expansion)
--- @return table { body: string, attachments: string[] } rewritten body and deduplicated attachment paths
function M.parse_body_attachments(body, expand_fn)
	expand_fn = expand_fn or function(path)
		return path
	end
	local attachments = {}
	local canonical = {} -- normalized key -> first-seen spelling
	local function collect(pre, path, post)
		path = vim.trim(path)
		if path == "" then
			return nil -- keep the original text
		end
		local expanded = expand_fn(path)
		local key = (expanded:gsub("^%./", ""))
		if not canonical[key] then
			canonical[key] = expanded
			table.insert(attachments, expanded)
		end
		return pre .. format_attachment_destination(canonical[key]) .. post
	end
	local fence = nil -- opening fence marker ("```" or "~~~") while inside a fenced block
	local out_lines = {}
	for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
		local marker = line:match("^%s*(```)") or line:match("^%s*(~~~)")
		if fence then
			if marker == fence then
				fence = nil
			end
		elseif marker then
			fence = marker
		else
			line = line:gsub("(%]%()<file://([^>]*)>(%))", collect)
			line = line:gsub("(%]%()file://([^%)]*)(%))", collect)
		end
		table.insert(out_lines, line)
	end
	return { body = table.concat(out_lines, "\n"), attachments = attachments }
end

--- Replace the unknown-flag usage dump with a concise upgrade hint when gh
--- doesn't support --attach (added in gh 2.99.0). gh answers an unknown flag
--- with its full multi-line usage text, which would bury the actionable part.
--- @param err string error message from gh
--- @return string
function M.format_attach_error(err)
	if err:find("unknown flag: --attach", 1, true) then
		return "PR body attachments (--attach) require gh >= 2.99.0; please update GitHub CLI"
	end
	return err
end

--- File extensions treated as attachable media when pasted as a local path.
local MEDIA_EXTENSIONS = {
	png = true,
	jpg = true,
	jpeg = true,
	gif = true,
	svg = true,
	webp = true,
	mp4 = true,
	mov = true,
	webm = true,
}

--- Clean a pasted chunk into a local path candidate.
--- Strips surrounding whitespace, matching quotes (Finder/terminals wrap
--- copied paths in ' or "), and shell-escaped spaces ("\ ").
--- @param text string
--- @return string cleaned
function M.clean_pasted_path(text)
	local cleaned = vim.trim(text)
	local quote = cleaned:sub(1, 1)
	if (quote == "'" or quote == '"') and #cleaned >= 2 and cleaned:sub(-1) == quote then
		cleaned = cleaned:sub(2, -2)
	end
	return (cleaned:gsub("\\ ", " "))
end

--- Whether a cleaned path looks like a local media file (image/video).
--- @param path string
--- @return boolean
function M.is_local_media_path(path)
	if not (path:match("^/") or path:match("^~/") or path:match("^%./") or path:match("^%.%./")) then
		return false
	end
	local ext = path:match("%.(%w+)$")
	return ext ~= nil and MEDIA_EXTENSIONS[ext:lower()] == true
end

--- Build replacement lines for a paste into the PR body, or nil to fall back
--- to the default paste. A pasted local image/video path becomes a markdown
--- `![](file://path)` reference; when the cursor already sits inside a
--- `](file://` or `](` destination, only the (prefixed) path is inserted.
--- @param lines string[] pasted lines
--- @param before_cursor string text on the current line before the cursor
--- @return string[]|nil
function M.transform_media_paste(lines, before_cursor)
	local content = {}
	for _, l in ipairs(lines) do
		if vim.trim(l) ~= "" then
			table.insert(content, l)
		end
	end
	if #content ~= 1 then
		return nil
	end
	local path = M.clean_pasted_path(content[1])
	if not M.is_local_media_path(path) then
		return nil
	end
	if before_cursor:sub(-7) == "file://" then
		return { path }
	end
	if before_cursor:sub(-2) == "](" then
		return { format_attachment_destination("file://" .. path) }
	end
	return { "![](" .. format_attachment_destination("file://" .. path) .. ")" }
end

--- Build the attachment-count suffix for success notifications.
--- Gives feedback that extraction actually happened (e.g. 0 when a reference
--- sat inside an unclosed code fence and was skipped).
--- @param count number number of attached files
--- @return string "" when count is 0, otherwise e.g. " (2 files attached)"
function M.format_attach_suffix(count)
	if count == 0 then
		return ""
	end
	return " (" .. count .. (count == 1 and " file" or " files") .. " attached)"
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

	-- Paste interception: convert a pasted local media path in the body pane
	-- into a ![](file://...) reference. vim.paste is the only hook for
	-- terminal (bracketed) paste — there is no dedicated autocmd event — so
	-- wrap it while the float is open and restore it on close. Streamed
	-- pastes (phase 1..3) are accumulated so the decision sees the full text.
	local original_paste = vim.paste
	local paste_chunks = nil
	local intercepting = false
	local function handle_body_paste(lines)
		local col = vim.api.nvim_win_get_cursor(0)[2]
		-- vim.paste inserts before the cursor in insert mode but after the
		-- cursor character in normal mode; compute the text left of the
		-- actual insertion point
		if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
			col = col + 1
		end
		local before_cursor = vim.api.nvim_get_current_line():sub(1, col)
		local replacement = M.transform_media_paste(lines, before_cursor)
		return original_paste(replacement or lines, -1)
	end
	---@diagnostic disable-next-line: duplicate-set-field
	vim.paste = function(lines, phase)
		if phase == -1 then
			if vim.api.nvim_get_current_buf() == body_buf then
				return handle_body_paste(lines)
			end
			return original_paste(lines, phase)
		end
		if phase == 1 then
			intercepting = vim.api.nvim_get_current_buf() == body_buf
			if intercepting then
				paste_chunks = { unpack(lines) }
				return true
			end
			return original_paste(lines, phase)
		end
		if not intercepting then
			return original_paste(lines, phase)
		end
		-- phase 2/3 of an intercepted stream: merge (chunk boundaries are
		-- arbitrary, so the first line continues the previous last line)
		paste_chunks[#paste_chunks] = paste_chunks[#paste_chunks] .. (lines[1] or "")
		for i = 2, #lines do
			table.insert(paste_chunks, lines[i])
		end
		if phase == 3 then
			local chunks = paste_chunks
			paste_chunks = nil
			intercepting = false
			return handle_body_paste(chunks)
		end
		return true
	end

	-- Close helper
	local closing = false
	local function close_all()
		if closing then
			return
		end
		closing = true
		vim.paste = original_paste
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

		local extracted = M.parse_body_attachments(parsed.body, expand_home)
		gh.create_draft_pr(parsed.title, extracted.body, extracted.attachments, function(err, data)
			if err then
				vim.notify("fude.nvim: " .. M.format_attach_error(err) .. " (draft saved)", vim.log.levels.ERROR)
				return
			end
			-- Success: clear the draft
			M.clear_draft()
			local url = data and data.url or ""
			local suffix = M.format_attach_suffix(#extracted.attachments)
			vim.notify("fude.nvim: Draft PR created: " .. url .. suffix, vim.log.levels.INFO)
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
						local extracted = M.parse_body_attachments(body, expand_home)
						gh.edit_pr(num, title, extracted.body, extracted.attachments, function(edit_err)
							vim.schedule(function()
								if edit_err then
									vim.notify("fude.nvim: " .. M.format_attach_error(edit_err), vim.log.levels.ERROR)
								else
									close_float()
									local suffix = M.format_attach_suffix(#extracted.attachments)
									vim.notify("fude.nvim: PR updated" .. suffix, vim.log.levels.INFO)
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
