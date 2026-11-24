--- Every changed file's diff in one tabpage, base on the left and head on the
--- right (`:FudeReviewAllDiffs`), like the GitHub PR "Files changed" split view.
--- The rows of both sides are aligned here from the unified patches, so the two
--- windows can share 'scrollbind'/'cursorbind' and any scroll key (<C-e>,
--- <C-d>, j) moves both. <CR> jumps to the line in the review tab.
local config = require("fude.config")

local M = {}

local ns = vim.api.nvim_create_namespace("fude_all_diffs")
local syntax_ns = vim.api.nvim_create_namespace("fude_all_diffs_syntax")

M.STATUS_LABELS = { added = "A", modified = "M", removed = "D", renamed = "R", copied = "C" }
M.NO_DIFF_TEXT = "(diff not available)"
M.FILLER_CHAR = "╱"

M.HL = {
	file = "FudeAllDiffsFile",
	hunk = "FudeAllDiffsHunk",
	delete = "FudeAllDiffsDelete",
	add = "FudeAllDiffsAdd",
	delete_text = "FudeAllDiffsDeleteText",
	add_text = "FudeAllDiffsAddText",
	filler = "FudeAllDiffsFiller",
	note = "FudeAllDiffsNote",
}

local HL_LINKS = {
	[M.HL.file] = "Title",
	[M.HL.hunk] = "Comment",
	[M.HL.delete] = "DiffDelete",
	[M.HL.add] = "DiffAdd",
	[M.HL.delete_text] = "DiffText",
	[M.HL.add_text] = "DiffText",
	[M.HL.filler] = "NonText",
	[M.HL.note] = "Comment",
}

-- Priorities: line backgrounds lowest, then syntax (the treesitter default),
-- then the changed-word background, which must win over the line one.
local LINE_PRIORITY = 50
local SYNTAX_PRIORITY = 100
local INLINE_PRIORITY = 150

----------------------------------------------------------------
-- Pure helpers
----------------------------------------------------------------

--- Header text of a file block.
--- @param file table changed-file entry { path, previous_path?, status, additions?, deletions? }
--- @return string
function M.format_file_header(file)
	local label = M.STATUS_LABELS[file.status] or "?"
	local path = file.path
	if file.previous_path and file.previous_path ~= file.path then
		path = file.previous_path .. " → " .. file.path
	end
	return string.format("%s %s  +%d -%d", label, path, tonumber(file.additions) or 0, tonumber(file.deletions) or 0)
end

