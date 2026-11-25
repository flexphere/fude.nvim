--- Pure helpers for the AI chat (`chat.lua`): the claude command line, the
--- stream-json line parser, the system prompt addition and the stored chat
--- format. No state, no vim API side effects (enforced by `make check-purity`).
local M = {}

-- === Command line ===

--- Permission mode passed to claude: anything that is not pre-approved by an
--- allow rule is denied instead of prompting (nobody can answer a prompt in
--- print mode), whatever default mode the user's own settings pick.
M.PERMISSION_MODE = "dontAsk"

--- Whether a string is a lowercase, hyphenated UUID, the only form claude
--- accepts as a session id.
--- @param s any
--- @return boolean
function M.is_uuid(s)
	if type(s) ~= "string" then
		return false
	end
	local h = "[0-9a-f]"
	local pattern = "^"
		.. h:rep(8)
		.. "%-"
		.. h:rep(4)
		.. "%-"
		.. h:rep(4)
		.. "%-"
		.. h:rep(4)
		.. "%-"
		.. h:rep(12)
		.. "$"
	return s:match(pattern) ~= nil
end

--- Keep the usable entries of an allowed-tools setting: non-blank strings,
--- trimmed, each once, in the given order.
--- @param allowed_tools any
--- @return string[]
local function clean_tool_specs(allowed_tools)
	local out, seen = {}, {}
	if type(allowed_tools) ~= "table" then
		return out
	end
	for _, spec in ipairs(allowed_tools) do
		if type(spec) == "string" then
			local trimmed = vim.trim(spec)
			if trimmed ~= "" and not seen[trimmed] then
				seen[trimmed] = true
				table.insert(out, trimmed)
			end
		end
	end
	return out
end

--- Built-in tool names an allowed-tools list refers to (`Bash(git diff:*)` →
--- `Bash`), each once, in first-appearance order. MCP tools (`mcp__…`) are not
--- built-in tools and are left out. The result is what `--tools` receives, so
--- a tool that is not named in the list does not exist for the session.
--- @param allowed_tools string[]|nil
--- @return string[]
function M.build_tool_names(allowed_tools)
	local names, seen = {}, {}
	for _, spec in ipairs(clean_tool_specs(allowed_tools)) do
		local name = spec:match("^([%w_]+)")
		if name and name:sub(1, 5) ~= "mcp__" and not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	return names
end

--- Build the claude command line for one question. The question itself is
--- not part of it: it goes to claude's stdin, so a prompt that starts with
--- `-` is never read as an option and the variadic `--allowedTools` cannot
--- swallow it.
---
--- Tools are restricted twice: `--tools` makes only the built-in tools named
--- in `allowed_tools` exist (so with the default list there is no Edit /
--- Write tool at all), and `--allowedTools` plus `--permission-mode dontAsk`
--- lets those tools run only in the listed forms (`Bash(git diff:*)`).
--- `extra_args` come last, so they can override any of the above.
--- @param opts { cmd: string|nil, session_id: string, resume: boolean|nil, allowed_tools: string[]|nil,
---   system_prompt: string|nil, extra_args: string[]|nil }
--- @return string[] argv
function M.build_claude_args(opts)
	opts = opts or {}
	local cmd = (type(opts.cmd) == "string" and opts.cmd ~= "") and opts.cmd or "claude"
	local args = {
		cmd,
		"-p",
		"--output-format",
		"stream-json",
		"--verbose",
		"--include-partial-messages",
		opts.resume and "--resume" or "--session-id",
		opts.session_id,
		"--permission-mode",
		M.PERMISSION_MODE,
		"--tools",
		table.concat(M.build_tool_names(opts.allowed_tools), ","),
	}
	local specs = clean_tool_specs(opts.allowed_tools)
	if #specs > 0 then
		table.insert(args, "--allowedTools")
		vim.list_extend(args, specs)
	end
	if type(opts.system_prompt) == "string" and opts.system_prompt ~= "" then
		table.insert(args, "--append-system-prompt")
		table.insert(args, opts.system_prompt)
	end
	if type(opts.extra_args) == "table" then
		for _, arg in ipairs(opts.extra_args) do
			if type(arg) == "string" then
				table.insert(args, arg)
			end
		end
	end
	return args
end

-- === System prompt ===

