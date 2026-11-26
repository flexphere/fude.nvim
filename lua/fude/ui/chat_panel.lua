--- AI chat panel for review mode: a vertical split at the tabpage edge with
--- the conversation log on top (read-only, markdown) and the input below.
--- Drives `chat.lua` (session, storage, claude process) and only renders.
---
--- State lives in `config.state`: `chat_panel` (windows and buffers),
--- `chat_live` (the exchange being answered — kept apart from the panel so an
--- answer keeps streaming into a panel closed and reopened meanwhile) and
--- `chat_input` (unsent input kept while the panel is closed).
local M = {}
local config = require("fude.config")
local chat = require("fude.chat")
local data = require("fude.chat.data")

-- Progress line (spinner + activity), drawn as an extmark so the log buffer's
-- text does not change on every frame.
local progress_ns = vim.api.nvim_create_namespace("fude_chat_progress")

--- Height of the input pane in lines (less on a short screen).
M.INPUT_HEIGHT = 8
--- Activity shown while claude has not said what it is doing.
M.THINKING_TEXT = "Thinking…"

local OPPOSITE_SPLIT = { left = "right", right = "left" }

-- Window-local options of both panes.
local PANE_WIN_OPTIONS = {
	number = false,
	relativenumber = false,
	signcolumn = "no",
	foldcolumn = "0",
	wrap = true,
	linebreak = true,
	spell = false,
	list = false,
	cursorline = false,
}

--- Why `chat.send` refused, as shown to the user.
local SEND_ERRORS = {
	[chat.ERR_BUSY] = "claude is still answering",
	[chat.ERR_EMPTY] = "the question is empty",
	[chat.ERR_NO_TARGET] = "no review target",
	[chat.ERR_NO_ROOT] = "the repository root was not found",
}

-- === Panel lookup ===

--- Whether a window is still open on the pane buffer it was created for.
--- 'winfixbuf' keeps the buffers in place, but a forced command (`:buffer!`)
--- can still replace one: such a window is the user's then, not a pane.
--- @param win number
--- @param buf number
--- @return boolean
local function shows(win, buf)
	return vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_get_buf(win) == buf
end

--- The open panel, or nil when it is closed or one of its parts is gone.
--- @return table|nil
local function get_panel()
	local panel = config.state.chat_panel
	if panel and shows(panel.log_win, panel.log_buf) and shows(panel.input_win, panel.input_buf) then
		return panel
	end
	return nil
end

--- Whether a window is one of the chat panel's two panes. Used by the side
--- panel and the file navigation, which must not treat them as editor windows.
--- @param win number|nil
--- @return boolean
function M.is_panel_window(win)
	local panel = config.state.chat_panel
	if not panel or not win then
		return false
	end
	return (win == panel.log_win and shows(win, panel.log_buf))
		or (win == panel.input_win and shows(win, panel.input_buf))
end

--- The tabpage the open panel is in. The side panel uses it to tell whether
--- the two panels share a tabpage (only then do they share its last window).
--- @return number|nil
function M.tabpage()
	local panel = get_panel()
	return panel and vim.api.nvim_win_get_tabpage(panel.log_win) or nil
end

--- Give the open panel the width it was opened with (the two panes share
--- one column). Used after an editor window was opened beside panes that had
--- grown: `winfixwidth` only protects a size from later changes.
function M.restore_width()
	local panel = get_panel()
	if panel then
		pcall(vim.api.nvim_win_set_width, panel.log_win, panel.width)
	end
end

--- Whether the panel is open.
--- @return boolean
function M.is_open()
	return get_panel() ~= nil
end

-- === Log buffer ===

--- Whether the log window looks at the end of the log: its cursor is on the
--- last line. New output scrolls the window only then.
--- @param panel table
--- @return boolean
local function is_at_end(panel)
	return vim.api.nvim_win_get_cursor(panel.log_win)[1] >= vim.api.nvim_buf_line_count(panel.log_buf)
end