--- Rows of one file's unified patch, both sides aligned. Removed lines are
--- paired with the added lines that follow them, row by row; the shorter side
--- of a pair gets nil (a filler row). `lnum` is the head-side line a row jumps
--- to: its own new line, or for a deletion the new line right after it.
--- @param patch string|nil unified diff hunks (GitHub `patch` / `git diff` body)
--- @return table[] rows { kind = "hunk"|"context"|"change", left?, right?, old_lnum?, new_lnum?, lnum }
function M.parse_patch_rows(patch)
	local rows = {}
	if type(patch) ~= "string" then
		return rows
	end
	local old_lnum, new_lnum
	local dels, adds = {}, {}

	local function flush()
		for i = 1, math.max(#dels, #adds) do
			local d, a = dels[i], adds[i]
			table.insert(rows, {
				kind = "change",
				left = d and d.text,
				right = a and a.text,
				old_lnum = d and d.lnum,
				new_lnum = a and a.lnum,
				lnum = a and a.lnum or (d and d.anchor),
			})
		end
		dels, adds = {}, {}
	end

	for line in (patch .. "\n"):gmatch("(.-)\r?\n") do
		local old_start, new_start = line:match("^@@%s+%-(%d+),?%d*%s+%+(%d+),?%d*%s+@@")
		if old_start then
			flush()
			old_lnum, new_lnum = tonumber(old_start), tonumber(new_start)
			table.insert(rows, { kind = "hunk", left = line, right = line, lnum = math.max(new_lnum, 1) })
		elseif old_lnum then
			local prefix, text = line:sub(1, 1), line:sub(2)
			if prefix == "-" then
				-- A removal after additions starts a new pair block.
				if #adds > 0 then
					flush()
				end
				table.insert(dels, { text = text, lnum = old_lnum, anchor = math.max(new_lnum, 1) })
				old_lnum = old_lnum + 1
			elseif prefix == "+" then
				table.insert(adds, { text = text, lnum = new_lnum })
				new_lnum = new_lnum + 1
			elseif prefix == " " then
				flush()
				table.insert(rows, {
					kind = "context",
					left = text,
					right = text,
					old_lnum = old_lnum,
					new_lnum = new_lnum,
					lnum = new_lnum,
				})
				old_lnum, new_lnum = old_lnum + 1, new_lnum + 1
			end
			-- "\ No newline at end of file" and trailing blank lines are skipped.
		end
	end
	flush()
	return rows
end

--- Rows of every file, each file starting with a header row and separated by a
--- blank row. Every row carries `file_index`; a file without a patch gets one
--- note row.
--- @param files table[] changed-file entries with a resolved `patch`
--- @return table[] rows
--- @return table[] ranges per file { first, last } (1-based row indices)
function M.build_rows(files)
	local rows, ranges = {}, {}
	for i, file in ipairs(files) do
		if i > 1 then
			table.insert(rows, { kind = "blank", left = "", right = "", file_index = i - 1 })
		end
		local first = #rows + 1
		local body = M.parse_patch_rows(file.patch)
		local header = M.format_file_header(file)
		local first_hunk = body[1]
		table.insert(rows, {
			kind = "file",
			left = header,
			right = header,
			file_index = i,
			lnum = first_hunk and first_hunk.lnum or 1,
		})
		if #body == 0 then
			table.insert(rows, { kind = "note", left = M.NO_DIFF_TEXT, right = M.NO_DIFF_TEXT, file_index = i, lnum = 1 })
		end
		for _, row in ipairs(body) do
			row.file_index = i
			table.insert(rows, row)
		end
		ranges[i] = { first = first, last = #rows }
	end
	return rows, ranges
end

--- Buffer lines of each side. A filler row is an empty line.
--- @param rows table[]
--- @return string[] left
--- @return string[] right
function M.build_buffer_lines(rows)
	local left, right = {}, {}
	for i, row in ipairs(rows) do
		left[i] = row.left or ""
		right[i] = row.right or ""
	end
	return left, right
end

--- Line highlight of a row on each side, and whether that side is a filler.
--- @param row table
--- @return string|nil left_hl
--- @return string|nil right_hl
--- @return boolean left_filler
--- @return boolean right_filler
function M.row_highlights(row)
	if row.kind == "file" then
		return M.HL.file, M.HL.file, false, false
	elseif row.kind == "hunk" then
		return M.HL.hunk, M.HL.hunk, false, false
	elseif row.kind == "note" then
		return M.HL.note, M.HL.note, false, false
	elseif row.kind == "change" then
		return row.left and M.HL.delete or nil, row.right and M.HL.add or nil, row.left == nil, row.right == nil
	end
	return nil, nil, false, false
end

--- Split a line into word, whitespace and single-punctuation tokens.
--- @param s string
--- @return table[] tokens { text, start } (start: 0-based byte column)
function M.tokenize(s)
	local tokens = {}
	local pos = 1
	while pos <= #s do
		local text = s:match("^[%w_]+", pos) or s:match("^%s+", pos) or s:match("^[\128-\255]+", pos) or s:sub(pos, pos)
		table.insert(tokens, { text = text, start = pos - 1 })
		pos = pos + #text
	end
	return tokens
end

local text_diff = (vim.text and vim.text.diff) or vim.diff

--- Changed parts of a removed/added line pair at token granularity. Returns
--- empty lists when the lines share no token, since the whole line is already
--- coloured and marking all of it adds nothing.
--- @param old string removed line
--- @param new string added line
--- @return table[] old_ranges { start_col, end_col } (0-based, end exclusive)
--- @return table[] new_ranges
function M.find_inline_ranges(old, new)
	if type(old) ~= "string" or type(new) ~= "string" or old == new or old == "" or new == "" then
		return {}, {}
	end
	local a, b = M.tokenize(old), M.tokenize(new)
	local function join(tokens)
		local texts = {}
		for i, t in ipairs(tokens) do
			texts[i] = t.text
		end
		return table.concat(texts, "\n") .. "\n"
	end
	local hunks = text_diff(join(a), join(b), { result_type = "indices" })
	if type(hunks) ~= "table" or #hunks == 0 then
		return {}, {}
	end
	if #hunks == 1 and hunks[1][1] <= 1 and hunks[1][2] == #a and hunks[1][3] <= 1 and hunks[1][4] == #b then
		return {}, {}
	end

	local function to_ranges(tokens, start, count, out)
		if count == 0 then
			return
		end
		local first, last = tokens[start], tokens[start + count - 1]
		local range = { first.start, last.start + #last.text }
		local prev = out[#out]
		if prev and prev[2] == range[1] then
			prev[2] = range[2]
		else
			table.insert(out, range)
		end
	end

	local old_ranges, new_ranges = {}, {}
	for _, h in ipairs(hunks) do
		to_ranges(a, h[1], h[2], old_ranges)
		to_ranges(b, h[3], h[4], new_ranges)
	end
	return old_ranges, new_ranges
end

--- The text of one side of one file, as a single source for a syntax parser,
--- and the buffer row of each of its lines. Header, hunk, note and filler rows
--- are left out so they do not confuse the parser.
--- @param rows table[]
--- @param range table { first, last }
--- @param side "left"|"right"
--- @return string source
--- @return integer[] row_map 1-based source line → 1-based buffer row
function M.build_syntax_source(rows, range, side)
	local lines, row_map = {}, {}
	for i = range.first, range.last do
		local row = rows[i]
		if (row.kind == "context" or row.kind == "change") and row[side] ~= nil then
			table.insert(lines, row[side])
			table.insert(row_map, i)
		end
	end
	return table.concat(lines, "\n"), row_map
end

--- Where <CR> on a row jumps: the file and the head-side line.
--- @param rows table[]
--- @param files table[]
--- @param index integer 1-based row
--- @return table|nil target { file, lnum }
--- @return string|nil reason when there is no target
function M.find_jump_target(rows, files, index)
	local row = rows[index]
	if not row or not row.file_index then
		return nil, "No file on this line"
	end
	if row.kind == "blank" then
		-- A separator belongs to the file above; jump to that file's header target.
		for i = index - 1, 1, -1 do
			if rows[i].kind == "file" then
				row = rows[i]
				break
			end
		end
	end
	local file = files[row.file_index]
	if not file then
		return nil, "No file on this line"
	end
	if file.status == "removed" then
		return nil, file.path .. " was removed"
	end
	return { file = file, lnum = math.max(row.lnum or 1, 1) }
end

--- Text of the line-number column for a row on one side.
--- @param row table|nil
--- @param side "left"|"right"
--- @param width integer
--- @return string
function M.format_line_number(row, side, width)
	local lnum
	if row then
		if side == "left" then
			lnum = row.old_lnum
		else
			lnum = row.new_lnum
		end
	end
	if not lnum then
		return string.rep(" ", width)
	end
	return string.format("%" .. width .. "d", lnum)
end

--- Width of the line-number column: the widest line number of either side.
--- @param rows table[]
--- @return integer
function M.calculate_number_width(rows)
	local max = 0
	for _, row in ipairs(rows) do
		max = math.max(max, row.old_lnum or 0, row.new_lnum or 0)
	end
	return math.max(#tostring(max), 2)
end

----------------------------------------------------------------
-- View
----------------------------------------------------------------

-- The open view, tied to the review session it was opened in:
-- { state, tab, origin_tab, left = { win, buf }, right = { win, buf },
--   files, rows, ranges, number_width, highlighted, augroup }
---@type table|nil
local view = nil

local function define_highlights()
	for name, link in pairs(HL_LINKS) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

local function is_open()
	return view ~= nil and vim.api.nvim_tabpage_is_valid(view.tab)
end

--- Whether the view is open (for tests and callers that only need to know).
function M.is_open()
	return is_open()
end

--- Files of the current scope with their patches resolved (local review
--- builds them with git on demand).
local function collect_files(state)
	local files_mod = require("fude.files")
	-- Local review entries carry no patch: read every tracked file's patch in
	-- one git diff rather than one process per file; files it does not cover
	-- (untracked ones) still go through resolve_patch.
	local batch = {}
	local session = state.local_session
	if state.review_mode == "local" and session and session.base_sha then
		batch = require("fude.diff").get_review_patches(session.base_sha, session.worktree_root) or {}
	end
	local files = {}
	for _, entry in ipairs(state.changed_files or {}) do
		local ok, patch = true, batch[entry.path]
		if not patch then
			ok, patch = pcall(files_mod.resolve_patch, entry)
		end
		local file = vim.tbl_extend("force", {}, entry)
		file.patch = ok and patch or ""
		table.insert(files, file)
	end
	return files
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

local function apply_row_highlights(rows)
	for _, side in ipairs({ "left", "right" }) do
		local buf = view[side].buf
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, syntax_ns, 0, -1)
	end
	for i, row in ipairs(rows) do
		local left_hl, right_hl, left_filler, right_filler = M.row_highlights(row)
		for side, spec in pairs({
			left = { hl = left_hl, filler = left_filler },
			right = { hl = right_hl, filler = right_filler },
		}) do
			local buf = view[side].buf
			if spec.hl then
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = spec.hl, priority = LINE_PRIORITY })
			end
			if spec.filler then
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
					virt_text = { { string.rep(M.FILLER_CHAR, vim.o.columns), M.HL.filler } },
					virt_text_pos = "overlay",
					priority = LINE_PRIORITY,
				})
			end
		end
		if row.kind == "change" and row.left and row.right then
			local old_ranges, new_ranges = M.find_inline_ranges(row.left, row.right)
			for _, r in ipairs(old_ranges) do
				vim.api.nvim_buf_set_extmark(view.left.buf, ns, i - 1, r[1], {
					end_col = r[2],
					hl_group = M.HL.delete_text,
					priority = INLINE_PRIORITY,
				})
			end
			for _, r in ipairs(new_ranges) do
				vim.api.nvim_buf_set_extmark(view.right.buf, ns, i - 1, r[1], {
					end_col = r[2],
					hl_group = M.HL.add_text,
					priority = INLINE_PRIORITY,
				})
			end
		end
	end
