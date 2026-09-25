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

--- Serialize PR edit content into a single string for drafts.json storage.
--- Line 1 holds the title, the remaining lines hold the body verbatim, so
--- parse_edit_draft can split them back apart. Normalization is delegated to
--- parse_pr_buffer so a restored draft always matches what submit would send.
--- @param title_lines string[]
--- @param body_lines string[]
--- @return string
function M.serialize_edit_draft(title_lines, body_lines)
	local parsed = M.parse_pr_buffer(title_lines or {}, body_lines or {}, { trim_body = false })
	return parsed.title .. "\n" .. parsed.body
end

--- Parse a serialized PR edit draft back into title/body lines.
--- @param text string
--- @return table { title_lines: string[], body_lines: string[] }
function M.parse_edit_draft(text)
	local lines = vim.split(text or "", "\n", { plain = true })
	local title = table.remove(lines, 1) or ""
	if #lines == 0 then
		lines = { "" }
	end
	return { title_lines = { title }, body_lines = lines }
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
--- CommonMark, where a bare destination cannot contain whitespace or
--- unbalanced parentheses — such a reference is not recognized and gh appends
--- the upload instead of rewriting it — so a path with whitespace or
--- parentheses is written in the angle-bracket form.
--- @param path string
--- @return string
local function format_attachment_destination(path)
	if path:find("[%s%(%)]") then
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
--- the first-seen spelling so gh receives a single --attach flag. A path
--- containing "#" (gh treats it as the alt text separator in --attach
--- arguments) or "<"/">" (not representable in an angle-bracket destination)
--- is not supported: such a reference is left untouched — not attached and
--- not rewritten. Paths with spaces or parentheses are supported and written
--- in the angle-bracket destination form.
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
		-- "#" would be split as the alt text separator by gh's --attach
		-- parsing, attaching the wrong file; "<"/">" cannot survive the
		-- angle-bracket destination form. Leave such references untouched
		if path == "" or path:find("[#<>]") then
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
			-- A closing fence carries no info string (CommonMark), so a line
			-- like ```lua inside a fence is content, not a close
			if marker == fence and line:match("^%s*" .. fence .. "+%s*$") then
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
--- Paths containing "#" or "<"/">" are rejected — parse_body_attachments
--- cannot attach them (gh treats "#" as the alt text separator; "<"/">" break
--- the angle-bracket destination form), so converting such a paste would only
--- produce a dead file:// reference.
--- @param path string
--- @return boolean
function M.is_local_media_path(path)
	if not (path:match("^/") or path:match("^~/") or path:match("^%./") or path:match("^%.%./")) then
		return false
	end
	if path:find("[#<>]") then
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

--- Stack a freshly created PR on top of the open PR of `parent_branch` as a
--- GitHub stacked PR (`gh stack link <parent PR> <new PR>`).
--- The parent is passed as its PR URL, never as a branch name: `gh stack link`
--- pushes branch arguments and creates PRs for branches without one, which
--- would open an unrequested PR for the parent. When the parent has no open
--- PR the step is skipped with a warning, since a stack links PRs, not branches;
--- a failed lookup gets its own warning with gh's error so it is not mistaken for "no PR".
--- The PR itself is already created at this point, so every failure is a WARN
--- that leaves it in place as an ordinary (unstacked) PR.
--- @param parent_branch string base branch the PR was created against (the picked base)
--- @param pr_url string URL of the PR just created
--- @private
local function link_to_stack(parent_branch, pr_url)
	gh.get_open_pr_url(parent_branch, function(lookup_err, parent_url)
		if lookup_err then
			vim.notify(
				"fude.nvim: Not stacked: failed to look up the PR of "
					.. parent_branch
					.. " (the PR was created unstacked): "
					.. vim.trim(lookup_err),
				vim.log.levels.WARN
			)
			return
		end
		if not parent_url then
			vim.notify(
				"fude.nvim: Not stacked: " .. parent_branch .. " has no open PR (the PR was created unstacked)",
				vim.log.levels.WARN
			)
			return
		end
		gh.link_stack({ parent_url, pr_url }, function(err)
			if err then
				vim.notify("fude.nvim: Stacking failed (the PR was created unstacked): " .. vim.trim(err), vim.log.levels.WARN)
				return
			end
			vim.notify("fude.nvim: Stacked on " .. parent_url, vim.log.levels.INFO)
		end)
	end)
end

--- Open the PR float with explicit title and body content.
--- @param title_lines string[]|nil initial title lines (default: {""})
--- @param body_lines string[]|nil initial body lines (default: {""})
--- @param opts table|nil { mode: "create"|"edit", footer: string, from_draft: boolean, on_submit: fun(...),
---   allow_draft: boolean, on_save_draft: fun(t_lines: string[], b_lines: string[]), on_discard_draft: fun(),
---   base: string|nil (create mode: base branch passed to `gh pr create --base`; nil lets gh choose),
---   stack: boolean|nil (create mode: the user chose to stack the PR; after creation it is linked
---   on top of the open PR of `base` as a GitHub stacked PR) }
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
	local footer_text = opts.footer or M.build_footer_text(mode, opts.from_draft, opts.base, opts.stack)

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
		-- arbitrary, so the first line continues the previous last line;
		-- phase 1 may deliver an empty chunk, leaving paste_chunks empty)
		if #paste_chunks == 0 then
			paste_chunks[1] = lines[1] or ""
		else
			paste_chunks[#paste_chunks] = paste_chunks[#paste_chunks] .. (lines[1] or "")
		end
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
		-- save_draft stores a fresh table, so a reference compare below tells
		-- whether the draft was replaced while the request was in flight
		local draft_at_submit = M.get_draft()

		vim.notify("fude.nvim: Creating draft PR...", vim.log.levels.INFO)

		local extracted = M.parse_body_attachments(parsed.body, expand_home)
		gh.create_draft_pr(parsed.title, extracted.body, extracted.attachments, opts.base, function(err, data)
			if err then
				vim.notify("fude.nvim: " .. M.format_attach_error(err) .. " (draft saved)", vim.log.levels.ERROR)
				return
			end
			-- Success: clear the draft, unless a newer one was saved while
			-- the request was in flight (e.g. the user reopened :FudePR)
			if M.get_draft() == draft_at_submit then
				M.clear_draft()
			end
			local url = data and data.url or ""
			local suffix = M.format_attach_suffix(#extracted.attachments)
			vim.notify("fude.nvim: Draft PR created: " .. url .. suffix, vim.log.levels.INFO)
			if opts.stack and opts.base and url ~= "" then
				link_to_stack(opts.base, url)
			end
		end)
	end

	-- Draft-save wiring for the cancel confirmation. create mode always saves
	-- to the session-local draft; edit mode saves only when the caller wires a
	-- drafts.json handler, otherwise the plain Yes/No confirmation is shown.
	local allow_draft = opts.allow_draft
	if allow_draft == nil then
		allow_draft = not is_edit
	end
	local on_save_draft = opts.on_save_draft
	if not on_save_draft and not is_edit then
		on_save_draft = function(t_lines, b_lines)
			M.save_draft(t_lines, b_lines)
			vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
		end
	end
	if not on_save_draft then
		allow_draft = false
	end

	-- Cancel handler: confirm before discarding unsaved changes, mirroring the
	-- comment input close flow. The baseline is the lines the float opened
	-- with (a restored draft included), so an unedited buffer closes silently.
	-- Only the q keymap goes through here — closing a window directly (:q
	-- etc.) fires WinClosed and still discards without confirmation.
	local function cancel()
		-- Either buffer can be wiped while its window survives (e.g. :e in a
		-- pane replaces the nofile buffer); nothing is left to confirm then
		if not (vim.api.nvim_buf_is_valid(title_buf) and vim.api.nvim_buf_is_valid(body_buf)) then
			close_all()
			return
		end
		local ui = require("fude.ui")
		local t_cur = vim.api.nvim_buf_get_lines(title_buf, 0, -1, false)
		local b_cur = vim.api.nvim_buf_get_lines(body_buf, 0, -1, false)
		local dirty = ui.should_confirm_discard(t_cur, title_lines) or ui.should_confirm_discard(b_cur, body_lines)
		if not dirty then
			close_all()
			return
		end
		ui.prompt_close_decision(allow_draft, function()
			on_save_draft(t_cur, b_cur)
			close_all()
		end, function()
			if opts.on_discard_draft then
				opts.on_discard_draft()
			end
			close_all()
		end, { unsaved = "Unsaved PR:", discard = "Discard changes?" })
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
--- @param float_opts table|nil extra open_pr_float opts (e.g. { base = "main" })
--- @private
local function open_from_draft(float_opts)
	local d = M.get_draft()
	if d then
		-- "Discard & close" deletes the stored draft too, matching the edit
		-- mode and comment input semantics. Opening from a template instead
		-- leaves an unrelated stored draft alone (no on_discard_draft there).
		local opts = vim.tbl_extend("force", float_opts or {}, { from_draft = true, on_discard_draft = M.clear_draft })
		M.open_pr_float(d.title_lines, d.body_lines, opts)
	end
end

--- Open the float from a template file.
--- @param path string template file path
--- @param default_title string|nil default title from first commit
--- @param float_opts table|nil extra open_pr_float opts (e.g. { base = "main" })
--- @private
local function open_from_template(path, default_title, float_opts)
	local lines = vim.fn.readfile(path)
	local title_lines = default_title and { default_title } or nil
	M.open_pr_float(title_lines, lines, float_opts)
end

--- Get default PR title from the first commit not on the base branch (lazy helper).
--- @param base string|nil base branch; nil yields nil (no commit range to derive the title from)
--- @return string|nil default_title
local function get_default_title(base)
	if base then
		return diff.get_first_commit_subject(base)
	end
	return nil
end

--- Build the footer for the two-pane PR float when no explicit footer is given.
--- Create mode shows the base branch so the user can confirm the target picked
--- in the preceding picker before submitting.
--- @param mode string "create"|"edit"
--- @param from_draft boolean|nil whether the float was opened from a restored draft
--- @param base string|nil base branch (create mode only)
--- @param stack boolean|nil whether the PR will be stacked on `base` (create mode only)
--- @return string footer_text
function M.build_footer_text(mode, from_draft, base, stack)
	local action = mode == "edit" and "<CR> update" or "<CR> create draft"
	if mode ~= "edit" and base and base ~= "" then
		action = action .. " → " .. base
		if stack then
			action = action .. " (stacked)"
		end
	end
	local cancel = from_draft and "q cancel (draft restored)" or "q cancel"
	return " " .. action .. " | " .. cancel .. " "
end

--- Build picker entries for base branch selection.
--- Order: the default branch first (so pressing <CR> in a fresh picker accepts it)
--- with a "(default)" marker, then related branches right after it (the gh-stack
--- parent, then branches HEAD was built on top of, nearest first) with a marker
--- naming the relation, then the remaining branches in the given order.
--- A default branch missing from `branches` is still listed first, since
--- `get_default_branch` can resolve it from a source other than the remote refs.
--- Related branches are listed only when present in `branches`: gh can only
--- target a branch that exists on the remote. The current branch is never
--- listed, since a PR cannot target its own head branch.
--- @param branches string[] candidate branch names (e.g. from diff.get_remote_branches)
--- @param default_branch string|nil repository default branch
--- @param opts table|nil { current_branch: string|nil, stack_parent: string|nil, ancestors: string[]|nil }
--- @return table[] entries { display: string, value: string, is_default: boolean, relation: string|nil }
function M.build_base_branch_entries(branches, default_branch, opts)
	opts = opts or {}
	local entries = {}
	local seen = {}
	if opts.current_branch then
		seen[opts.current_branch] = true
	end
	if default_branch and default_branch ~= "" and not seen[default_branch] then
		table.insert(entries, { display = default_branch .. " (default)", value = default_branch, is_default = true })
		seen[default_branch] = true
	end

	local on_remote = {}
	for _, name in ipairs(branches or {}) do
		on_remote[name] = true
	end
	local related = {}
	if opts.stack_parent then
		table.insert(related, { name = opts.stack_parent, relation = "stack parent" })
	end
	for _, name in ipairs(opts.ancestors or {}) do
		table.insert(related, { name = name, relation = "ancestor" })
	end
	for _, r in ipairs(related) do
		if on_remote[r.name] and not seen[r.name] then
			table.insert(entries, {
				display = r.name .. " (" .. r.relation .. ")",
				value = r.name,
				is_default = false,
				relation = r.relation,
			})
			seen[r.name] = true
		end
	end

	for _, name in ipairs(branches or {}) do
		if not seen[name] then
			table.insert(entries, { display = name, value = name, is_default = false })
			seen[name] = true
		end
	end
	return entries
end

--- Find the relation marker of the entry whose value is `value`.
--- @param entries table[] entries from build_base_branch_entries
--- @param value string|nil selected branch name
--- @return string|nil relation ("stack parent" | "ancestor"), nil for unrelated or unknown branches
function M.find_entry_relation(entries, value)
	for _, e in ipairs(entries or {}) do
		if e.value == value then
			return e.relation
		end
	end
	return nil
end

--- Show an entry picker using Telescope when available, otherwise vim.ui.select.
--- Telescope preselects the first result, so callers order entries default-first.
--- @param entries table[] entries { display: string, value: string, ... }
--- @param opts table { prompt: string (vim.ui.select prompt), title: string (Telescope prompt title),
---   make_previewer: (fun(): table)|nil (Telescope only; called lazily so the fallback path never requires Telescope) }
--- @param callback fun(selected: string|nil) receives entry value or nil on cancel
--- @private
local function pick_entry(entries, opts, callback)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		-- Fallback to vim.ui.select
		local items = {}
		for _, e in ipairs(entries) do
			table.insert(items, e.display)
		end
		vim.ui.select(items, {
			prompt = opts.prompt,
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

	pickers
		.new({}, {
			prompt_title = opts.title,
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
			previewer = opts.make_previewer and opts.make_previewer() or nil,
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

--- Build the choices for the "create as stacked PR?" prompt.
--- The likely answer comes first so a bare <CR> accepts it: Yes for the
--- gh-stack parent (the branch is already the layer below in a local stack),
--- No otherwise (an arbitrary branch is usually just a merge target).
--- @param relation string|nil relation of the picked base ("stack parent" | "ancestor" | nil)
--- @return table[] choices { label: string, stack: boolean }
function M.build_stack_choices(relation)
	local yes = { label = "Yes (stacked PR)", stack = true }
	local no = { label = "No (ordinary PR)", stack = false }
	if relation == "stack parent" then
		return { yes, no }
	end
	return { no, yes }
end

--- Ask whether to create the PR as a GitHub stacked PR on top of `base`.
--- @param base string picked base branch
--- @param relation string|nil relation of the picked base (orders the choices)
--- @param callback fun(stack: boolean|nil) true/false for the answer, nil on cancel
function M.confirm_stack(base, relation, callback)
	local choices = M.build_stack_choices(relation)
	vim.ui.select(choices, {
		prompt = "Stack the PR on " .. base .. "?",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if choice then
			callback(choice.stack)
		else
			callback(nil)
		end
	end)
end

--- Show the base branch picker (Telescope or vim.ui.select).
--- @param entries table[] entries from build_base_branch_entries
--- @param callback fun(selected: string|nil) receives the branch name or nil on cancel
function M.select_base_branch(entries, callback)
	pick_entry(entries, {
		prompt = "Select base branch:",
		title = "Base Branch",
	}, callback)
end

--- Continue the creation flow after the base branch is settled: find templates,
--- select if multiple, open the float.
--- When a draft exists, it is shown as a selectable option alongside templates.
--- @param base string|nil base branch (nil: gh chooses)
--- @param stack boolean|nil whether the user chose to stack the PR on `base` (linked after creation)
--- @private
local function create_with_base(base, stack)
	local templates = M.find_templates()
	local has_draft = M.get_draft() ~= nil
	local total = #templates + (has_draft and 1 or 0)
	local float_opts = { base = base, stack = stack }

	if total == 0 then
		-- No templates, no draft: open with empty body
		local default_title = get_default_title(base)
		local title_lines = default_title and { default_title } or nil
		M.open_pr_float(title_lines, { "" }, float_opts)
	elseif total == 1 and not has_draft then
		-- Single template, no draft: read and open
		local default_title = get_default_title(base)
		open_from_template(templates[1], default_title, float_opts)
	elseif total == 1 and has_draft then
		-- Only draft, no templates: open from draft
		open_from_draft(float_opts)
	else
		-- Multiple options: show picker with draft + templates
		local entries = M.build_picker_entries(templates, has_draft)
		M.select_template(entries, function(selected)
			if not selected then
				return
			end
			if selected == "__draft__" then
				open_from_draft(float_opts)
			else
				-- Lazy: only fetch default title when template is selected
				local default_title = get_default_title(base)
				open_from_template(selected, default_title, float_opts)
			end
		end)
	end
end

--- Show PR creation flow: pick the base branch, then templates, then open the float.
--- The base picker lists remote branches with the default branch preselected and
--- related branches (gh-stack parent, branches HEAD is built on) right after it
--- (a default branch resolved from local refs is listed even without a remote,
--- so the default title keeps its commit range). It is skipped only when there
--- are no candidates at all, in which case gh chooses the base as before.
function M.create()
	local repo_root = diff.get_repo_root()
	if not repo_root then
		vim.notify("fude.nvim: Not in a git repository", vim.log.levels.ERROR)
		return
	end

	local default_branch = diff.get_default_branch()
	local current_branch = diff.get_current_branch()
	local entries = M.build_base_branch_entries(diff.get_remote_branches(), default_branch, {
		current_branch = current_branch,
		stack_parent = diff.get_gh_stack_parent(current_branch),
		ancestors = diff.get_ancestor_branches(default_branch),
	})
	if #entries == 0 then
		create_with_base(nil)
		return
	end
	M.select_base_branch(entries, function(base)
		if not base then
			return
		end
		if base == default_branch then
			create_with_base(base, false)
			return
		end
		M.confirm_stack(base, M.find_entry_relation(entries, base), function(stack)
			if stack == nil then
				return
			end
			create_with_base(base, stack)
		end)
	end)
end

--- Show template/draft picker using Telescope or vim.ui.select.
--- @param entries table[] entries from build_picker_entries
--- @param callback fun(selected: string|nil) receives entry value or nil
function M.select_template(entries, callback)
	pick_entry(entries, {
		prompt = "Select PR template:",
		title = "PR Templates",
		make_previewer = function()
			local previewers = require("telescope.previewers")
			return previewers.new_buffer_previewer({
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
			})
		end,
	}, callback)
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

				local drafts = require("fude.drafts")
				-- Derive the draft key from the PR url, not config.state:
				-- FudeEditPR also works without an active review session. No
				-- slug means no persistent draft (Yes/No fallback on cancel).
				local slug = drafts.repo_slug(data.url)
				local draft_key = slug and drafts.make_draft_key(slug, num, "pr_edit") or nil

				local title_lines = { data.title }
				local body_lines = vim.split(format.normalize_newlines(data.body), "\n", { plain = true })
				local saved = drafts.get(draft_key)
				local from_draft = false
				if saved then
					local restored = M.parse_edit_draft(format.normalize_newlines(saved))
					title_lines = restored.title_lines
					body_lines = restored.body_lines
					from_draft = true
				end

				-- The float stays open until an update request finishes, so a
				-- draft explicitly saved while one is in flight (q -> "Save
				-- draft & close") is newer user intent: the success cleanup
				-- must not delete it. A flag beats comparing stored content,
				-- which would misfire when the re-saved draft happens to
				-- serialize identically to the pre-submit one.
				local draft_saved_in_flight = false

				M.open_pr_float(title_lines, body_lines, {
					mode = "edit",
					from_draft = from_draft,
					allow_draft = draft_key ~= nil and drafts.enabled(),
					on_save_draft = function(t_lines, b_lines)
						local serialized = M.serialize_edit_draft(t_lines, b_lines)
						-- drafts.set removes the entry for empty input, so
						-- don't claim a draft was saved in that case
						drafts.set(draft_key, serialized)
						draft_saved_in_flight = true
						if vim.trim(serialized) == "" then
							vim.notify("fude.nvim: Empty input — draft cleared", vim.log.levels.INFO)
						else
							vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
						end
					end,
					on_discard_draft = function()
						drafts.remove(draft_key)
					end,
					on_submit = function(title, body, close_float)
						vim.notify("fude.nvim: Updating PR...", vim.log.levels.INFO)
						draft_saved_in_flight = false
						local extracted = M.parse_body_attachments(body, expand_home)
						gh.edit_pr(num, title, extracted.body, extracted.attachments, function(edit_err)
							vim.schedule(function()
								if edit_err then
									vim.notify("fude.nvim: " .. M.format_attach_error(edit_err), vim.log.levels.ERROR)
								else
									close_float()
									if not draft_saved_in_flight then
										drafts.remove(draft_key)
									end
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
