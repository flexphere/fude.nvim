--- AI chat core for review mode: stores one claude session and its
--- conversation per review target, and runs `claude -p` for a question,
--- reporting the answer as it streams in. No UI here; the panel drives this
--- module through `send` / `cancel` / `discard` / `load`.
---
--- Pure helpers (command line, stream-json parser, system prompt, stored
--- format) live in `chat/data.lua` and are re-exported below.
local M = {}
local config = require("fude.config")
local data = require("fude.chat.data")
local diff = require("fude.diff")
local drafts = require("fude.drafts")
local store = require("fude.local.store")

-- Re-export data functions (facade)
M.is_uuid = data.is_uuid
M.build_tool_names = data.build_tool_names
M.build_claude_args = data.build_claude_args
M.build_system_prompt = data.build_system_prompt
M.build_prompt_context = data.build_prompt_context
M.build_prompt_input = data.build_prompt_input
M.split_stream_chunk = data.split_stream_chunk
M.parse_stream_line = data.parse_stream_line
M.is_session_not_found = data.is_session_not_found
M.is_session_in_use = data.is_session_in_use
M.find_session_retry = data.find_session_retry
M.format_tool_use = data.format_tool_use
M.build_empty_chat = data.build_empty_chat
M.build_message = data.build_message
M.serialize_chat = data.serialize_chat
M.deserialize_chat = data.deserialize_chat
M.format_question_lines = data.format_question_lines
M.format_answer_end_lines = data.format_answer_end_lines
M.format_chat_lines = data.format_chat_lines
M.format_base_path = data.format_base_path
M.build_selection_text = data.build_selection_text
M.calculate_panel_width = data.calculate_panel_width
M.find_panel_split = data.find_panel_split

-- Directory override for tests (nil = use stdpath("state")/fude).
M._dir = nil

--- Reasons `send` refuses a question (its second return value).
M.ERR_BUSY = "busy"
M.ERR_EMPTY = "empty"
M.ERR_NO_TARGET = "no_target"
M.ERR_NO_ROOT = "no_root"

-- The question being answered (one at a time). Module-local rather than in
-- config.state: the process must be reachable to stop it after reset_state().
-- { state, key, root, prompt, handlers, session_id, resume, text, pending,
--   result, handle, retried, finished, abandoned }
local running = nil

-- === Config helpers ===

--- @return table the `chat` options (empty table before setup)
local function chat_opts()
	return config.opts.chat or {}
end

--- Whether the claude command (`chat.cmd`) can be run.
--- @return boolean
function M.is_available()
	local cmd = chat_opts().cmd
	return type(cmd) == "string" and cmd ~= "" and vim.fn.executable(cmd) == 1
end

--- Storage key of the active review target: the unit drafts use (GitHub: repo
--- + PR number; local review: worktree + branch), so a chat follows its
--- target across review stops and restarts and never mixes with another.
--- @param st table|nil config.state-shaped table (default: config.state)
--- @return string|nil key, nil without a review target
function M.current_key(st)
	local repo, id = drafts.build_draft_scope(st or config.state)
	if not repo then
		return nil
	end
	return drafts.make_draft_key(repo, id, "chat")
end

-- === Storage ===

--- File holding a target's chat. The key holds slashes and colons, so the
--- file is named by its hash; the key itself is kept inside the file.
--- @param key string
--- @return string
local function chat_path(key)
	local dir = M._dir or (vim.fn.stdpath("state") .. "/fude")
	return dir .. "/chat/" .. vim.fn.sha256(key) .. ".json"
end

--- Load a target's chat. Missing, unreadable or corrupt files give an empty
--- chat.
--- @param key string|nil
--- @return { session_id: string|nil, started: boolean, messages: table[] }
function M.load(key)
	if not key then
		return data.build_empty_chat()
	end
	local path = chat_path(key)
	if vim.fn.filereadable(path) == 0 then
		return data.build_empty_chat()
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return data.build_empty_chat()
	end
	return data.deserialize_chat(table.concat(lines, "\n"))
end

--- Persist a target's chat. Written to a temp file and renamed into place, so
--- a process killed mid-write never leaves a truncated conversation.
--- @param key string|nil
--- @param chat table { session_id, started, messages }
--- @return boolean ok, string|nil err
function M.save(key, chat)
	if not key then
		return false, "no review target"
	end
	local path = chat_path(key)
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		pcall(vim.fn.mkdir, dir, "p")
	end
	local tmp = string.format("%s.%d.tmp", path, vim.uv.os_getpid())
	local ok, result = pcall(vim.fn.writefile, vim.split(data.serialize_chat(chat, key), "\n"), tmp)
	if not ok or result ~= 0 then
		pcall(vim.fn.delete, tmp)
		return false, (not ok) and tostring(result) or ("could not write " .. tmp)
	end
	local renamed, rename_err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		pcall(vim.fn.delete, tmp)
		return false, "could not replace " .. path .. ": " .. (rename_err or "?")
	end
	return true, nil
