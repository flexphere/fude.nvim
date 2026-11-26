local helpers = require("tests.helpers")
local chat = require("fude.chat")
local data = require("fude.chat.data")
local chat_panel = require("fude.ui.chat_panel")
local sidepanel = require("fude.ui.sidepanel")
local config = require("fude.config")

local ID = "0b0e6f1c-7a52-4c1e-9d3a-5f6a7b8c9d01"
local KEY = "o/r:#7:chat"

local function text_line(text)
	return vim.json.encode({
		type = "stream_event",
		event = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } },
		parent_tool_use_id = vim.NIL,
	}) .. "\n"
end

local function tool_line(name, input)
	return vim.json.encode({
		type = "assistant",
		message = { content = { { type = "tool_use", id = "toolu_1", name = name, input = input } } },
		parent_tool_use_id = vim.NIL,
	}) .. "\n"
end

local function success_line(text)
	return vim.json.encode({ type = "result", subtype = "success", is_error = false, result = text }) .. "\n"
end

describe("chat.format_question_lines", function()
	it("puts the question under its heading and ends on the answer's empty first line", function()
		assert.are.same(
			{ "## You", "", "why?", "really", "", "## Claude", "", "" },
			data.format_question_lines("why?\nreally\n")
		)
	end)
end)

describe("chat.format_answer_end_lines", function()
	it("ends a finished answer with a blank line", function()
		assert.are.same({ "" }, data.format_answer_end_lines("done", nil, true))
	end)

	it("marks an interrupted answer, after a blank line when there is text", function()
		assert.are.same({ "", data.CANCELLED_MARK, "" }, data.format_answer_end_lines("cancelled", nil, true))
		assert.are.same({ data.CANCELLED_MARK, "" }, data.format_answer_end_lines("cancelled", nil, false))
	end)

	it("shows every line of an error", function()
		assert.are.same(
			{ "", "**Error:** API Error: 529", "overloaded", "" },
			data.format_answer_end_lines("error", "API Error: 529\noverloaded\n", true)
		)
		assert.are.same({ "**Error:** unknown error", "" }, data.format_answer_end_lines("error", nil, false))
	end)
end)

describe("chat.format_chat_lines", function()
	it("renders stored questions and answers in order", function()
		local lines = data.format_chat_lines({
			data.build_message("user", "q1"),
			data.build_message("assistant", "a1\nmore", "done"),
			data.build_message("user", "q2"),
			data.build_message("assistant", "part", "cancelled"),
		})
		assert.are.same({
			"## You",
			"",
			"q1",
			"",
			"## Claude",
			"",
			"a1",
			"more",
			"",
			"## You",
			"",
			"q2",
			"",
			"## Claude",
			"",
			"part",
			"",
			data.CANCELLED_MARK,
			"",
		}, lines)
	end)

	it("marks an answer interrupted before any text", function()
		local lines = data.format_chat_lines({
			data.build_message("user", "q"),
			data.build_message("assistant", "", "cancelled"),
		})
		assert.are.same({ "## You", "", "q", "", "## Claude", "", "", data.CANCELLED_MARK, "" }, lines)
	end)

	it("returns no lines for an empty conversation", function()
		assert.are.same({}, data.format_chat_lines({}))
		assert.are.same({}, data.format_chat_lines(nil))
	end)
end)