--- Move the log window to the end of the log.
--- @param panel table
local function scroll_to_end(panel)
	local last = vim.api.nvim_buf_line_count(panel.log_buf)
	pcall(vim.api.nvim_win_set_cursor, panel.log_win, { last, 0 })
end

--- Change the read-only log buffer.
--- @param panel table
--- @param first number 0-based start (as nvim_buf_set_lines)
--- @param last number 0-based end, exclusive
--- @param lines string[]
local function set_log_lines(panel, first, last, lines)
	vim.bo[panel.log_buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.log_buf, first, last, false, lines)
	vim.bo[panel.log_buf].modifiable = false
end

--- @param panel table
--- @return string the log's last line
local function last_log_line(panel)
	return vim.api.nvim_buf_get_lines(panel.log_buf, -2, -1, false)[1] or ""
end

--- Draw the progress line at the end of the log, or remove it when nothing
--- is being answered.
--- @param panel table
local function draw_progress(panel)
	vim.api.nvim_buf_clear_namespace(panel.log_buf, progress_ns, 0, -1)
	local live = config.state.chat_live
	if not live then
		return
	end
	local toggle_picker = require("fude.ui.toggle_picker")
	local mark = toggle_picker.format_loading_mark(panel.frame or 1)
	local gap = last_log_line(panel) == "" and "" or " "
	pcall(vim.api.nvim_buf_set_extmark, panel.log_buf, progress_ns, vim.api.nvim_buf_line_count(panel.log_buf) - 1, 0, {
		virt_text = {
			{ gap .. mark, toggle_picker.LOADING_HL },
			{ " " .. (live.activity or M.THINKING_TEXT), "Comment" },
		},
		virt_text_pos = "eol",
	})
end

--- Change the log and keep the view: follow the end when the window was
--- looking at it, stay put otherwise. The progress line moves with the end.
--- @param panel table
--- @param change fun()
local function update_log(panel, change)
	local follow = is_at_end(panel)
	change()
	if follow then
		scroll_to_end(panel)
	end
	draw_progress(panel)
end

--- Add lines after the log's last line (an empty log is replaced).
--- @param panel table
--- @param lines string[]
local function append_lines(panel, lines)
	local count = vim.api.nvim_buf_line_count(panel.log_buf)
	if count == 1 and last_log_line(panel) == "" then
		set_log_lines(panel, 0, -1, lines)
	else
		set_log_lines(panel, count, count, lines)
	end
end

--- Continue the log's last line with a piece of text (which may hold newlines).
--- @param panel table
--- @param text string
local function append_text(panel, text)
	local pieces = vim.split((text:gsub("\r\n?", "\n")), "\n", { plain = true })
	pieces[1] = last_log_line(panel) .. pieces[1]
	set_log_lines(panel, -2, -1, pieces)
end

--- Stop the progress timer.
--- @param panel table
local function stop_progress(panel)
	if panel.stop_spinner then
		panel.stop_spinner()
		panel.stop_spinner = nil
	end
	if vim.api.nvim_buf_is_valid(panel.log_buf) then
		vim.api.nvim_buf_clear_namespace(panel.log_buf, progress_ns, 0, -1)
	end
end

--- Start the progress timer while an answer is in flight (no-op when running).
--- @param panel table
local function start_progress(panel)
	if panel.stop_spinner or not config.state.chat_live then
		return
	end
	panel.frame = 1
	panel.stop_spinner = require("fude.ui").start_spinner(function(frame)
		-- The panel was closed, or the answer ended, without stopping the timer.
		if config.state.chat_panel ~= panel or not get_panel() or not config.state.chat_live then
			stop_progress(panel)
			return
		end
		panel.frame = frame
		draw_progress(panel)
	end)
	draw_progress(panel)
end