end

--- Treesitter language of a path, or nil without a parser.
local function find_lang(path)
	local ft = vim.filetype.match({ filename = path })
	if not ft then
		return nil
	end
	local lang = vim.treesitter.language.get_lang(ft) or ft
	-- language.add reports a missing parser by error (0.10) or by its result
	-- (0.11+); inspect answers only for a loaded parser either way.
	pcall(vim.treesitter.language.add, lang)
	if not pcall(vim.treesitter.language.inspect, lang) then
		return nil
	end
	return lang
end

local function highlight_source(buf, source, row_map, lang)
	if source == "" then
		return
	end
	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, lang)
	if not ok_parser or not parser then
		return
	end
	local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
	if not ok_query or not query then
		return
	end
	local ok_tree, trees = pcall(parser.parse, parser)
	if not ok_tree or not trees or not trees[1] then
		return
	end
	local source_lines = vim.split(source, "\n", { plain = true })
	for id, node, metadata in query:iter_captures(trees[1]:root(), source, 0, -1) do
		local name = query.captures[id]
		if name and name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
			local hl = "@" .. name .. "." .. lang
			local priority = SYNTAX_PRIORITY + (tonumber(metadata and metadata.priority) or 0)
			local sr, sc, er, ec = node:range()
			for r = sr, er do
				local buf_row = row_map[r + 1]
				local text = source_lines[r + 1]
				if buf_row and text then
					local s = r == sr and sc or 0
					local e = r == er and math.min(ec, #text) or #text
					if e > s then
						pcall(vim.api.nvim_buf_set_extmark, buf, syntax_ns, buf_row - 1, s, {
							end_col = e,
							hl_group = hl,
							priority = priority,
						})
					end
				end
			end
		end
	end
end

--- Syntax-highlight every not yet highlighted file that intersects the rows on
--- screen. Done lazily so a large PR opens without parsing every file first.
local function highlight_visible()
	if not is_open() or not vim.api.nvim_win_is_valid(view.right.win) then
		return
	end
	local top = vim.fn.line("w0", view.right.win)
	local bottom = vim.fn.line("w$", view.right.win)
	for i, range in ipairs(view.ranges) do
		if not view.highlighted[i] and range.last >= top and range.first <= bottom then
			view.highlighted[i] = true
			local lang = find_lang(view.files[i].path)
			if lang then
				for _, side in ipairs({ "left", "right" }) do
					local source, row_map = M.build_syntax_source(view.rows, range, side)
					highlight_source(view[side].buf, source, row_map, lang)
				end
			end
		end
	end
end

--- Render the current scope's files into the open view.
local function render(state)
	local files = collect_files(state)
	local rows, ranges = M.build_rows(files)
	if #rows == 0 then
		rows = { { kind = "note", left = "No changed files", right = "No changed files" } }
		ranges = {}
	end
	view.files, view.rows, view.ranges = files, rows, ranges
	view.number_width = M.calculate_number_width(rows)
	view.highlighted = {}
	local left, right = M.build_buffer_lines(rows)
	set_lines(view.left.buf, left)
	set_lines(view.right.buf, right)
	apply_row_highlights(rows)
	for _, side in ipairs({ "left", "right" }) do
		local win = view[side].win
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_option_value("numberwidth", view.number_width + 2, { win = win, scope = "local" })
		end
	end
	highlight_visible()
end

--- statuscolumn: each side's own line numbers (old on the left, new on the right).
function M.statuscolumn()
	local win = vim.g.statusline_winid
	local side = view and ((view.left.win == win and "left") or (view.right.win == win and "right")) or nil
	-- Another buffer opened in a view window gets ordinary line numbers.
	if not side or vim.api.nvim_win_get_buf(win) ~= view[side].buf then
		return "%l "
	end
	if vim.v.virtnum ~= 0 then
		return ""
	end
	return "%#LineNr#" .. M.format_line_number(view.rows[vim.v.lnum], side, view.number_width) .. " "
end

local WIN_OPTIONS = {
	wrap = false,
	scrollbind = true,
	cursorbind = true,
	number = true,
	relativenumber = false,
	signcolumn = "no",
	foldenable = false,
	foldcolumn = "0",
	list = false,
	spell = false,
	cursorline = true,
	statuscolumn = "%!v:lua.require'fude.all_diffs'.statuscolumn()",
}

--- Give windows that outlive the view (its tab could not be closed) the
--- global values of the options the view set, so they stop scrolling together
--- and get their normal gutter back.
local function reset_window_options(win)
	for name in pairs(WIN_OPTIONS) do
		vim.api.nvim_set_option_value(name, vim.api.nvim_get_option_value(name, { scope = "global" }), {
			win = win,
			scope = "local",
		})
	end
	for _, name in ipairs({ "winbar", "numberwidth" }) do
		vim.api.nvim_set_option_value(name, vim.api.nvim_get_option_value(name, { scope = "global" }), {
			win = win,
			scope = "local",
		})
	end
end

--- Close the view (no-op when closed).
function M.close()
	if not view then
		return
	end
	local v = view
	view = nil
	pcall(vim.api.nvim_del_augroup_by_id, v.augroup)
	if vim.api.nvim_tabpage_is_valid(v.tab) and #vim.api.nvim_list_tabpages() > 1 then
		pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(v.tab))
	end
	for _, side in ipairs({ "left", "right" }) do
		if vim.api.nvim_win_is_valid(v[side].win) then
			reset_window_options(v[side].win)
		end
		if vim.api.nvim_buf_is_valid(v[side].buf) then
			pcall(vim.api.nvim_buf_delete, v[side].buf, { force = true })
		end
	end