describe("chat.build_selection_text", function()
	it("heads a range with path:Lstart-Lend and fences the lines with the filetype", function()
		assert.are.same(
			{ "lua/fude/foo.lua:L10-L11", "```lua", "local a = 1", "return a", "```" },
			data.build_selection_text("lua/fude/foo.lua", 10, 11, { "local a = 1", "return a" }, "lua")
		)
	end)

	it("writes a single line as path:Lline", function()
		assert.are.same(
			{ "a.py:L3", "```python", "x = 1", "```" },
			data.build_selection_text("a.py", 3, 3, { "x = 1" }, "python")
		)
	end)

	it("orders a reversed range", function()
		assert.are.equal("a.py:L2-L5", data.build_selection_text("a.py", 5, 2, { "x" }, "python")[1])
	end)

	it("uses a fence longer than any backtick run in the selection", function()
		local text = data.build_selection_text("README.md", 1, 3, { "```lua", "x ````` y", "```" }, "markdown")
		assert.are.equal("``````markdown", text[2])
		assert.are.equal("``````", text[#text])
		assert.are.equal("x ````` y", text[4])
	end)

	it("names an unnamed buffer and omits a missing filetype", function()
		assert.are.same({ "[No Name]:L1", "```", "x", "```" }, data.build_selection_text(nil, 1, 1, { "x" }, ""))
		assert.are.equal("[No Name]:L1", data.build_selection_text("", 1, 1, { "x" }, nil)[1])
	end)

	it("keeps the path given for a file outside the repository", function()
		assert.are.equal(
			"~/notes/todo.md:L4-L6",
			data.build_selection_text("~/notes/todo.md", 4, 6, { "a" }, "markdown")[1]
		)
	end)
end)

describe("chat.format_base_path", function()
	it("says that the path is the base version", function()
		assert.are.equal("lua/x.lua (base version)", data.format_base_path("lua/x.lua"))
		assert.are.equal("? (base version)", data.format_base_path(nil))
	end)
end)

describe("chat.calculate_panel_width", function()
	it("uses the configured width when the editor is wide enough", function()
		assert.are.equal(60, data.calculate_panel_width(60, 200))
	end)

	it("never takes more than half the editor's columns", function()
		assert.are.equal(40, data.calculate_panel_width(60, 80))
		assert.are.equal(40, data.calculate_panel_width(60, 81))
	end)

	it("raises a tiny setting to the minimum, unless the editor is narrower still", function()
		assert.are.equal(data.MIN_PANEL_WIDTH, data.calculate_panel_width(3, 200))
		assert.are.equal(10, data.calculate_panel_width(3, 20))
		assert.are.equal(1, data.calculate_panel_width(60, 1))
	end)

	it("falls back to the default for a non-number", function()
		assert.are.equal(60, data.calculate_panel_width("wide", 200))
		assert.are.equal(60, data.calculate_panel_width(nil, 200))
	end)
end)

describe("chat.find_panel_split", function()
	it("opens on the right unless left is asked for", function()
		assert.are.equal("right", data.find_panel_split("right"))
		assert.are.equal("left", data.find_panel_split("left"))
		assert.are.equal("right", data.find_panel_split("top"))
		assert.are.equal("right", data.find_panel_split(nil))
	end)
end)

describe("chat panel", function()
	local tmp_dir
	local runs
	local notes
	local available
	local insert_starts

	local function panel()
		return config.state.chat_panel
	end

	local function log_lines()
		return vim.api.nvim_buf_get_lines(panel().log_buf, 0, -1, false)
	end

	local function input_lines()
		return vim.api.nvim_buf_get_lines(panel().input_buf, 0, -1, false)
	end

	local function log_text()
		return table.concat(log_lines(), "\n")
	end

	local function set_input(lines)
		vim.api.nvim_buf_set_lines(panel().input_buf, 0, -1, false, lines)
	end

	local function progress_text()
		local ns = vim.api.nvim_get_namespaces().fude_chat_progress
		local marks = vim.api.nvim_buf_get_extmarks(panel().log_buf, ns, 0, -1, { details = true })
		local out = {}
		for _, mark in ipairs(marks) do
			for _, chunk in ipairs(mark[4].virt_text or {}) do
				table.insert(out, chunk[1])
			end
		end
		return table.concat(out)
	end

	--- The buffer-local normal-mode mapping of `lhs`, or nil.
	local function mapping(buf, lhs)
		local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == want then
				return map
			end
		end
		return nil
	end

	local function notified(level, pattern)
		for _, n in ipairs(notes) do
			if n.level == level and n.msg:find(pattern, 1, true) then
				return true
			end
		end
		return false
	end

	local function start_review()
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 7
		config.state.pr_url = "https://github.com/o/r/pull/7"
		config.state.base_ref = "main"
		config.state.head_ref = "feat"
		config.state.repo_root = "/repo"
	end

	before_each(function()
		config.setup({})
		tmp_dir = vim.fn.tempname()
		chat._dir = tmp_dir
		runs = {}
		notes = {}
		available = true
		start_review()
		helpers.mock(require("fude.diff"), "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(chat, "is_available", function()
			return available
		end)
		helpers.mock(chat, "run", function(cmd, opts, on_chunk, on_exit)
			local run = { cmd = cmd, opts = opts, chunk = on_chunk, exit = on_exit, killed = false }
			table.insert(runs, run)
			return {
				kill = function()
					run.killed = true
				end,
			}
		end)
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notes, { msg = msg, level = level })
		end)
		-- Count :startinsert instead of running it: insert mode would outlive the test.
		insert_starts = 0
		local real_cmd = vim.cmd
		helpers.mock(vim, "cmd", function(command)
			if command == "startinsert" then
				insert_starts = insert_starts + 1
				return
			end
			return real_cmd(command)
		end)
	end)

	after_each(function()
		helpers.cleanup()
		chat._dir = nil
		vim.fn.delete(tmp_dir, "rf")
		pcall(vim.cmd, "silent! tabonly")
	end)

	describe("open / toggle", function()
		it("opens the log above the input at the right edge and focuses the input", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.toggle()
			local p = panel()
			assert.is_not_nil(p)
			assert.are.equal(p.input_win, vim.api.nvim_get_current_win())
			local editor_pos = vim.api.nvim_win_get_position(editor)
			local log_pos = vim.api.nvim_win_get_position(p.log_win)
			local input_pos = vim.api.nvim_win_get_position(p.input_win)
			assert.is_true(log_pos[2] > editor_pos[2])
			assert.are.equal(log_pos[2], input_pos[2])
			assert.is_true(input_pos[1] > log_pos[1])
			-- right edge: the pane ends at the last column
			assert.are.equal(vim.o.columns, log_pos[2] + vim.api.nvim_win_get_width(p.log_win))
		end)

		it("opens at the left edge with chat.position = left", function()
			config.setup({ chat = { position = "left" } })
			local editor = vim.api.nvim_get_current_win()
			chat_panel.open()
			assert.are.equal(0, vim.api.nvim_win_get_position(panel().log_win)[2])
			assert.is_true(vim.api.nvim_win_get_position(editor)[2] > 0)
		end)

		it("uses chat.width, limited to half the editor", function()
			config.setup({ chat = { width = 30 } })
			chat_panel.open()
			assert.are.equal(30, vim.api.nvim_win_get_width(panel().log_win))
			chat_panel.close()
			config.setup({ chat = { width = 5000 } })
			chat_panel.open()
			assert.are.equal(math.floor(vim.o.columns / 2), vim.api.nvim_win_get_width(panel().log_win))
		end)

		it("makes the log a read-only markdown buffer and the input an editable scratch buffer", function()
			chat_panel.open()
			local p = panel()
			assert.is_false(vim.bo[p.log_buf].modifiable)
			assert.are.equal("markdown", vim.bo[p.log_buf].filetype)
			assert.are.equal("nofile", vim.bo[p.log_buf].buftype)
			assert.is_true(vim.bo[p.input_buf].modifiable)
			assert.are.equal("nofile", vim.bo[p.input_buf].buftype)
			-- not a comment input: the commit scope's comment teardown must not close it
			assert.is_nil(vim.b[p.input_buf].fude_comment)
		end)

		it("focuses the open panel from another window, and closes it from inside", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.toggle()
			local p = panel()
			vim.api.nvim_set_current_win(editor)
			chat_panel.toggle()
			assert.are.equal(p, panel())
			assert.are.equal(p.input_win, vim.api.nvim_get_current_win())
			chat_panel.toggle()
			assert.is_nil(panel())
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
			assert.is_false(vim.api.nvim_win_is_valid(p.input_win))
			assert.are.equal(editor, vim.api.nvim_get_current_win())
		end)

		it("starts insert mode when a command focuses the input, not on plain window movement", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.toggle()
			assert.are.equal(1, insert_starts)
			vim.api.nvim_set_current_win(editor)
			vim.api.nvim_set_current_win(panel().input_win)
			assert.are.equal(1, insert_starts)
			vim.api.nvim_set_current_win(editor)
			chat_panel.toggle()
			assert.are.equal(2, insert_starts)
			-- closing starts nothing
			chat_panel.toggle()
			assert.are.equal(2, insert_starts)
		end)

		it("closes from the log pane too", function()
			chat_panel.toggle()
			vim.api.nvim_set_current_win(panel().log_win)
			chat_panel.toggle()
			assert.is_nil(panel())
		end)

		it("reopens in the current tabpage when the panel lives in another one", function()
			chat_panel.open()
			local old = panel()
			vim.cmd("tabnew")
			chat_panel.toggle()
			assert.is_false(vim.api.nvim_win_is_valid(old.log_win))
			assert.are.equal(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(panel().log_win))
		end)

		it("closes both panes when one of them is closed", function()
			chat_panel.open()
			local p = panel()
			-- from the other pane: it closes once the closing command has ended
			vim.api.nvim_win_close(p.log_win, true)
			assert.is_true(helpers.wait_for(function()
				return panel() == nil
			end))
			assert.is_false(vim.api.nvim_win_is_valid(p.input_win))
		end)

		it("closes the other pane at once when a pane is closed from an editor window", function()
			chat_panel.open()
			local p = panel()
			vim.api.nvim_set_current_win(p.prev_win)
			vim.api.nvim_win_close(p.input_win, true)
			assert.is_nil(panel())
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
		end)

		it("refuses outside review mode", function()
			config.reset_state()
			chat_panel.toggle()
			assert.is_nil(panel())
			assert.is_true(notified(vim.log.levels.WARN, "Not active"))
		end)

		it("shows the stored conversation", function()
			chat.save(KEY, {
				session_id = ID,
				started = true,
				messages = { data.build_message("user", "old q"), data.build_message("assistant", "old a", "done") },
			})
			chat_panel.open()
			assert.are.same({ "## You", "", "old q", "", "## Claude", "", "old a", "" }, log_lines())
			-- looking at the end of the log
			assert.are.equal(#log_lines(), vim.api.nvim_win_get_cursor(panel().log_win)[1])
		end)

		it("keeps unsent input across close and open", function()
			chat_panel.open()
			set_input({ "half a", "question" })
			chat_panel.close()
			chat_panel.open()
			assert.are.same({ "half a", "question" }, input_lines())
		end)
	end)

	describe("keymaps", function()
		it("maps submit, cancel and close from chat.keymaps", function()
			config.setup({ chat = { keymaps = { submit = "<C-s>", cancel = "<C-x>", close = "Q" } } })
			chat_panel.open()
			local p = panel()
			assert.is_not_nil(mapping(p.input_buf, "<C-s>"))
			assert.is_nil(mapping(p.log_buf, "<C-s>"))
			assert.is_nil(mapping(p.input_buf, "<CR>"))
			for _, buf in ipairs({ p.input_buf, p.log_buf }) do
				assert.is_not_nil(mapping(buf, "<C-x>"))
				assert.is_not_nil(mapping(buf, "Q"))
			end
		end)

		it("leaves a key set to false unmapped", function()
			config.setup({ chat = { keymaps = { cancel = false, close = false } } })
			chat_panel.open()
			assert.is_nil(mapping(panel().input_buf, "<C-c>"))
			assert.is_nil(mapping(panel().input_buf, "q"))
			assert.is_not_nil(mapping(panel().input_buf, "<CR>"))
		end)

		it("the submit key sends the input", function()
			chat_panel.open()
			set_input({ "why?" })
			mapping(panel().input_buf, "<CR>").callback()
			assert.are.equal(1, #runs)
			assert.are.equal("why?", runs[1].opts.stdin)
		end)

		it("the cancel key stops the answer and the close key closes the panel", function()
			chat_panel.open()
			set_input({ "why?" })
			chat_panel.submit()
			mapping(panel().log_buf, "<C-c>").callback()
			assert.is_true(runs[1].killed)
			mapping(panel().log_buf, "q").callback()
			assert.is_nil(panel())
		end)
	end)

	describe("submit", function()
		it("moves the question to the log, empties the input and runs claude in the repo root", function()
			chat_panel.open()
			set_input({ "why this", "change?" })
			chat_panel.submit()
			assert.are.same({ "## You", "", "why this", "change?", "", "## Claude", "", "" }, log_lines())
			assert.are.same({ "" }, input_lines())
			assert.are.equal("/repo", runs[1].opts.cwd)
			assert.are.equal("why this\nchange?", runs[1].opts.stdin)
		end)

		it("does not send an empty input", function()
			chat_panel.open()
			set_input({ "  ", "" })
			chat_panel.submit()
			assert.are.equal(0, #runs)
			assert.are.same({ "" }, log_lines())
		end)

		it("appends the answer to the log as it arrives", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("Hello"))
			assert.are.equal("Hello", log_lines()[#log_lines()])
			runs[1].chunk(text_line(", world\nsecond line"))
			local lines = log_lines()
			assert.are.equal("Hello, world", lines[#lines - 1])
			assert.are.equal("second line", lines[#lines])
			runs[1].chunk(success_line("Hello, world\nsecond line"))
			runs[1].exit(0, "")
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "Hello, world", "second line", "" }, log_lines())
			-- the next open shows the same log from the store
			chat_panel.close()
			chat_panel.open()
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "Hello, world", "second line", "" }, log_lines())
		end)

		it("shows an answer that came without partial text", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(success_line("whole"))
			runs[1].exit(0, "")
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "whole", "" }, log_lines())
		end)

		it("refuses a question while one is being answered and keeps the input", function()
			chat_panel.open()
			set_input({ "q1" })
			chat_panel.submit()
			set_input({ "q2" })
			chat_panel.submit()
			assert.are.equal(1, #runs)
			assert.are.same({ "q2" }, input_lines())
			assert.is_true(notified(vim.log.levels.INFO, "still answering"))
		end)

		it("continues the stored session on the next question", function()
			chat_panel.open()
			set_input({ "q1" })
			chat_panel.submit()
			runs[1].chunk(vim.json.encode({ type = "system", subtype = "init" }) .. "\n" .. success_line("a1"))
			runs[1].exit(0, "")
			set_input({ "q2" })
			chat_panel.submit()
			assert.is_true(vim.tbl_contains(runs[2].cmd, "--resume"))
			assert.is_true(vim.tbl_contains(log_lines(), "q1"))
			assert.is_true(vim.tbl_contains(log_lines(), "q2"))
		end)
	end)

	describe("progress", function()
		it("shows a spinner while answering without changing the log's text", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			assert.truthy(progress_text():find(chat_panel.THINKING_TEXT, 1, true))
			local tick = vim.api.nvim_buf_get_changedtick(panel().log_buf)
			local first = progress_text()
			-- the timer advances the frame
			assert.is_true(helpers.wait_for(function()
				return progress_text() ~= first
			end))
			assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(panel().log_buf))
		end)

		it("shows the tool claude is running", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(tool_line("Read", { file_path = "/repo/lua/fude/foo.lua" }))
			assert.truthy(progress_text():find("Read lua/fude/foo.lua", 1, true))
			-- text after the tool call: back to the plain spinner
			runs[1].chunk(text_line("so"))
			assert.is_nil(progress_text():find("Read lua/fude/foo.lua", 1, true))
		end)

		it("removes the progress line when the answer ends", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(success_line("a"))
			runs[1].exit(0, "")
			assert.are.equal("", progress_text())
			assert.is_nil(panel().stop_spinner)
		end)

		it("stops the spinner timer when the panel closes", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			local p = panel()
			assert.is_not_nil(p.stop_spinner)
			chat_panel.close()
			assert.is_nil(p.stop_spinner)
		end)
	end)

	describe("scrolling", function()
		local function fill_log()
			local messages = {}
			for i = 1, 30 do
				table.insert(messages, data.build_message("user", "q" .. i))
				table.insert(messages, data.build_message("assistant", "a" .. i, "done"))
			end
			chat.save(KEY, { session_id = ID, started = true, messages = messages })
		end

		it("follows new output while the log window is at the end", function()
			fill_log()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("one\ntwo\nthree"))
			assert.are.equal(#log_lines(), vim.api.nvim_win_get_cursor(panel().log_win)[1])
		end)

		it("stays put while the user reads earlier output", function()
			fill_log()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			vim.api.nvim_win_set_cursor(panel().log_win, { 5, 0 })
			runs[1].chunk(text_line("one\ntwo\nthree"))
			runs[1].chunk(success_line("one\ntwo\nthree"))
			runs[1].exit(0, "")
			assert.are.equal(5, vim.api.nvim_win_get_cursor(panel().log_win)[1])
		end)
	end)

	describe("cancel", function()
		it("stops the process and marks the partial answer as interrupted", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("partial"))
			chat_panel.cancel()
			assert.is_true(runs[1].killed)
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "partial", "", data.CANCELLED_MARK, "" }, log_lines())
			assert.are.equal("", progress_text())
			assert.are.equal("cancelled", chat.load(KEY).messages[2].status)
		end)

		it("says so when nothing is being answered", function()
			chat_panel.open()
			chat_panel.cancel()
			assert.is_true(notified(vim.log.levels.INFO, "No chat answer in progress"))
		end)
	end)

	describe("failure", function()
		it("shows the error after the text that had arrived and returns the question to the input", function()
			chat_panel.open()
			set_input({ "my", "question" })
			chat_panel.submit()
			runs[1].chunk(text_line("so far"))
			runs[1].exit(1, "API Error: 529")
			assert.are.same(
				{ "## You", "", "my", "question", "", "## Claude", "", "so far", "", "**Error:** API Error: 529", "" },
				log_lines()
			)
			assert.are.same({ "my", "question" }, input_lines())
			assert.are.equal("", progress_text())
			assert.are.same({}, chat.load(KEY).messages)
		end)

		it("puts the failed question before input typed meanwhile", function()
			chat_panel.open()
			set_input({ "first" })
			chat_panel.submit()
			set_input({ "typed later" })
			runs[1].exit(1, "boom")
			assert.are.same({ "first", "", "typed later" }, input_lines())
		end)

		it("shows a command that could not be started", function()
			helpers.mock(chat, "run", function()
				return nil, "ENOENT"
			end)
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			assert.truthy(log_text():find("**Error:** could not start", 1, true))
			assert.are.same({ "q" }, input_lines())
			assert.is_nil(config.state.chat_live)
		end)

		it("says that the answer is ready when it ends while the panel is closed", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			chat_panel.close()
			runs[1].chunk(text_line("a") .. success_line("a"))
			runs[1].exit(0, "")
			local ready = 0
			for _, n in ipairs(notes) do
				if n.level == vim.log.levels.INFO and n.msg:find("answer is ready", 1, true) then
					ready = ready + 1
				end
			end
			assert.are.equal(1, ready)
		end)

		it("does not announce an answer that ends in the open panel", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(success_line("a"))
			runs[1].exit(0, "")
			assert.is_false(notified(vim.log.levels.INFO, "answer is ready"))
		end)

		it("keeps the question for the next open when the panel was closed meanwhile", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			chat_panel.close()
			runs[1].exit(1, "boom")
			assert.is_true(notified(vim.log.levels.ERROR, "boom"))
			chat_panel.open()
			assert.are.same({ "q" }, input_lines())
		end)

		it("tells that a new session was started when the resumed one is gone", function()
			chat.save(KEY, { session_id = ID, started = true, messages = {} })
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].exit(1, "No conversation found with session ID: " .. ID)
			assert.are.equal(2, #runs)
			assert.is_true(vim.tbl_contains(log_lines(), data.NEW_SESSION_NOTE))
			runs[2].chunk(text_line("fresh") .. success_line("fresh"))
			runs[2].exit(0, "")
			assert.are.same({ "## You", "", "q", "", "## Claude", "", data.NEW_SESSION_NOTE, "", "fresh", "" }, log_lines())
			assert.are.same({ "" }, input_lines())
		end)
	end)

	describe("reopening while answering", function()
		it("shows the exchange in flight and keeps streaming into the new panel", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("part one"))
			chat_panel.close()
			runs[1].chunk(text_line(", part two"))
			chat_panel.open()
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "part one, part two" }, log_lines())
			assert.truthy(progress_text():find(chat_panel.THINKING_TEXT, 1, true))
			runs[1].chunk(text_line("!") .. success_line("x"))
			runs[1].exit(0, "")
			assert.are.same({ "## You", "", "q", "", "## Claude", "", "part one, part two!", "" }, log_lines())
		end)
	end)

	describe("new chat", function()
		it("discards the session and the conversation and empties the log", function()
			chat.save(KEY, {
				session_id = ID,
				started = true,
				messages = { data.build_message("user", "old q"), data.build_message("assistant", "old a", "done") },
			})
			chat_panel.open()
			chat_panel.new_chat()
			assert.are.same({ "" }, log_lines())
			assert.are.same(data.build_empty_chat(), chat.load(KEY))
			set_input({ "q" })
			chat_panel.submit()
			assert.is_true(vim.tbl_contains(runs[1].cmd, "--session-id"))
			assert.is_false(vim.tbl_contains(runs[1].cmd, ID))
		end)

		it("stops the answer in progress first and stores nothing of it", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("partial"))
			chat_panel.new_chat()
			assert.is_true(runs[1].killed)
			assert.are.same({ "" }, log_lines())
			assert.are.equal("", progress_text())
			assert.is_nil(config.state.chat_live)
			assert.are.same(data.build_empty_chat(), chat.load(KEY))
		end)

		it("works with the panel closed", function()
			chat.save(KEY, { session_id = ID, started = true, messages = { data.build_message("user", "old") } })
			chat_panel.new_chat()
			assert.is_nil(panel())
			assert.are.same(data.build_empty_chat(), chat.load(KEY))
		end)
	end)

	describe("add selection", function()
		local buf

		before_each(function()
			buf = helpers.create_buf({ "local a = 1", "local b = 2", "return a + b" }, "/repo/lua/x.lua")
			-- a file buffer, not the scratch buffer the helper makes
			vim.bo[buf].buftype = ""
			vim.bo[buf].filetype = "lua"
			vim.api.nvim_set_current_buf(buf)
			helpers.mock_diff({ ["/repo/lua/x.lua"] = "lua/x.lua" })
		end)

		it("opens the panel and puts the path, range and fenced lines in the input", function()
			chat_panel.add_selection(1, 2)
			assert.is_not_nil(panel())
			assert.are.same({ "lua/x.lua:L1-L2", "```lua", "local a = 1", "local b = 2", "```", "" }, input_lines())
			assert.are.equal(panel().input_win, vim.api.nvim_get_current_win())
			assert.are.equal(6, vim.api.nvim_win_get_cursor(panel().input_win)[1])
			-- once for opening the panel, once for the paste
			assert.are.equal(2, insert_starts)
		end)

		it("writes the full path of a file outside the root claude runs in, wherever Neovim's cwd is", function()
			-- the cwd moved into another worktree: its files are relative to that one
			local other = helpers.create_buf({ "x" }, "/other-worktree/README.md")
			vim.bo[other].buftype = ""
			vim.api.nvim_set_current_buf(other)
			helpers.mock_diff({ ["/other-worktree/README.md"] = "README.md", ["/repo/lua/x.lua"] = nil })
			chat_panel.add_selection(1, 1)
			assert.are.equal("/other-worktree/README.md:L1", input_lines()[1])
			-- while a file of the review's root stays relative to it
			vim.api.nvim_set_current_win(panel().prev_win)
			vim.api.nvim_set_current_buf(buf)
			chat_panel.add_selection(1, 1)
			assert.is_true(vim.tbl_contains(input_lines(), "lua/x.lua:L1"))
		end)

		it("writes paths relative to the worktree of a local review", function()
			config.reset_state()
			config.state.active = true
			config.state.review_mode = "local"
			config.state.local_session =
				{ id = "s1", worktree_root = "/repo/lua", branch = "feat", base_ref = "main", scope = "base" }
			chat_panel.add_selection(1, 1)
			assert.are.equal("x.lua:L1", input_lines()[1])
		end)

		it("appends after existing input in an open panel", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.open()
			local p = panel()
			set_input({ "Compare this:", "" })
			vim.api.nvim_set_current_win(editor)
			chat_panel.add_selection(3, 3)
			assert.are.equal(p, panel())
			assert.are.same({ "Compare this:", "", "lua/x.lua:L3", "```lua", "return a + b", "```", "" }, input_lines())
			assert.are.equal(p.input_win, vim.api.nvim_get_current_win())
			assert.are.equal(2, insert_starts)
		end)

		it("marks lines taken from the diff preview's base pane as the base version", function()
			local base = helpers.create_buf({ "old a", "old b", "old c" })
			vim.bo[base].buftype = "nofile"
			vim.bo[base].filetype = "lua"
			pcall(vim.api.nvim_buf_set_name, base, "[base] lua/x.lua")
			config.state.preview_buf = base
			vim.api.nvim_set_current_buf(base)
			chat_panel.add_selection(2, 3)
			assert.are.same({ "lua/x.lua (base version):L2-L3", "```lua", "old b", "old c", "```", "" }, input_lines())
		end)

		it("refuses a named special buffer such as the side panel", function()
			sidepanel.open()
			assert.are.equal(config.state.sidepanel.win, vim.api.nvim_get_current_win())
			chat_panel.add_selection(1, 1)
			assert.is_nil(panel())
			assert.is_true(notified(vim.log.levels.WARN, "not a file"))
		end)

		it("names a buffer without a file and a file outside the repository", function()
			local scratch = helpers.create_buf({ "x" })
			vim.api.nvim_set_current_buf(scratch)
			chat_panel.add_selection(1, 1)
			assert.are.equal("[No Name]:L1", input_lines()[1])
			chat_panel.close()
			config.state.chat_input = nil

			local outside = helpers.create_buf({ "y" }, "/elsewhere/notes.txt")
			vim.bo[outside].buftype = ""
			vim.api.nvim_set_current_buf(outside)
			chat_panel.add_selection(1, 1)
			assert.are.equal("/elsewhere/notes.txt:L1", input_lines()[1])
		end)

		it("refuses a selection inside the chat panel", function()
			chat_panel.open()
			set_input({ "text" })
			chat_panel.add_selection(1, 1)
			assert.are.same({ "text" }, input_lines())
			assert.is_true(notified(vim.log.levels.WARN, "not in the chat panel"))
		end)
	end)

	describe("without the claude command", function()
		it("warns and does nothing", function()
			available = false
			chat.save(KEY, { session_id = ID, started = true, messages = {} })
			chat_panel.toggle()
			chat_panel.add_selection(1, 1)
			chat_panel.new_chat()
			assert.is_nil(panel())
			assert.are.equal(ID, chat.load(KEY).session_id)
			local warns = 0
			for _, n in ipairs(notes) do
				if n.level == vim.log.levels.WARN and n.msg:find("claude command", 1, true) then
					warns = warns + 1
				end
			end
			assert.are.equal(3, warns)
		end)
	end)

	describe("review stop", function()
		it("teardown stops claude, stores what arrived and closes the panel", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			runs[1].chunk(text_line("partial"))
			local p = panel()
			chat_panel.teardown()
			assert.is_true(runs[1].killed)
			assert.is_nil(panel())
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
			assert.is_nil(config.state.chat_live)
			assert.are.equal("partial", chat.load(KEY).messages[2].text)
			assert.are.equal("cancelled", chat.load(KEY).messages[2].status)
		end)

		it(":FudeReviewStop (GitHub) tears the chat down", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			local p = panel()
			require("fude").stop()
			assert.is_false(config.state.active)
			assert.is_true(runs[1].killed)
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
			assert.is_false(vim.api.nvim_win_is_valid(p.input_win))
			assert.are.equal("cancelled", chat.load(KEY).messages[2].status)
		end)

		it("keeps the chat when a GitHub stop fails to restore HEAD and the session continues", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			local p = panel()
			config.state.scope = "commit"
			config.state.original_head_ref = "fude-test-no-such-ref-5d1f0c"
			require("fude").stop()
			assert.is_true(notified(vim.log.levels.ERROR, "Failed to restore HEAD"))
			assert.is_true(config.state.active)
			assert.is_false(runs[1].killed)
			assert.are.equal(p, panel())
			assert.is_true(chat_panel.is_open())
			assert.is_true(chat.is_running(KEY))
		end)

		it("tells that an answer is ready when the panel is open in another tabpage", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			vim.cmd("tabnew")
			runs[1].chunk(success_line("answer"))
			runs[1].exit(0, "")
			assert.is_true(notified(vim.log.levels.INFO, "answer is ready"))
		end)

		it("reports a failure when the panel is open in another tabpage", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			vim.cmd("tabnew")
			runs[1].exit(1, "boom")
			assert.is_true(notified(vim.log.levels.ERROR, "Chat failed: boom"))
			-- the question is back in the input of that panel
			assert.are.same({ "q" }, input_lines())
		end)

		it("stopping a local review tears the chat down", function()
			local root = vim.fn.tempname()
			vim.fn.mkdir(root, "p")
			config.reset_state()
			config.state.active = true
			config.state.review_mode = "local"
			config.state.local_session =
				{ id = "s1", worktree_root = root, branch = "feat", base_ref = "main", scope = "uncommitted" }
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			local p = panel()
			local key = chat.current_key()
			require("fude.local.session").stop()
			vim.fn.delete(root, "rf")
			assert.is_false(config.state.active)
			assert.is_true(runs[1].killed)
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
			assert.are.equal("cancelled", chat.load(key).messages[2].status)
		end)

		it("late output of a stopped session does not touch the next session's panel", function()
			chat_panel.open()
			set_input({ "q" })
			chat_panel.submit()
			local old = runs[1]
			-- stop without killing (as if the kill had no effect), then start again
			chat_panel.close()
			config.reset_state()
			chat._reset()
			start_review()
			chat_panel.open()
			local before = log_lines()
			old.chunk(text_line("late") .. tool_line("Read", { file_path = "/repo/a.lua" }) .. success_line("late"))
			old.exit(0, "")
			assert.are.same(before, log_lines())
			assert.are.equal("", progress_text())
			assert.is_nil(config.state.chat_live)
			assert.are.same({ "" }, input_lines())
		end)
	end)

	describe("with the side panel and other windows", function()
		it("is not counted as an editor window by the side panel", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.open()
			assert.is_true(sidepanel.is_last_normal_window(editor))
			assert.is_true(chat_panel.is_panel_window(panel().log_win))
			assert.is_true(chat_panel.is_panel_window(panel().input_win))
			assert.is_false(chat_panel.is_panel_window(editor))
		end)

		it("is never the side panel's target window", function()
			local editor = vim.api.nvim_get_current_win()
			-- a special buffer in the only other window: the fallback loop picks "any" window
			local special = helpers.create_buf({ "x" })
			vim.bo[special].buftype = "nofile"
			vim.api.nvim_win_set_buf(editor, special)
			chat_panel.open()
			assert.are.equal(editor, sidepanel.find_target_window(nil))
		end)

		it("opens next to the side panel without closing it", function()
			sidepanel.open()
			local side_win = config.state.sidepanel.win
			chat_panel.open()
			assert.is_true(vim.api.nvim_win_is_valid(side_win))
			assert.is_not_nil(panel())
			assert.are.equal(0, vim.api.nvim_win_get_position(side_win)[2])
		end)

		it("moves file navigation out of a chat pane", function()
			local editor = vim.api.nvim_get_current_win()
			config.state.changed_files = { { path = "a.lua", status = "modified" }, { path = "b.lua", status = "modified" } }
			local opened_in
			helpers.mock(require("fude.files"), "open_file", function()
				opened_in = vim.api.nvim_get_current_win()
			end)
			chat_panel.open()
			require("fude.files").next_file()
			assert.are.equal(editor, opened_in)
		end)

		it("opens a file chosen from a chat pane in an editor window and keeps the unsent question", function()
			local editor = vim.api.nvim_get_current_win()
			vim.fn.mkdir(tmp_dir, "p")
			local file = tmp_dir .. "/a.lua"
			vim.fn.writefile({ "return 1" }, file)
			chat_panel.open()
			set_input({ "unsent" })
			local p = panel()
			-- as a picker's confirm does, with focus back in the input pane
			require("fude.files").open_file(file, { path = "a.lua", status = "modified" })
			assert.are.equal(
				vim.fn.resolve(file),
				vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor)))
			)
			assert.are.equal(editor, vim.api.nvim_get_current_win())
			assert.is_true(chat_panel.is_open())
			assert.are.equal(p.input_buf, vim.api.nvim_win_get_buf(p.input_win))
			assert.are.same({ "unsent" }, input_lines())
		end)

		it("leave_panel_window moves out of a chat pane and out of the side panel", function()
			local editor = vim.api.nvim_get_current_win()
			local files = require("fude.files")
			assert.is_true(files.leave_panel_window())
			assert.are.equal(editor, vim.api.nvim_get_current_win())
			chat_panel.open()
			vim.api.nvim_set_current_win(panel().log_win)
			assert.is_true(files.leave_panel_window())
			assert.are.equal(editor, vim.api.nvim_get_current_win())
			sidepanel.open()
			assert.are.equal(config.state.sidepanel.win, vim.api.nvim_get_current_win())
			assert.is_true(files.leave_panel_window())
			assert.are.equal(editor, vim.api.nvim_get_current_win())
		end)

		it("leave_panel_window refuses with a warning when only the panes are left", function()
			local editor = vim.api.nvim_get_current_win()
			chat_panel.open()
			local input_win = panel().input_win
			vim.api.nvim_win_close(editor, true)
			-- before the scheduled editor window is opened
			assert.is_false(require("fude.files").leave_panel_window())
			assert.are.equal(input_win, vim.api.nvim_get_current_win())
			assert.is_true(notified(vim.log.levels.WARN, "No source window available"))
		end)

		it("refuses :edit in a pane instead of replacing it", function()
			if vim.fn.exists("+winfixbuf") ~= 1 then
				return
			end
			vim.fn.mkdir(tmp_dir, "p")
			local file = tmp_dir .. "/b.lua"
			vim.fn.writefile({ "return 2" }, file)
			chat_panel.open()
			set_input({ "unsent" })
			local p = panel()
			for _, win in ipairs({ p.input_win, p.log_win }) do
				vim.api.nvim_set_current_win(win)
				local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
				assert.is_false(ok)
				assert.truthy(tostring(err):find("E1513", 1, true))
			end
			assert.is_true(chat_panel.is_open())
			assert.are.same({ "unsent" }, input_lines())
		end)

		it("leaves a window alone whose pane buffer was replaced by force", function()
			if vim.fn.exists("+winfixbuf") ~= 1 then
				return
			end
			local other = helpers.create_buf({ "mine" })
			vim.bo[other].buftype = ""
			chat_panel.open()
			local p = panel()
			vim.api.nvim_set_current_win(p.input_win)
			vim.cmd("buffer! " .. other)
			assert.is_false(chat_panel.is_open())
			assert.is_false(chat_panel.is_panel_window(p.input_win))
			-- the next toggle reopens the panel without closing that window
			chat_panel.toggle()
			assert.is_true(vim.api.nvim_win_is_valid(p.input_win))
			assert.are.equal(other, vim.api.nvim_win_get_buf(p.input_win))
			assert.is_false(vim.wo[p.input_win].winfixbuf)
			assert.is_false(vim.wo[p.input_win].winfixheight)
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
			assert.is_true(chat_panel.is_open())
			assert.are_not.equal(p.input_win, panel().input_win)
		end)

		it("turns the pane :only left behind into an ordinary editor window", function()
			chat_panel.open()
			set_input({ "unsent" })
			local p = panel()
			vim.api.nvim_set_current_win(p.input_win)
			vim.cmd("only")
			assert.is_true(helpers.wait_for(function()
				return config.state.chat_panel == nil
			end))
			local wins = vim.api.nvim_tabpage_list_wins(0)
			assert.are.equal(1, #wins)
			local win = wins[1]
			assert.is_false(vim.wo[win].winfixwidth)
			assert.is_false(vim.wo[win].winfixheight)
			if vim.fn.exists("+winfixbuf") == 1 then
				assert.is_false(vim.wo[win].winfixbuf)
			end
			assert.are.equal(vim.go.wrap, vim.wo[win].wrap)
			assert.are.equal(vim.go.signcolumn, vim.wo[win].signcolumn)
			assert.are.equal("", vim.bo[vim.api.nvim_win_get_buf(win)].buftype)
			assert.are.same({ "unsent" }, config.state.chat_input)
		end)

		it("opens an editor window in its own tabpage while the side panel is in another one", function()
			sidepanel.open()
			vim.cmd("tabnew")
			local editor = vim.api.nvim_get_current_win()
			chat_panel.open()
			local p = panel()
			vim.api.nvim_win_close(editor, true)
			local function editor_windows()
				local wins = {}
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if not chat_panel.is_panel_window(w) then
						table.insert(wins, w)
					end
				end
				return wins
			end
			assert.is_true(helpers.wait_for(function()
				return #editor_windows() == 1
			end))
			assert.are.equal(p, panel())
			assert.are.equal("", vim.bo[vim.api.nvim_win_get_buf(editor_windows()[1])].buftype)
		end)

		it("stays open when a :quit closes the side panel's tabpage", function()
			local first_tab = vim.api.nvim_get_current_tabpage()
			local editor = vim.api.nvim_get_current_win()
			sidepanel.open()
			vim.cmd("tabnew")
			chat_panel.open()
			local p = panel()
			vim.api.nvim_set_current_win(editor)
			vim.cmd("quit")
			assert.is_true(helpers.wait_for(function()
				return not vim.api.nvim_tabpage_is_valid(first_tab)
			end))
			assert.are.equal(p, panel())
			assert.is_true(chat_panel.is_open())
		end)

		describe("on a wide screen", function()
			local columns

			before_each(function()
				columns = vim.o.columns
				vim.o.columns = 200
			end)

			after_each(function()
				pcall(vim.cmd, "silent! only")
				vim.o.columns = columns
			end)

			it("keeps the configured width when the editor window is reopened", function()
				local editor = vim.api.nvim_get_current_win()
				chat_panel.open()
				local p = panel()
				assert.are.equal(60, vim.api.nvim_win_get_width(p.log_win))
				vim.api.nvim_win_close(editor, true)
				assert.is_true(helpers.wait_for(function()
					return #vim.api.nvim_tabpage_list_wins(0) == 3
				end))
				assert.are.equal(60, vim.api.nvim_win_get_width(p.log_win))
				assert.are.equal(60, vim.api.nvim_win_get_width(p.input_win))
			end)

			it("keeps the side panel's configured width when its editor window is reopened", function()
				local editor = vim.api.nvim_get_current_win()
				sidepanel.open()
				local side_win = config.state.sidepanel.win
				local width = vim.api.nvim_win_get_width(side_win)
				assert.are.equal(config.opts.sidepanel.width, width)
				vim.api.nvim_win_close(editor, true)
				assert.is_true(helpers.wait_for(function()
					return #vim.api.nvim_tabpage_list_wins(0) == 2
				end))
				assert.are.equal(width, vim.api.nvim_win_get_width(side_win))
			end)
		end)

		it("closes the whole panel when a pane is moved to another tabpage", function()
			local tab = vim.api.nvim_get_current_tabpage()
			chat_panel.open()
			set_input({ "unsent" })
			local p = panel()
			vim.api.nvim_set_current_win(p.input_win)
			vim.cmd("wincmd T")
			assert.is_true(helpers.wait_for(function()
				return config.state.chat_panel == nil
			end))
			-- no window is left on a pane buffer, in any tabpage
			assert.is_false(vim.api.nvim_buf_is_valid(p.input_buf))
			assert.is_false(vim.api.nvim_buf_is_valid(p.log_buf))
			assert.are.same({ tab }, vim.api.nvim_list_tabpages())
			assert.are.same({ "unsent" }, config.state.chat_input)
			-- and the next toggle opens a working panel with the input back
			chat_panel.toggle()
			assert.is_true(chat_panel.is_open())
			assert.are.same({ "unsent" }, input_lines())
		end)

		it("closes a second window opened on a pane buffer with the panel", function()
			chat_panel.open()
			local p = panel()
			vim.api.nvim_set_current_win(p.log_win)
			vim.cmd("split")
			local extra = vim.api.nvim_get_current_win()
			assert.are.equal(p.log_buf, vim.api.nvim_win_get_buf(extra))
			chat_panel.close()
			assert.is_false(vim.api.nvim_win_is_valid(extra))
			assert.is_false(vim.api.nvim_win_is_valid(p.log_win))
		end)

		it("opens an editor window when its panes are the only windows left", function()
			local editor = vim.api.nvim_get_current_win()
			vim.cmd("vsplit")
			local other = vim.api.nvim_get_current_win()
			chat_panel.open()
			local p = panel()
			vim.api.nvim_win_close(other, true)
			vim.api.nvim_win_close(editor, true)
			local function editor_windows()
				local wins = {}
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if not chat_panel.is_panel_window(w) then
						table.insert(wins, w)
					end
				end
				return wins
			end
			assert.is_true(helpers.wait_for(function()
				return #editor_windows() == 1
			end))
			assert.are.equal(p, panel())
			local new_win = editor_windows()[1]
			-- an ordinary editor window, on the other side of the panel
			assert.is_false(vim.wo[new_win].winfixwidth)
			assert.are.equal("", vim.bo[vim.api.nvim_win_get_buf(new_win)].buftype)
			assert.are.equal(0, vim.api.nvim_win_get_position(new_win)[2])
			assert.are.equal(new_win, p.prev_win)
		end)

		it("lets the side panel reopen the editor window when both panels are open", function()
			local columns = vim.o.columns
			vim.o.columns = 200
			local editor = vim.api.nvim_get_current_win()
			sidepanel.open()
			local side_win = config.state.sidepanel.win
			vim.api.nvim_set_current_win(editor)
			chat_panel.open()
			local p = panel()
			-- side panel | editor | chat
			assert.are.same({ side_win, editor }, {
				vim.api.nvim_tabpage_list_wins(0)[1],
				vim.api.nvim_tabpage_list_wins(0)[2],
			})
			assert.are.equal("", vim.bo[vim.api.nvim_win_get_buf(editor)].buftype)
			local side_width = vim.api.nvim_win_get_width(side_win)
			assert.are.equal(60, vim.api.nvim_win_get_width(p.log_win))
			local function editor_windows()
				local wins = {}
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if not chat_panel.is_panel_window(w) and w ~= side_win then
						table.insert(wins, w)
					end
				end
				return wins
			end
			-- closed from the editor window itself: focus falls into a panel
			vim.api.nvim_set_current_win(editor)
			vim.api.nvim_win_close(editor, true)
			assert.is_true(helpers.wait_for(function()
				return #editor_windows() == 1
			end))
			-- and it stays one: the chat panel does not open a second one
			vim.wait(50, function()
				return #editor_windows() ~= 1
			end)
			assert.are.equal(1, #editor_windows())
			local new_win = editor_windows()[1]
			-- both panels keep their widths, the editor window gets the rest and the focus
			assert.are.equal(side_width, vim.api.nvim_win_get_width(side_win))
			assert.are.equal(60, vim.api.nvim_win_get_width(p.log_win))
			assert.are.equal(60, vim.api.nvim_win_get_width(p.input_win))
			assert.is_true(vim.api.nvim_win_get_width(new_win) > 90)
			assert.are.equal(new_win, vim.api.nvim_get_current_win())
			assert.are.equal(p, panel())
			vim.o.columns = columns
		end)

		describe("unsent input", function()
			local function type_question()
				chat_panel.open()
				set_input({ "unsent", "question" })
				return panel()
			end

			local function assert_kept(p)
				assert.is_true(helpers.wait_for(function()
					return config.state.chat_panel == nil
				end))
				assert.is_false(vim.api.nvim_buf_is_valid(p.input_buf))
				assert.are.same({ "unsent", "question" }, config.state.chat_input)
				chat_panel.open()
				assert.are.same({ "unsent", "question" }, input_lines())
			end

			for name, close in pairs({
				[":q in the input pane"] = function(p)
					vim.api.nvim_set_current_win(p.input_win)
					vim.cmd("quit")
				end,
				[":close in the input pane"] = function(p)
					vim.api.nvim_set_current_win(p.input_win)
					vim.cmd("close")
				end,
				[":q in the log pane"] = function(p)
					vim.api.nvim_set_current_win(p.log_win)
					vim.cmd("quit")
				end,
				[":bdelete of the input buffer"] = function(p)
					vim.cmd("bdelete! " .. p.input_buf)
				end,
				[":bwipeout of the input buffer"] = function(p)
					vim.cmd("bwipeout! " .. p.input_buf)
				end,
				[":only from the log pane"] = function(p)
					vim.api.nvim_set_current_win(p.log_win)
					vim.cmd("only")
				end,
				[":only from an editor window"] = function(p)
					vim.api.nvim_set_current_win(p.prev_win)
					vim.cmd("only")
				end,
				["<C-w>T in the input pane"] = function(p)
					vim.api.nvim_set_current_win(p.input_win)
					vim.cmd("wincmd T")
				end,
				["the close key"] = function()
					chat_panel.close()
				end,
				["the toggle command from a pane"] = function()
					chat_panel.toggle()
				end,
			}) do
				it("survives " .. name, function()
					local p = type_question()
					close(p)
					assert_kept(p)
				end)
			end

			it("survives :tabclose of the panel's tabpage", function()
				vim.cmd("tabnew")
				local p = type_question()
				vim.cmd("tabclose")
				assert_kept(p)
			end)

			it("follows what is typed, without waiting for the panel to close", function()
				chat_panel.open()
				set_input({ "typed" })
				vim.api.nvim_exec_autocmds("TextChangedI", { buffer = panel().input_buf })
				assert.are.same({ "typed" }, config.state.chat_input)
				set_input({ "" })
				vim.api.nvim_exec_autocmds("TextChanged", { buffer = panel().input_buf })
				assert.is_nil(config.state.chat_input)
			end)

			it("is gone after it was sent", function()
				local p = type_question()
				chat_panel.submit()
				assert.is_nil(config.state.chat_input)
				vim.api.nvim_set_current_win(p.input_win)
				vim.cmd("quit")
				assert.is_true(helpers.wait_for(function()
					return config.state.chat_panel == nil
				end))
				assert.is_nil(config.state.chat_input)
			end)

			it("is gone after the review stopped", function()
				type_question()
				chat_panel.teardown()
				assert.is_nil(config.state.chat_input)
			end)

			it("is kept by :FudeReviewChatNew, which only discards the conversation", function()
				type_question()
				chat_panel.new_chat()
				assert.are.same({ "unsent", "question" }, input_lines())
			end)
		end)

		it("follows a :quit of the last editor window instead of keeping the tabpage open", function()
			vim.cmd("tabnew")
			local tab = vim.api.nvim_get_current_tabpage()
			chat_panel.open()
			set_input({ "unsent" })
			vim.api.nvim_set_current_win(panel().prev_win)
			vim.cmd("quit")
			assert.is_true(helpers.wait_for(function()
				return not vim.api.nvim_tabpage_is_valid(tab)
			end))
			assert.is_nil(panel())
			assert.are.same({ "unsent" }, config.state.chat_input)
		end)
	end)
end)