--- Fill the log from the stored conversation, plus the exchange in flight.
--- @param panel table
local function render_log(panel)
	local state = config.state
	local key = chat.current_key(state)
	local lines = data.format_chat_lines(chat.load(key).messages)
	-- An answer that ended while the session was replaced never reported back.
	local live = state.chat_live
	if live and not chat.is_running(live.key) then
		state.chat_live = nil
		live = nil
	end
	if #lines == 0 then
		lines = { "" }
	end
	set_log_lines(panel, 0, -1, lines)
	if live and live.key == key then
		append_lines(panel, data.format_question_lines(live.prompt))
		if live.text ~= "" then
			append_text(panel, live.text)
		end
	end
	scroll_to_end(panel)
	stop_progress(panel)
	start_progress(panel)
end

-- === Input buffer ===

--- @param lines string[]
--- @return boolean whether the lines hold nothing but whitespace
local function is_blank(lines)
	return vim.trim(table.concat(lines, "\n")) == ""
end

--- Copy the input pane's text to `state.chat_input`. The state is kept
--- current while the user types (autocmds in `open`) and after every change
--- the module makes, so the unsent question survives however the pane goes
--- away — `:q`, `:bwipeout`, `:only`, `:tabclose` — without relying on a
--- hand-over at close time, when the buffer may be wiped already.
--- @param panel table
local function sync_input(panel)
	if config.state.chat_panel ~= panel or not vim.api.nvim_buf_is_valid(panel.input_buf) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(panel.input_buf, 0, -1, false)
	config.state.chat_input = (not is_blank(lines)) and lines or nil
end

--- Put a question back in front of the unsent input (in the panel, or in the
--- lines kept for the next open), so a failed question is not lost.
--- @param prompt string
local function restore_input(prompt)
	local state = config.state
	local panel = get_panel()
	local existing = panel and vim.api.nvim_buf_get_lines(panel.input_buf, 0, -1, false) or state.chat_input or {}
	local lines = vim.split(prompt, "\n", { plain = true })
	if not is_blank(existing) then
		table.insert(lines, "")
		vim.list_extend(lines, existing)
	end
	if panel then
		vim.api.nvim_buf_set_lines(panel.input_buf, 0, -1, false, lines)
		sync_input(panel)
	else
		state.chat_input = lines
	end
end

-- === Answer handlers ===
-- chat.lua calls these only while the review session the question was asked
-- in is still the active one, so config.state is that session's state.

local handlers = {}

function handlers.on_text(text)
	local live = config.state.chat_live
	if not live then
		return
	end
	live.text = live.text .. text
	live.activity = nil
	local panel = get_panel()
	if panel then
		update_log(panel, function()
			append_text(panel, text)
		end)
	end
end

function handlers.on_tool(label)
	local live = config.state.chat_live
	if not live then
		return
	end
	live.activity = label
	local panel = get_panel()
	if panel then
		draw_progress(panel)
	end
end

function handlers.on_retry()
	-- The note about a new session arrives as answer text (and is stored with
	-- it); only the activity of the process that was replaced goes.
	local live = config.state.chat_live
	if not live then
		return
	end
	live.activity = nil
	local panel = get_panel()
	if panel then
		draw_progress(panel)
	end
end

function handlers.on_done(result)
	local state = config.state
	local live = state.chat_live
	state.chat_live = nil
	local panel = get_panel()
	if panel then
		stop_progress(panel)
		update_log(panel, function()
			local has_text = last_log_line(panel) ~= ""
			append_lines(panel, data.format_answer_end_lines(result.status, result.error, has_text))
		end)
	end
	-- A panel in another tabpage shows nothing to the user right now.
	local visible = panel ~= nil and vim.api.nvim_win_get_tabpage(panel.log_win) == vim.api.nvim_get_current_tabpage()
	if result.status == "error" then
		-- A failure stored with the conversation is in claude's session too:
		-- handing the question back would send it there a second time.
		if not result.stored then
			restore_input(result.prompt or (live and live.prompt) or "")
		end
		if not visible then
			vim.notify("fude.nvim: Chat failed: " .. tostring(result.error), vim.log.levels.ERROR)
		end
	elseif result.status == "done" and not visible then
		-- The panel was closed meanwhile: say when it is worth opening again.
		vim.notify("fude.nvim: The chat answer is ready (:FudeReviewChat)", vim.log.levels.INFO)
	end
	if result.save_error then
		vim.notify("fude.nvim: Could not save the chat: " .. tostring(result.save_error), vim.log.levels.WARN)
	end