--- Build the text appended to claude's system prompt: the parts of the
--- review target that do not change during a conversation. GitHub review: PR
--- number, URL, base and head branch. Local review: the branch. What can
--- change (the local scope and base branch) is not here: claude records the
--- system prompt on a conversation's first request and reuses that record on
--- every `--resume`, so it goes with each question instead
--- (`build_prompt_context`).
--- @param st table|nil config.state-shaped table
--- @return string|nil text, nil when there is no review target
function M.build_system_prompt(st)
	if type(st) ~= "table" then
		return nil
	end
	local lines = {
		"The user is reviewing code in Neovim with fude.nvim and asks you questions about it.",
		"Answer the question; do not modify files.",
		"",
	}
	local function add(label, value)
		if type(value) == "string" or type(value) == "number" then
			table.insert(lines, label .. ": " .. tostring(value))
		end
	end
	if st.review_mode == "local" then
		local session = st.local_session
		if type(session) ~= "table" then
			return nil
		end
		table.insert(lines, "Review target: local review of a branch (no pull request)")
		add("Branch", session.branch)
		table.insert(lines, "Each question starts with the base branch and the scope under review at that moment.")
		return table.concat(lines, "\n")
	end
	if type(st.pr_number) ~= "number" and type(st.pr_number) ~= "string" then
		return nil
	end
	table.insert(lines, "Review target: GitHub pull request #" .. tostring(st.pr_number))
	add("URL", st.pr_url)
	add("Base branch", st.base_ref)
	add("Head branch", st.head_ref)
	return table.concat(lines, "\n")
end

--- What each local review scope compares, for the question's context lines.
local LOCAL_SCOPE_TEXT = {
	base = "base (the whole branch: working tree against the merge-base with the base branch)",
	unpushed = "unpushed (working tree against the upstream branch)",
	uncommitted = "uncommitted (staged and unstaged changes against HEAD)",
}