end

--- Whether the view still belongs to the active review session.
local function ensure_session()
	if view and view.state == config.state and config.state.active then
		return true
	end
	vim.notify("fude.nvim: The review session of this diff view has ended", vim.log.levels.WARN)
	return false
end

--- A window of `tab` that can show a source file: not the side panel, the
--- preview, a float, or a special buffer.
local function find_source_window(tab, state)
	local panel_win = state.sidepanel and state.sidepanel.win
	local candidates = { vim.api.nvim_tabpage_get_win(tab) }
	vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(tab))
	for _, win in ipairs(candidates) do
		if
			win ~= panel_win
			and win ~= state.preview_win
			and vim.api.nvim_win_get_config(win).relative == ""
			and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
		then
			return win
		end
	end
	return nil
end

--- Open the file of the cursor row at its line in the review tab.
function M.jump()
	if not is_open() or not ensure_session() then
		return
	end
	local state = view.state
	local index = vim.api.nvim_win_get_cursor(0)[1]
	local target, reason = M.find_jump_target(view.rows, view.files, index)
	if not target then
		vim.notify("fude.nvim: " .. reason, vim.log.levels.INFO)
		return
	end
	local root = require("fude.diff").get_repo_root()
	if not root then
		vim.notify("fude.nvim: Not in a git repository", vim.log.levels.WARN)
		return
	end

	local tab = view.origin_tab
	if not vim.api.nvim_tabpage_is_valid(tab) or tab == view.tab then
		tab = nil
		for _, t in ipairs(vim.api.nvim_list_tabpages()) do
			if t ~= view.tab then
				tab = t
				break
			end
		end
	end
	if not tab then
		vim.cmd("tabnew")
		tab = vim.api.nvim_get_current_tabpage()
		view.origin_tab = tab
	end
	local win = find_source_window(tab, state)
	vim.api.nvim_set_current_tabpage(tab)
	if not win then
		vim.cmd("vsplit")
		win = vim.api.nvim_get_current_win()
		vim.cmd("enew")
	end
	vim.api.nvim_set_current_win(win)

	local entry = target.file
	for _, f in ipairs(state.changed_files or {}) do
		if f.path == target.file.path then
			entry = f
			break
		end
	end
	local ok, err = pcall(require("fude.files").open_file, root .. "/" .. entry.path, entry)
	if not ok then
		vim.notify("fude.nvim: Could not open " .. entry.path .. ": " .. tostring(err), vim.log.levels.WARN)
		return
	end
	local cur = vim.api.nvim_get_current_win()
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(cur))
	vim.api.nvim_win_set_cursor(cur, { math.min(target.lnum, last), 0 })
	vim.cmd("normal! zz")