end

-- === Actions ===

--- WARN and return false when the claude command cannot be run.
--- @return boolean
local function ensure_available()
	if chat.is_available() then
		return true
	end
	local cmd = (config.opts.chat or {}).cmd
	vim.notify(
		"fude.nvim: Chat needs the claude command (`" .. tostring(cmd) .. "` is not executable)",
		vim.log.levels.WARN
	)
	return false
end

--- WARN and return false outside review mode.
--- @return boolean
local function ensure_active()
	if config.state.active then
		return true
	end
	vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
	return false
end

--- Focus the input pane in insert mode, like the comment inputs: it is where
--- a command put the user to type. Not used for plain window movement.
--- @param panel table
local function focus_input(panel)
	vim.api.nvim_set_current_win(panel.input_win)
	-- Continue at the end of what is there: an unsent question restored into
	-- the pane, or one left with <Esc>, is appended to, not written into.
	local last = vim.api.nvim_buf_line_count(panel.input_buf)
	local line = vim.api.nvim_buf_get_lines(panel.input_buf, last - 1, last, false)[1] or ""
	pcall(vim.api.nvim_win_set_cursor, panel.input_win, { last, #line })
	vim.cmd("startinsert!")
end

--- Path to write for a selection in `buf`.
--- @param buf number
--- @return string|nil path nil for an unnamed buffer
--- @return boolean refused true when the buffer is not something to quote lines from
local function resolve_selection_path(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	-- The diff preview's base pane, named "[base] <path>": base-version lines.
	if buf == config.state.preview_buf then
		return data.format_base_path(name:match("%[base%] (.+)$")), false
	end
	-- A special buffer, named or not (side panel, comment browser, comment
	-- input, overview, terminal, …): nothing claude could read by a path.
	if vim.bo[buf].buftype ~= "" then
		return nil, true
	end
	if name == "" then
		return nil, false
	end
	-- Relative to the directory claude runs in (not to Neovim's cwd, which may
	-- be another worktree or repository after a :cd); outside it, the full
	-- path as the user would type it. Both sides resolved: buffer names have
	-- symlinks resolved while the root may not.
	local root = chat.current_root()
	local full = vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
	local rel = root and require("fude.diff").make_relative(full, vim.fn.resolve(root)) or nil
	if rel and rel ~= "" then
		return rel, false
	end
	return vim.fn.fnamemodify(name, ":~"), false
end

--- Send the input pane's text as a question.
function M.submit()
	local panel = get_panel()
	if not panel then
		return
	end
	local state = config.state
	if chat.is_running() then
		vim.notify("fude.nvim: claude is still answering", vim.log.levels.INFO)
		return
	end
	local prompt = vim.trim(table.concat(vim.api.nvim_buf_get_lines(panel.input_buf, 0, -1, false), "\n"))
	if prompt == "" then
		return
	end
	local key = chat.current_key(state)
	if not key then
		vim.notify("fude.nvim: No review target to chat about", vim.log.levels.WARN)
		return
	end

	state.chat_live = { key = key, prompt = prompt, text = "", activity = nil }
	append_lines(panel, data.format_question_lines(prompt))
	vim.api.nvim_buf_set_lines(panel.input_buf, 0, -1, false, { "" })
	sync_input(panel)
	scroll_to_end(panel)
	start_progress(panel)

	-- Stop claude when Neovim exits mid-answer, storing what arrived so far.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("fude_chat_exit", { clear = true }),
		once = true,
		callback = function()
			chat.cancel()
		end,
		desc = "fude.nvim: Stop the chat answer in progress",
	})

	local accepted, reason = chat.send(prompt, handlers)
	if not accepted then
		handlers.on_done({ status = "error", error = SEND_ERRORS[reason] or tostring(reason), prompt = prompt, text = "" })
	end
end

--- Stop the answer in progress; what arrived so far stays, marked as interrupted.
function M.cancel()
	if not chat.cancel() then
		vim.notify("fude.nvim: No chat answer in progress", vim.log.levels.INFO)
	end
end

--- Map the panel's keys from `chat.keymaps` (an entry set to false is left unmapped).
--- @param panel table
local function setup_keymaps(panel)
	local keymaps = (config.opts.chat or {}).keymaps
	if type(keymaps) ~= "table" then
		keymaps = {}
	end
	local function map(buf, lhs, fn, desc)
		if type(lhs) == "string" and lhs ~= "" then
			vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
		end
	end
	map(panel.input_buf, keymaps.submit, M.submit, "Send the question")
	for _, buf in ipairs({ panel.log_buf, panel.input_buf }) do
		map(buf, keymaps.cancel, M.cancel, "Stop the answer in progress")
		map(buf, keymaps.close, M.close, "Close the chat panel")
	end
end

--- Whether the chat panel's panes are the only non-floating windows left in
--- their tabpage.
--- @param panel table
--- @return boolean
local function is_alone(panel)
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(panel.log_win))) do
		if not M.is_panel_window(w) and vim.api.nvim_win_get_config(w).relative == "" then
			return false
		end
	end
	return true