--- Lines put in front of a question: the parts of the review target that can
--- change during a conversation — in local review the base branch and the
--- current scope (the commit's SHA in the commit scope). A GitHub review has
--- none.
--- @param st table|nil config.state-shaped table
--- @return string[] lines (empty when there is nothing to add)
function M.build_prompt_context(st)
	if type(st) ~= "table" or st.review_mode ~= "local" then
		return {}
	end
	local session = st.local_session
	if type(session) ~= "table" then
		return {}
	end
	local parts = {}
	if type(session.base_ref) == "string" and session.base_ref ~= "" then
		table.insert(parts, "base branch: " .. session.base_ref)
	end
	if session.scope == "commit" then
		local sha = type(session.scope_commit_sha) == "string" and session.scope_commit_sha or "?"
		table.insert(parts, "scope: commit " .. sha .. " (that single commit against its parent; it is checked out)")
	elseif type(session.scope) == "string" and session.scope ~= "" then
		table.insert(parts, "scope: " .. (LOCAL_SCOPE_TEXT[session.scope] or session.scope))
	end
	if #parts == 0 then
		return {}
	end
	return { "[Review context — " .. table.concat(parts, "; ") .. "]" }
end

--- The text sent to claude for a question: the context lines, a blank line,
--- then the question as the user wrote it. Only this text carries the
--- context; the conversation log and the stored chat keep the bare question.
--- @param context string[]|nil see build_prompt_context
--- @param prompt string the user's question
--- @return string
function M.build_prompt_input(context, prompt)
	if type(context) ~= "table" or #context == 0 then
		return prompt
	end
	return table.concat(context, "\n") .. "\n\n" .. prompt
end

-- === stream-json ===

--- Split a stdout chunk into complete lines. A chunk may end in the middle of
--- a line, so the unfinished tail is returned to be passed back with the next
--- chunk.
--- @param pending string|nil the tail returned by the previous call
--- @param chunk string|nil
--- @return string[] lines complete lines (without the newline, blank ones dropped)
--- @return string rest the unfinished tail
function M.split_stream_chunk(pending, chunk)
	local text = (pending or "") .. (chunk or "")
	local lines = {}
	local start = 1
	while true do
		local nl = text:find("\n", start, true)
		if not nl then
			break
		end
		local line = (text:sub(start, nl - 1):gsub("\r$", ""))
		if line ~= "" then
			table.insert(lines, line)
		end
		start = nl + 1
	end
	return lines, text:sub(start)
end

--- The error text of a failed `result` line: its `errors` list, else its
--- `result` text, else its subtype.
--- @param obj table decoded result line
--- @return string
local function result_error(obj)
	local parts = {}
	if type(obj.errors) == "table" then
		for _, e in ipairs(obj.errors) do
			if type(e) == "string" and e ~= "" then
				table.insert(parts, e)
			end
		end
	end
	if #parts > 0 then
		return table.concat(parts, "\n")
	end
	if type(obj.result) == "string" and obj.result ~= "" then
		return obj.result
	end
	if type(obj.subtype) == "string" and obj.subtype ~= "" then
		return obj.subtype
	end
	return "unknown error"
end

--- Parse one line of `claude -p --output-format stream-json --verbose
--- --include-partial-messages` into the events the chat acts on:
---   { kind = "init" }                      the session exists on claude's side
---   { kind = "message_start" }             a new assistant message begins
---   { kind = "text", text }                a piece of the answer
---   { kind = "tool", name, input }         a tool call (from the complete assistant message)
---   { kind = "result", ok, text?, error? } the run's outcome
--- Unknown types, malformed lines and sub-agent output (`parent_tool_use_id`
--- set) yield no event. The answer text is taken from the partial deltas
--- only, since the complete assistant message repeats it.
--- @param line string|nil
--- @return table[] events
function M.parse_stream_line(line)
	if type(line) ~= "string" or vim.trim(line) == "" then
		return {}
	end
	local ok, obj = pcall(vim.json.decode, line)
	if not ok or type(obj) ~= "table" then
		return {}
	end

	if obj.type == "result" then
		if obj.is_error == true or obj.subtype ~= "success" then
			return { { kind = "result", ok = false, error = result_error(obj) } }
		end
		return { { kind = "result", ok = true, text = type(obj.result) == "string" and obj.result or "" } }
	end

	if obj.type == "system" then
		if obj.subtype == "init" then
			return { { kind = "init" } }
		end
		return {}
	end

	-- JSON null decodes to vim.NIL (userdata); a sub-agent line carries the id string.
	if type(obj.parent_tool_use_id) == "string" then
		return {}
	end

	if obj.type == "stream_event" then
		local event = obj.event
		if type(event) ~= "table" then
			return {}
		end
		if event.type == "message_start" then
			return { { kind = "message_start" } }
		end
		if event.type == "content_block_delta" then
			local delta = event.delta
			if type(delta) == "table" and delta.type == "text_delta" and type(delta.text) == "string" then
				if delta.text ~= "" then
					return { { kind = "text", text = delta.text } }
				end
			end
		end
		return {}
	end

	if obj.type == "assistant" then
		local message = obj.message
		local content = type(message) == "table" and message.content or nil
		if type(content) ~= "table" then
			return {}
		end
		local events = {}
		for _, block in ipairs(content) do
			if type(block) == "table" and block.type == "tool_use" and type(block.name) == "string" then
				table.insert(events, {
					kind = "tool",
					name = block.name,
					input = type(block.input) == "table" and block.input or {},
				})
			end
		end
		return events
	end

	return {}
end

--- Whether an error says that the session passed to `--resume` does not exist
--- (claude 2.1: "No conversation found with session ID: <id>").
--- @param err string|nil
--- @return boolean
function M.is_session_not_found(err)
	return type(err) == "string" and err:find("No conversation found with session ID", 1, true) ~= nil
end

--- Whether an error says that the id passed to `--session-id` already exists
--- (claude 2.1: "Session ID <id> is already in use.").
--- @param err string|nil
--- @return boolean
function M.is_session_in_use(err)
	return type(err) == "string" and err:find("Session ID", 1, true) ~= nil and err:find("already in use", 1, true) ~= nil
end

--- Decide how a failed run can be tried again with the other session
--- argument: a resumed session that does not exist starts over under a new id
--- (`"new"`), and a new id that turned out to exist — the earlier run created
--- the session but was stopped before saying so — is resumed (`"resume"`).
--- @param resumed boolean whether the failed run used `--resume`
--- @param err string|nil the run's error text
--- @return "new"|"resume"|nil
function M.find_session_retry(resumed, err)
	if resumed and M.is_session_not_found(err) then
		return "new"
	end
	if not resumed and M.is_session_in_use(err) then
		return "resume"
	end
	return nil
end

--- Longest tool detail shown before it is cut.
M.TOOL_DETAIL_WIDTH = 80

--- Cut a UTF-8 string to at most `max` characters, the last one being `…`
--- when something was cut. Never splits a multi-byte character.
--- @param text string
--- @param max number
--- @return string
local function truncate_chars(text, max)
	local chars = {}
	for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(chars, ch)
		if #chars > max then
			return table.concat(chars, "", 1, max - 1) .. "…"
		end
	end
	return text
end

--- Input field shown next to each known tool's name.
local TOOL_DETAIL_FIELDS = {
	Read = "file_path",
	Grep = "pattern",
	Glob = "pattern",
	Bash = "command",
}

--- One-line description of a tool call for the progress display, e.g.
--- `Read lua/fude/foo.lua` or `Bash git diff main...HEAD`. A path under
--- `root` is shown relative to it; a multi-line command shows its first line;
--- an unknown tool shows its name only.
--- @param name string tool name
--- @param input table|nil tool input
--- @param root string|nil repository root
--- @return string
function M.format_tool_use(name, input, root)
	name = type(name) == "string" and name or "?"
	local field = TOOL_DETAIL_FIELDS[name]
	local detail = (field and type(input) == "table") and input[field] or nil
	if type(detail) ~= "string" then
		return name
	end
	if field == "file_path" and type(root) == "string" and root ~= "" then
		local prefix = (root:gsub("/+$", "")) .. "/"
		if detail:sub(1, #prefix) == prefix then
			detail = detail:sub(#prefix + 1)
		end
	end
	detail = vim.trim(detail)
	detail = detail:match("^[^\r\n]*") or ""
	if detail == "" then
		return name
	end
	return name .. " " .. truncate_chars(detail, M.TOOL_DETAIL_WIDTH)
end

-- === Stored chat ===

M.STORE_VERSION = 1

--- Statuses an assistant message can be stored with.
local MESSAGE_STATUSES = { done = true, cancelled = true }

--- A chat with no session and no messages.
--- @return { session_id: string|nil, started: boolean, messages: table[] }
function M.build_empty_chat()
	return { session_id = nil, started = false, messages = {} }
end

--- Build one stored message.
--- @param role "user"|"assistant"
--- @param text string
--- @param status "done"|"cancelled"|nil assistant messages only: cancelled = stopped midway
--- @param at string|nil UTC ISO-8601 timestamp
--- @return { role: string, text: string, status: string|nil, at: string|nil }
function M.build_message(role, text, status, at)
	return { role = role, text = text, status = status, at = at }
end

--- Serialize a chat to the JSON stored on disk.
--- @param chat table { session_id, started, messages }
--- @param key string|nil the review target the chat belongs to (kept for inspection)
--- @return string
function M.serialize_chat(chat, key)
	chat = type(chat) == "table" and chat or M.build_empty_chat()
	local messages = {}
	for _, m in ipairs(type(chat.messages) == "table" and chat.messages or {}) do
		table.insert(messages, { role = m.role, text = m.text, status = m.status, at = m.at })
	end
	return vim.json.encode({
		version = M.STORE_VERSION,
		key = key,
		session_id = chat.session_id,
		started = chat.started == true,
		messages = messages,
	})
end

--- Deserialize a stored chat. The file may be hand-edited or corrupt, so every
--- field is checked: anything unusable falls back to the empty chat's value
--- (a session id that is not a UUID is dropped, since it is passed to claude's
--- command line), and messages without a known role or a string text are
--- skipped.
--- @param text string|nil
--- @return { session_id: string|nil, started: boolean, messages: table[] }
function M.deserialize_chat(text)
	local chat = M.build_empty_chat()
	if type(text) ~= "string" or text == "" then
		return chat
	end
	local ok, obj = pcall(vim.json.decode, text)
	if not ok or type(obj) ~= "table" then
		return chat
	end
	if M.is_uuid(obj.session_id) then
		chat.session_id = obj.session_id
		chat.started = obj.started == true
	end
	if type(obj.messages) == "table" then
		for _, m in ipairs(obj.messages) do
			if type(m) == "table" and (m.role == "user" or m.role == "assistant") and type(m.text) == "string" then
				table.insert(chat.messages, {
					role = m.role,
					text = m.text,
					status = (m.role == "assistant" and MESSAGE_STATUSES[m.status]) and m.status or nil,
					at = type(m.at) == "string" and m.at or nil,
				})
			end
		end
	end
	return chat
end

-- === Panel text ===

--- Headings of the two speakers in the conversation log.
M.USER_HEADING = "## You"
M.ASSISTANT_HEADING = "## Claude"
--- Line marking an answer that was stopped midway.
M.CANCELLED_MARK = "*(interrupted)*"
--- Line telling that claude's session was gone and a new one was started.
M.NEW_SESSION_NOTE = "*(The previous claude session was not found. Started a new one.)*"
--- Name shown for a buffer without a file name.
M.NO_NAME = "[No Name]"

--- Split a text into lines, accepting CRLF / CR line ends.
--- @param text string|nil
--- @return string[]
local function text_lines(text)
	text = (text or ""):gsub("\r\n", "\n")
	text = text:gsub("\r", "\n")
	return vim.split(text, "\n", { plain = true })
end

--- Lines opening one exchange in the log: the question under its heading,
--- then the answer's heading and an empty line the answer's text is written
--- onto.
--- @param prompt string
--- @return string[]
function M.format_question_lines(prompt)
	local lines = { M.USER_HEADING, "" }
	vim.list_extend(lines, text_lines(vim.trim(prompt or "")))
	-- The last, empty line is where the answer's text starts.
	vim.list_extend(lines, { "", M.ASSISTANT_HEADING, "", "" })
	return lines
end

--- Lines that end an answer in the log, after its text.
--- @param status "done"|"cancelled"|"error"
--- @param err string|nil error text (status "error")
--- @param has_text boolean|nil whether the log's last line holds text (a blank line is put before the mark then)
--- @return string[]
function M.format_answer_end_lines(status, err, has_text)
	local lines = {}
	if status == "cancelled" then
		if has_text then
			table.insert(lines, "")
		end
		table.insert(lines, M.CANCELLED_MARK)
	elseif status == "error" then
		if has_text then
			table.insert(lines, "")
		end
		local err_lines = text_lines(vim.trim(err or "unknown error"))
		table.insert(lines, "**Error:** " .. err_lines[1])
		for i = 2, #err_lines do
			table.insert(lines, err_lines[i])
		end
	end
	table.insert(lines, "")
	return lines
end

--- Lines of a stored conversation for the log buffer.
--- @param messages table[]|nil stored messages ({ role, text, status })
--- @return string[]
function M.format_chat_lines(messages)
	local lines = {}
	for _, m in ipairs(messages or {}) do
		if m.role == "user" then
			vim.list_extend(lines, M.format_question_lines(m.text))
		else
			-- The answer starts on the empty line the question lines end with.
			if lines[#lines] == "" then
				table.remove(lines)
			end
			local body = text_lines(m.text)
			vim.list_extend(lines, body)
			vim.list_extend(lines, M.format_answer_end_lines(m.status or "done", nil, body[#body] ~= ""))
		end
	end
	return lines
end

--- Text pasted into the chat input for a selection: a `<path>:L<start>-L<end>`
--- line (`<path>:L<line>` for one line) and the selected lines in a code fence
--- tagged with the filetype. The fence is longer than any backtick run in the
--- selection (at least three), so a selection holding a fence stays intact.
--- @param path string|nil repo-relative path; the caller passes the full path
---   for a file outside the repository and nil for an unnamed buffer (`[No Name]`)
--- @param start_line number 1-based first line
--- @param end_line number 1-based last line
--- @param lines string[] the selected lines
--- @param filetype string|nil
--- @return string[] lines to append to the input
function M.build_selection_text(path, start_line, end_line, lines, filetype)
	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end
	local name = (type(path) == "string" and path ~= "") and path or M.NO_NAME
	local range = start_line == end_line and ("L" .. start_line) or ("L" .. start_line .. "-L" .. end_line)
	local longest = 0
	for _, line in ipairs(lines or {}) do
		for run in line:gmatch("`+") do
			longest = math.max(longest, #run)
		end
	end
	local fence = string.rep("`", math.max(3, longest + 1))
	local out = { name .. ":" .. range, fence .. (type(filetype) == "string" and filetype or "") }
	vim.list_extend(out, lines or {})
	table.insert(out, fence)
	return out
end

--- Smallest width the chat panel is given when the editor allows it.
M.MIN_PANEL_WIDTH = 20

--- Width of the chat panel: the configured width, at least MIN_PANEL_WIDTH,
--- but never more than half the editor's columns (that bound wins), and at
--- least one column.
--- @param width any configured `chat.width`
--- @param columns number editor columns
--- @return number
function M.calculate_panel_width(width, columns)
	local wanted = math.max(M.MIN_PANEL_WIDTH, math.floor(tonumber(width) or 60))
	return math.max(1, math.min(wanted, math.floor(columns / 2)))
end

--- nvim_open_win split side for a `chat.position`.
--- @param position any "right" | "left" (anything else → "right")
--- @return "right"|"left"
function M.find_panel_split(position)
	return position == "left" and "left" or "right"
end

return M