end

-- === Running claude ===

--- Start a command, streaming its stdout. Replaced in tests.
--- `on_chunk` receives stdout pieces as they arrive (a piece may end in the
--- middle of a line) and `on_exit` runs once after the last piece; both run
--- on the main loop.
--- @param cmd string[]
--- @param opts { cwd: string|nil, stdin: string|nil }
--- @param on_chunk fun(chunk: string)
--- @param on_exit fun(code: number, stderr: string)
--- @return { kill: fun() }|nil handle, string|nil err
function M.run(cmd, opts, on_chunk, on_exit)
	local ok, obj = pcall(vim.system, cmd, {
		cwd = opts.cwd,
		stdin = opts.stdin,
		text = true,
		stdout = function(_, chunk)
			if chunk then
				vim.schedule(function()
					on_chunk(chunk)
				end)
			end
		end,
	}, function(result)
		vim.schedule(function()
			-- A process ended by a signal reports code 0; it did not succeed.
			local code = result.code
			if code == 0 and (result.signal or 0) ~= 0 then
				code = 128 + result.signal
			end
			on_exit(code, result.stderr or "")
		end)
	end)
	if not ok then
		return nil, tostring(obj)
	end
	return {
		kill = function()
			pcall(obj.kill, obj, "sigterm")
		end,
	}
end

--- Call a handler of the job's caller, unless the review session the
--- question was asked in is gone (stopped, or stopped and restarted).
--- @param job table
--- @param name string handler name
--- @param ... any
local function emit(job, name, ...)
	if config.state ~= job.state then
		return
	end
	local handler = job.handlers[name]
	if handler then
		handler(...)
	end
end

--- @return string UTC ISO-8601 timestamp
local function now_iso()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- End a job: store the exchange and report the outcome. A finished answer
--- and one stopped midway are stored (question, then answer); a failed one is
--- not, since the caller gets the question back to send again. Storing does
--- not depend on the session still being active — the key names the target —
--- but nothing is stored for an abandoned job (its chat was discarded).
--- @param job table
--- @param status "done"|"cancelled"|"error"
--- @param err string|nil
local function finish(job, status, err)
	if job.finished then
		return
	end
	job.finished = true
	if running == job then
		running = nil
	end
	local save_err
	if not job.abandoned and status ~= "error" then
		local chat = M.load(job.key)
		local at = now_iso()
		table.insert(chat.messages, data.build_message("user", job.prompt, nil, at))
		table.insert(chat.messages, data.build_message("assistant", job.text, status, at))
		local _
		_, save_err = M.save(job.key, chat)
	end
	emit(job, "on_done", {
		status = status,
		text = job.text,
		error = err,
		prompt = job.prompt,
		save_error = save_err,
	})
end

local start_process

--- Act on one parsed stream event.
--- @param job table
--- @param event table see data.parse_stream_line
local function handle_event(job, event)
	if event.kind == "init" then
		-- The session now exists on claude's side: later questions resume it.
		if not job.resume then
			local chat = M.load(job.key)
			if chat.session_id == job.session_id and not chat.started then
				chat.started = true
				M.save(job.key, chat)
			end
		end
	elseif event.kind == "message_start" then
		-- Text of separate messages (before and after a tool call) is not glued together.
		job.break_pending = job.text ~= ""
	elseif event.kind == "text" then
		local text = event.text
		if job.break_pending then
			job.break_pending = false
			if job.text:sub(-2) ~= "\n\n" then
				text = (job.text:sub(-1) == "\n" and "\n" or "\n\n") .. text
			end
		end
		job.text = job.text .. text
		emit(job, "on_text", text)
	elseif event.kind == "tool" then
		emit(job, "on_tool", data.format_tool_use(event.name, event.input, job.root))
	elseif event.kind == "result" then
		job.result = event
	end
end

--- @param job table
--- @param lines string[]
local function handle_lines(job, lines)
	for _, line in ipairs(lines) do
		for _, event in ipairs(data.parse_stream_line(line)) do
			handle_event(job, event)
		end
	end
end

--- The process ended: decide between done, error and one retry with the
--- other session argument.
--- @param job table
--- @param code number
--- @param stderr string
local function handle_exit(job, code, stderr)
	-- A last line without a trailing newline is still a line.
	if job.pending ~= "" then
		local last = job.pending
		job.pending = ""
		handle_lines(job, { last })
	end

	local result = job.result
	if result and result.ok then
		if job.text == "" then
			job.text = result.text or ""
		end
		finish(job, "done")
		return
	end

	local err
	if result then
		err = result.error
	else
		err = vim.trim(stderr or "")
		if err == "" then
			if code == 0 and job.text ~= "" then
				finish(job, "done")
				return
			end
			err = code == 0 and "claude returned no response" or ("claude exited with code " .. tostring(code))
		end
	end

	local retry = (not job.retried) and data.find_session_retry(job.resume, err) or nil
	-- A stopped session gets no second process: nobody is waiting for it.
	if retry and config.state == job.state then
		job.retried = true
		local chat = M.load(job.key)
		if retry == "new" then
			chat.session_id = store.generate_uuid()
			chat.started = false
		else
			chat.started = true
		end
		M.save(job.key, chat)
		job.session_id = chat.session_id
		job.resume = chat.started
		job.result = nil
		job.text = ""
		job.break_pending = false
		emit(job, "on_retry", retry)
		-- A handler may have cancelled or discarded the chat.
		if not job.finished then
			start_process(job)
		end
		return
	end
	finish(job, "error", err)