end

--- Whether a window is the only non-floating window of its tabpage.
--- @param win number
--- @return boolean
local function is_last_in_tabpage(win)
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
		if w ~= win and vim.api.nvim_win_get_config(w).relative == "" then
			return false
		end
	end
	return true
end

--- Whether the side panel is open in the chat panel's tabpage.
--- @param panel table
--- @return boolean
local function shares_tabpage_with_sidepanel(panel)
	local side = config.state.sidepanel
	return side ~= nil
		and side.win ~= nil
		and vim.api.nvim_win_is_valid(side.win)
		and vim.api.nvim_win_get_tabpage(side.win) == vim.api.nvim_win_get_tabpage(panel.log_win)
end

--- Open an editor window beside the panel when the panel's panes are the
--- only windows left, so the next file does not open in a pane (the side
--- panel's rule). No-op otherwise.
--- @param panel table
local function ensure_editor_window(panel)
	if not get_panel() or not is_alone(panel) then
		return
	end
	local enter = M.is_panel_window(vim.api.nvim_get_current_win())
	-- `win = -1` means the current tabpage, which need not be the panel's by
	-- the time this scheduled work runs: open the window from inside a pane.
	vim.api.nvim_win_call(panel.log_win, function()
		panel.prev_win =
			require("fude.ui.sidepanel").open_editor_window({ split = OPPOSITE_SPLIT[panel.split], win = -1 }, false)
	end)
	if enter then
		vim.api.nvim_set_current_win(panel.prev_win)
	end
	-- The new window takes half of the tabpage the panes had grown into.
	M.restore_width()
end

--- A :quit closed the last editor window: let it reach Neovim (or close the
--- tabpage) as it would without the panel. When the quit is refused, the
--- panel is closed and an editor window takes its place.
--- @param panel table
local function quit_if_alone(panel)
	if not get_panel() or not is_alone(panel) then
		return
	end
	-- Leave one pane to quit from. The panel is gone either way: when the
	-- quit only closes the tabpage, nothing may keep pointing at its windows.
	sync_input(panel)
	stop_progress(panel)
	pcall(vim.api.nvim_del_augroup_by_id, panel.augroup)
	pcall(vim.cmd, "noautocmd call nvim_win_close(" .. panel.log_win .. ", v:true)")
	config.state.chat_panel = nil
	local input_win = panel.input_win
	local ok, err = pcall(function()
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("quit")
	end)
	if not ok then
		vim.notify("fude.nvim: " .. tostring(err), vim.log.levels.ERROR)
		if vim.api.nvim_win_is_valid(input_win) then
			-- From inside the pane: `win = -1` is the current tabpage's edge.
			vim.api.nvim_win_call(input_win, function()
				require("fude.ui.sidepanel").open_editor_window({ split = OPPOSITE_SPLIT[panel.split], win = -1 }, false)
			end)
			pcall(vim.cmd, "noautocmd call nvim_win_close(" .. input_win .. ", v:true)")
		end
	end
end

--- Open the chat panel at the tabpage edge and focus its input (insert mode).
function M.open()
	if not ensure_active() or not ensure_available() then
		return
	end
	local state = config.state
	M.close()

	local prev_win = vim.api.nvim_get_current_win()
	local opts = config.opts.chat or {}
	local split = data.find_panel_split(opts.position)

	local log_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[log_buf].buftype = "nofile"
	vim.bo[log_buf].bufhidden = "wipe"
	vim.bo[log_buf].modifiable = false
	local input_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[input_buf].buftype = "nofile"
	vim.bo[input_buf].bufhidden = "wipe"

	-- Top-level split: the panel sits at the tabpage edge whatever window is focused.
	local width = data.calculate_panel_width(opts.width, vim.o.columns)
	local log_win = vim.api.nvim_open_win(log_buf, true, { split = split, win = -1, width = width })
	local input_height = math.max(1, math.min(M.INPUT_HEIGHT, math.floor((vim.o.lines - vim.o.cmdheight) / 3)))
	local input_win = vim.api.nvim_open_win(input_buf, true, { split = "below", win = log_win, height = input_height })

	-- scope = "local": vim.wo[win] on the current window would also change the
	-- global values and leak into later windows.
	for _, win in ipairs({ log_win, input_win }) do
		for name, value in pairs(PANE_WIN_OPTIONS) do
			vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
		end
		vim.api.nvim_set_option_value("winfixwidth", true, { scope = "local", win = win })
		-- A file opened from a pane (:edit, a picker of another plugin) is refused
		-- (E1513) instead of replacing the pane and wiping the unsent question.
		if vim.fn.exists("+winfixbuf") == 1 then
			vim.api.nvim_set_option_value("winfixbuf", true, { scope = "local", win = win })
		end
	end
	vim.api.nvim_set_option_value("winfixheight", true, { scope = "local", win = input_win })

	pcall(vim.api.nvim_buf_set_name, log_buf, "[fude] Chat")
	pcall(vim.api.nvim_buf_set_name, input_buf, "[fude] Chat Input")
	vim.bo[log_buf].filetype = "markdown"
	vim.bo[input_buf].filetype = "markdown"

	local panel = {
		log_win = log_win,
		log_buf = log_buf,
		input_win = input_win,
		input_buf = input_buf,
		prev_win = prev_win,
		split = split,
		width = width,
	}
	state.chat_panel = panel

	-- state.chat_input stays the copy of the unsent input while the panel is open.
	if state.chat_input and not is_blank(state.chat_input) then
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, state.chat_input)
	end

	local augroup = vim.api.nvim_create_augroup("fude_chat_panel_" .. log_win, { clear = true })
	panel.augroup = augroup
	-- Keep state.chat_input current (see sync_input). BufUnload covers text
	-- changed without a TextChanged event yet when the buffer goes away.
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave", "BufUnload" }, {
		group = augroup,
		buffer = input_buf,
		callback = function()
			sync_input(panel)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == log_win or closed_win == input_win then
				-- One pane is useless without the other. Closing the current
				-- window from here would abort the command that closed the first
				-- pane (`:only` from a pane: E855), so that waits for it to end.
				local other = closed_win == log_win and input_win or log_win
				local current = vim.api.nvim_get_current_win()
				local current_buf = vim.api.nvim_win_get_buf(current)
				-- `<C-w>T` in a pane closes it after opening a new window on its
				-- buffer in a new tabpage, which is the current window by now.
				if current == other or current_buf == log_buf or current_buf == input_buf then
					-- The remaining pane as the current window is `:only` from a
					-- pane: the user asked to keep that window, so it must not
					-- take its tabpage with it.
					local keep = current == other
					vim.schedule(function()
						if config.state.chat_panel == panel then
							M.close({ keep_last_window = keep })
						end
					end)
				else
					M.close()
				end
				return
			end
			local quitting = closed_win == panel.quitting_win
			-- WinClosed fires before the window is gone, so look after it is.
			vim.schedule(function()
				-- With the side panel open, it reopens the editor window (or
				-- quits, closing this panel first): one of the two must own that.
				-- A side panel in another tabpage looks after that tabpage only.
				if config.state.chat_panel ~= panel or not get_panel() or shares_tabpage_with_sidepanel(panel) then
					return
				end
				if quitting then
					quit_if_alone(panel)
				else
					ensure_editor_window(panel)
				end
			end)
		end,
	})
	-- :quit/:wq/ZZ fire QuitPre; :bdelete and :close do not (see ui/sidepanel.lua).
	vim.api.nvim_create_autocmd("QuitPre", {
		group = augroup,
		callback = function()
			local cur = vim.api.nvim_get_current_win()
			if M.is_panel_window(cur) then
				return
			end
			panel.quitting_win = cur
			vim.schedule(function()
				if panel.quitting_win == cur then
					panel.quitting_win = nil
				end
			end)
		end,
	})

	setup_keymaps(panel)
	render_log(panel)
	focus_input(panel)