end

--- Rebuild the view from the current scope, keeping the cursor row.
function M.refresh()
	if not is_open() or not ensure_session() then
		return
	end
	local cursor = vim.api.nvim_win_is_valid(view.right.win) and vim.api.nvim_win_get_cursor(view.right.win)[1] or 1
	render(view.state)
	local last = #view.rows
	for _, side in ipairs({ "left", "right" }) do
		if vim.api.nvim_win_is_valid(view[side].win) then
			vim.api.nvim_win_set_cursor(view[side].win, { math.min(cursor, last), 0 })
		end
	end
	highlight_visible()
end

local function new_buffer(name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "fude_all_diffs"
	pcall(vim.api.nvim_buf_set_name, buf, name)
	return buf
end

local function setup_window(win, winbar)
	for name, value in pairs(WIN_OPTIONS) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
	vim.api.nvim_set_option_value("winbar", winbar, { win = win, scope = "local" })
end

local function setup_keymaps(buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("<CR>", M.jump, "fude: Open this line in the review tab")
	map("R", M.refresh, "fude: Rebuild the diff view")
	map("q", M.close, "fude: Close the diff view")
end

--- Open the view in a new tabpage, or focus and rebuild an open one.
function M.open()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if is_open() and view.state == state then
		vim.api.nvim_set_current_tabpage(view.tab)
		M.refresh()
		return
	end
	-- A view of an earlier session (or one whose tab is gone) is replaced.
	M.close()
	define_highlights()

	local origin_tab = vim.api.nvim_get_current_tabpage()
	local left_buf = new_buffer("fude://all-diffs/base")
	local right_buf = new_buffer("fude://all-diffs/head")
	vim.cmd("tab sbuffer " .. left_buf)
	local left_win = vim.api.nvim_get_current_win()
	vim.cmd("rightbelow vertical sbuffer " .. right_buf)
	local right_win = vim.api.nvim_get_current_win()

	view = {
		state = state,
		tab = vim.api.nvim_get_current_tabpage(),
		origin_tab = origin_tab,
		left = { win = left_win, buf = left_buf },
		right = { win = right_win, buf = right_buf },
		augroup = vim.api.nvim_create_augroup("FudeAllDiffs", { clear = true }),
	}
	setup_window(left_win, " Base")
	setup_window(right_win, " Head")
	setup_keymaps(left_buf)
	setup_keymaps(right_buf)
	render(state)
	vim.cmd("syncbind")

	-- Closing one side would leave the other unaligned and alone: close both.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = view.augroup,
		pattern = { tostring(left_win), tostring(right_win) },
		callback = function()
			vim.schedule(M.close)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
		group = view.augroup,
		callback = function()
			highlight_visible()
		end,
	})
end

return M