end

--- Start claude for the job with its current session argument.
--- @param job table
start_process = function(job)
	local opts = chat_opts()
	local args = data.build_claude_args({
		cmd = opts.cmd,
		session_id = job.session_id,
		resume = job.resume,
		allowed_tools = opts.allowed_tools,
		system_prompt = data.build_system_prompt(job.state),
		extra_args = opts.args,
	})
	job.pending = ""
	-- Each process gets its own token, so output of the one a retry replaced
	-- (or of a killed one) is dropped.
	local token = {}
	job.token = token
	-- The context lines go to claude only: job.prompt stays the user's own text.
	local input = data.build_prompt_input(data.build_prompt_context(job.state), job.prompt)
	local handle, err = M.run(args, { cwd = job.root, stdin = input }, function(chunk)
		if job.finished or job.token ~= token then
			return
		end
		local lines
		lines, job.pending = data.split_stream_chunk(job.pending, chunk)
		handle_lines(job, lines)
	end, function(code, stderr)
		if job.finished or job.token ~= token then
			return
		end
		handle_exit(job, code, stderr)
	end)
	if not handle then
		finish(job, "error", "could not start " .. tostring(args[1]) .. ": " .. tostring(err))
		return
	end
	job.handle = handle
end

--- Whether a question is being answered.
--- @param key string|nil only for this review target (default: any)
--- @return boolean
function M.is_running(key)
	return running ~= nil and (key == nil or running.key == key)
end

--- Ask claude a question about the active review target.
---
--- The first question of a target starts a session under a new UUID
--- (`--session-id`); later ones resume it (`--resume`). When the resumed
--- session no longer exists, the question is sent once more under a new id
--- and `on_retry("new")` tells the caller. claude runs in the repository
--- root with the question on stdin.
---
--- Handlers run on the main loop, and only while the review session the
--- question was asked in is still the active one:
---   on_text(text)    a piece of the answer
---   on_tool(label)   a tool call, e.g. "Read lua/fude/foo.lua"
---   on_retry(kind)   "new": started over under a new session id;
---                    "resume": the session existed already and was resumed
---   on_done(result)  { status = "done"|"cancelled"|"error", text, error, prompt, save_error }
--- `on_done` may run before `send` returns (the command could not be started).
--- @param prompt string
--- @param handlers table|nil
--- @return boolean accepted, string|nil reason one of M.ERR_* when refused
function M.send(prompt, handlers)
	if running then
		return false, M.ERR_BUSY
	end
	if type(prompt) ~= "string" or vim.trim(prompt) == "" then
		return false, M.ERR_EMPTY
	end
	local state = config.state
	local key = M.current_key(state)
	if not key then
		return false, M.ERR_NO_TARGET
	end
	local root = diff.get_repo_root()
	if not root then
		return false, M.ERR_NO_ROOT
	end

	local chat = M.load(key)
	if not chat.session_id then
		chat.session_id = store.generate_uuid()
		chat.started = false
		-- Stored before the run, so the id survives a Neovim exit mid-answer.
		M.save(key, chat)
	end

	local job = {
		state = state,
		key = key,
		root = root,
		prompt = prompt,
		handlers = handlers or {},
		session_id = chat.session_id,
		resume = chat.started,
		text = "",
		pending = "",
		retried = false,
		finished = false,
	}
	running = job
	start_process(job)
	return true, nil
end

--- Stop the question being answered. What arrived so far is stored as an
--- answer stopped midway and `on_done` runs with status "cancelled" before
--- this returns; output the process still sends is dropped.
--- @return boolean cancelled false when nothing was running
function M.cancel()
	local job = running
	if not job then
		return false
	end
	if job.handle then
		job.handle.kill()
	end
	finish(job, "cancelled")
	return true
end

--- Discard a review target's session id and conversation, so its next
--- question starts a new session. A question being answered for it is
--- stopped first, without storing its partial answer.
--- @param key string|nil (default: the active review target)
--- @return boolean ok, string|nil err
function M.discard(key)
	key = key or M.current_key()
	if not key then
		return false, "no review target"
	end
	if running and running.key == key then
		running.abandoned = true
		M.cancel()
	end
	local path = chat_path(key)
	if vim.uv.fs_stat(path) and vim.fn.delete(path) ~= 0 then
		return false, "could not delete " .. path
	end
	return true, nil
end

--- Test helper: forget the running job without touching its process or store.
function M._reset()
	running = nil
end

return M