end

--- Close the chat panel. An answer in progress keeps running and is stored
--- when it ends; unsent input is kept for the next open. When a pane is the
--- current window, focus returns to the window the panel was opened or
--- focused from.
--- @param opts { keep_last_window: boolean|nil }|nil keep_last_window: a pane that is
---   the only window of its tabpage stays as an ordinary empty window instead
---   of closing the tabpage with it
function M.close(opts)
	local state = config.state
	local panel = state.chat_panel
	if not panel then
		return
	end
	if panel.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, panel.augroup)
	end
	stop_progress(panel)
	-- A last look while the buffer is there; when it is wiped already (the
	-- pane was closed with :q), state.chat_input holds what the autocmds saw.
	sync_input(panel)

	local was_focused = M.is_panel_window(vim.api.nvim_get_current_win())
	if was_focused then
		-- Insert mode belongs to the input pane, not to the window focus returns to.
		vim.cmd("stopinsert")
	end
	-- Every window on a pane buffer goes, not only the two the panel opened: a
	-- pane moved to another tabpage (`<C-w>T`) or split is a new window on the
	-- same buffer, and would stay behind without its panel.
	local seen = {}
	for _, buf in ipairs({ panel.log_buf, panel.input_buf }) do
		for _, win in ipairs(vim.api.nvim_buf_is_valid(buf) and vim.fn.win_findbuf(buf) or {}) do
			seen[win] = true
			local keep = opts and opts.keep_last_window and is_last_in_tabpage(win)
			local ok, err = true, nil
			if not keep then
				ok, err = pcall(vim.cmd, "noautocmd call nvim_win_close(" .. win .. ", v:true)")
			end
			if keep or (not ok and type(err) == "string" and err:find("Cannot close last window")) then
				-- The pane stays as the editor's last window (e.g. `:only` from a
				-- pane): it must not keep the pane's options, size and buffer pins.
				require("fude.ui.sidepanel").reset_window_options(win)
				vim.api.nvim_win_call(win, function()
					pcall(vim.cmd, "enew")
				end)
			end
		end
	end
	-- A window whose buffer was replaced by force is not a pane any more: it
	-- stays open, as an ordinary window.
	for _, win in ipairs({ panel.log_win, panel.input_win }) do
		if not seen[win] and vim.api.nvim_win_is_valid(win) then
			require("fude.ui.sidepanel").reset_window_options(win)
		end
	end
	state.chat_panel = nil

	-- Without noautocmd, so BufEnter re-syncs the review state of that window.
	if was_focused and panel.prev_win and vim.api.nvim_win_is_valid(panel.prev_win) then
		pcall(vim.api.nvim_set_current_win, panel.prev_win)
	end
end

--- Toggle the chat panel like the side panel: open it when closed, focus its
--- input when it is open but another window is focused, close it when one of
--- its panes is the current window. A panel in another tabpage is reopened
--- in the current one.
function M.toggle()
	if not ensure_active() or not ensure_available() then
		return
	end
	local panel = get_panel()
	if not panel then
		M.open()
	elseif vim.api.nvim_win_get_tabpage(panel.log_win) ~= vim.api.nvim_get_current_tabpage() then
		M.open()
	elseif M.is_panel_window(vim.api.nvim_get_current_win()) then
		M.close()
	else
		panel.prev_win = vim.api.nvim_get_current_win()
		focus_input(panel)
	end
end

--- Discard the review target's claude session and conversation; the next
--- question starts a new session. An answer in progress is stopped first.
function M.new_chat()
	if not ensure_active() or not ensure_available() then
		return
	end
	local state = config.state
	local key = chat.current_key(state)
	if not key then
		vim.notify("fude.nvim: No review target to chat about", vim.log.levels.WARN)
		return
	end
	local ok, err = chat.discard(key)
	state.chat_live = nil
	local panel = get_panel()
	if panel then
		render_log(panel)
	end
	if not ok then
		vim.notify("fude.nvim: Could not discard the chat: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify("fude.nvim: Started a new chat", vim.log.levels.INFO)
end

--- Append lines `line1`..`line2` of the current buffer to the chat input as
--- a `<path>:L<start>-L<end>` line and a code fence, opening the panel when
--- it is closed and focusing the input. Existing input is kept.
--- @param line1 number 1-based first line
--- @param line2 number 1-based last line
function M.add_selection(line1, line2)
	if not ensure_active() or not ensure_available() then
		return
	end
	local source_win = vim.api.nvim_get_current_win()
	if M.is_panel_window(source_win) then
		vim.notify("fude.nvim: Select lines in a file, not in the chat panel", vim.log.levels.WARN)
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	if line1 > line2 then
		line1, line2 = line2, line1
	end
	local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
	local path, refused = resolve_selection_path(buf)
	if refused then
		vim.notify("fude.nvim: This buffer is not a file to quote lines from", vim.log.levels.WARN)
		return
	end
	local text = data.build_selection_text(path, line1, line2, lines, vim.bo[buf].filetype)

	local panel = get_panel()
	if not panel or vim.api.nvim_win_get_tabpage(panel.log_win) ~= vim.api.nvim_get_current_tabpage() then
		M.open()
		panel = get_panel()
		if not panel then
			return
		end
	else
		panel.prev_win = source_win
	end

	local existing = vim.api.nvim_buf_get_lines(panel.input_buf, 0, -1, false)
	local new_lines = {}
	if not is_blank(existing) then
		-- Drop trailing blank lines, then one blank line before the block.
		while #existing > 0 and vim.trim(existing[#existing]) == "" do
			table.remove(existing)
		end
		vim.list_extend(new_lines, existing)
		table.insert(new_lines, "")
	end
	vim.list_extend(new_lines, text)
	-- A line to type the question on.
	table.insert(new_lines, "")
	vim.api.nvim_buf_set_lines(panel.input_buf, 0, -1, false, new_lines)
	sync_input(panel)
	focus_input(panel)
	pcall(vim.api.nvim_win_set_cursor, panel.input_win, { #new_lines, 0 })
end

--- Review stop: stop the answer in progress (what arrived is stored) and
--- close the panel. Called before `config.reset_state()`.
function M.teardown()
	chat.cancel()
	M.close()
	config.state.chat_live = nil
	config.state.chat_input = nil
	pcall(vim.api.nvim_del_augroup_by_name, "fude_chat_exit")
end

return M
