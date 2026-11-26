local helpers = require("tests.helpers")
local chat = require("fude.chat")
local data = require("fude.chat.data")
local config = require("fude.config")

local ID = "0b0e6f1c-7a52-4c1e-9d3a-5f6a7b8c9d01"

--- JSON line helpers shaped like claude 2.1's stream-json output.
local function text_line(text, parent)
	return vim.json.encode({
		type = "stream_event",
		event = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } },
		session_id = ID,
		parent_tool_use_id = parent or vim.NIL,
	})
end

local function message_start_line()
	return vim.json.encode({
		type = "stream_event",
		event = { type = "message_start", message = { role = "assistant" } },
		parent_tool_use_id = vim.NIL,
	})
end

local function init_line()
	return vim.json.encode({ type = "system", subtype = "init", session_id = ID })
end

local function tool_line(name, input, parent)
	return vim.json.encode({
		type = "assistant",
		message = {
			content = {
				{ type = "text", text = "looking" },
				{ type = "tool_use", id = "toolu_1", name = name, input = input },
			},
		},
		parent_tool_use_id = parent or vim.NIL,
	})
end

local function success_line(text)
	return vim.json.encode({ type = "result", subtype = "success", is_error = false, result = text, session_id = ID })
end

local function not_found_line(id)
	return vim.json.encode({
		type = "result",
		subtype = "error_during_execution",
		is_error = true,
		session_id = id,
		errors = { "No conversation found with session ID: " .. id },
	})
end

local function index_of(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
	return nil
end

describe("chat.build_tool_names", function()
	it("reduces tool specs to their built-in tool names, each once", function()
		assert.are.same(
			{ "Read", "Bash", "Grep" },
			data.build_tool_names({ "Read", "Bash(git diff:*)", "Bash(git log:*)", " Grep " })
		)
	end)

	it("leaves out MCP tools and unusable entries", function()
		assert.are.same({ "Read" }, data.build_tool_names({ "mcp__github__get_issue", 3, "", "Read" }))
		assert.are.same({}, data.build_tool_names(nil))
		assert.are.same({}, data.build_tool_names("Read"))
	end)
end)

describe("chat.build_claude_args", function()
	local defaults

	before_each(function()
		config.setup({})
		defaults = config.opts.chat
	end)

	it("starts the first question with --session-id and print-mode stream-json flags", function()
		local args = data.build_claude_args({ cmd = "claude", session_id = ID, resume = false })
		assert.are.equal("claude", args[1])
		assert.are.equal("-p", args[2])
		assert.are.equal("stream-json", args[index_of(args, "--output-format") + 1])
		assert.is_not_nil(index_of(args, "--verbose"))
		assert.is_not_nil(index_of(args, "--include-partial-messages"))
		assert.are.equal(ID, args[index_of(args, "--session-id") + 1])
		assert.is_nil(index_of(args, "--resume"))
	end)

	it("resumes the session on later questions", function()
		local args = data.build_claude_args({ session_id = ID, resume = true })
		assert.are.equal(ID, args[index_of(args, "--resume") + 1])
		assert.is_nil(index_of(args, "--session-id"))
	end)

	it("does not put the question on the command line", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = defaults.allowed_tools })
		-- Every argument after "-p" up to the first value-taking flag is a flag:
		-- no positional prompt that a variadic option could swallow.
		assert.are.equal("--output-format", args[3])
	end)

	it("makes only read-only tools exist with the default allowed tools", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = defaults.allowed_tools })
		assert.are.equal("Read,Grep,Glob,Bash", args[index_of(args, "--tools") + 1])
		assert.are.equal("dontAsk", args[index_of(args, "--permission-mode") + 1])
		for _, arg in ipairs(args) do
			assert.is_nil(arg:match("^Edit"))
			assert.is_nil(arg:match("^Write"))
			assert.is_nil(arg:match("^NotebookEdit"))
			-- Bash only in restricted forms, never bare
			assert.are_not.equal("Bash", arg)
		end
	end)

	it("passes every allowed tool as its own --allowedTools argument", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = defaults.allowed_tools })
		local start = index_of(args, "--allowedTools")
		assert.is_not_nil(start)
		for i, spec in ipairs(defaults.allowed_tools) do
			assert.are.equal(spec, args[start + i])
		end
		assert.is_not_nil(index_of(args, "Bash(git diff:*)"))
		assert.is_not_nil(index_of(args, "Bash(gh pr view:*)"))
	end)

	it("passes a deny rule given as extra arguments after the allowed tools, as its own option", function()
		local extra = { "--disallowedTools", "Bash(git *--output*)" }
		local args = data.build_claude_args({
			session_id = ID,
			allowed_tools = defaults.allowed_tools,
			system_prompt = "ctx",
			extra_args = extra,
		})
		local deny = index_of(args, "--disallowedTools")
		assert.are.equal("Bash(git *--output*)", args[deny + 1])
		assert.are.equal(deny + 1, #args)
		-- the variadic --allowedTools list is closed by an option before it
		assert.is_true(index_of(args, "--allowedTools") < deny)
		assert.are.equal("ctx", args[deny - 1])
		-- also without a system prompt: the option itself ends the allow list
		local bare = data.build_claude_args({ session_id = ID, allowed_tools = { "Read" }, extra_args = extra })
		assert.are.same(
			{ "--allowedTools", "Read", "--disallowedTools", "Bash(git *--output*)" },
			vim.list_slice(bare, #bare - 3)
		)
	end)

	it("reads only the user's settings when asked to", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = { "Read" }, user_settings_only = true })
		assert.are.equal("user", args[index_of(args, "--setting-sources") + 1])
		-- in front of the variadic tool options
		assert.is_true(index_of(args, "--setting-sources") < index_of(args, "--allowedTools"))
	end)

	it("does not restrict the settings sources unless asked to", function()
		assert.is_nil(index_of(data.build_claude_args({ session_id = ID }), "--setting-sources"))
		assert.is_nil(
			index_of(data.build_claude_args({ session_id = ID, user_settings_only = false }), "--setting-sources")
		)
	end)

	it("leaves the settings sources to the extra arguments when they set them", function()
		for _, extra in ipairs({
			{ "--setting-sources", "user,project,local" },
			{ "--model", "sonnet", "--setting-sources=user,project,local" },
		}) do
			local args = data.build_claude_args({ session_id = ID, user_settings_only = true, extra_args = extra })
			local count = 0
			for _, arg in ipairs(args) do
				if arg:find("^%-%-setting%-sources") then
					count = count + 1
				end
			end
			assert.are.equal(1, count)
			assert.is_nil(index_of(args, "user"))
		end
	end)

	it("recognises --setting-sources among extra arguments", function()
		assert.is_true(data.has_setting_sources({ "--setting-sources", "user" }))
		assert.is_true(data.has_setting_sources({ "--x", "--setting-sources=project" }))
		assert.is_false(data.has_setting_sources({ "--setting-sourcesx", "--model", "sonnet", 5 }))
		assert.is_false(data.has_setting_sources({}))
		assert.is_false(data.has_setting_sources(nil))
	end)

	it("offers no tool at all for an empty allowed list", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = {} })
		assert.are.equal("", args[index_of(args, "--tools") + 1])
		assert.is_nil(index_of(args, "--allowedTools"))
	end)

	it("follows a configured tool list", function()
		local args = data.build_claude_args({ session_id = ID, allowed_tools = { "Read", "Edit" } })
		assert.are.equal("Read,Edit", args[index_of(args, "--tools") + 1])
		assert.are.equal("Edit", args[index_of(args, "--allowedTools") + 2])
	end)

	it("appends the system prompt only when there is one", function()
		local with = data.build_claude_args({ session_id = ID, system_prompt = "Review target: X" })
		assert.are.equal("Review target: X", with[index_of(with, "--append-system-prompt") + 1])
		local without = data.build_claude_args({ session_id = ID })
		assert.is_nil(index_of(without, "--append-system-prompt"))
	end)

	it("puts the extra arguments last and uses the configured command", function()
		local args = data.build_claude_args({
			cmd = "/opt/bin/claude",
			session_id = ID,
			allowed_tools = { "Read" },
			system_prompt = "ctx",
			extra_args = { "--model", "sonnet" },
		})
		assert.are.equal("/opt/bin/claude", args[1])
		assert.are.equal("--model", args[#args - 1])
		assert.are.equal("sonnet", args[#args])
	end)
end)

describe("chat.build_system_prompt", function()
	it("describes a GitHub review by PR number, URL and branches", function()
		local text = data.build_system_prompt({
			review_mode = "github",
			pr_number = 42,
			pr_url = "https://github.com/o/r/pull/42",
			base_ref = "main",
			head_ref = "feat/x",
		})
		assert.truthy(text:find("pull request #42", 1, true))
		assert.truthy(text:find("URL: https://github.com/o/r/pull/42", 1, true))
		assert.truthy(text:find("Base branch: main", 1, true))
		assert.truthy(text:find("Head branch: feat/x", 1, true))
	end)

	it("describes a local review by its branch only, leaving out what can change", function()
		local text = data.build_system_prompt({
			review_mode = "local",
			local_session = { branch = "feat/y", base_ref = "develop", scope = "uncommitted" },
		})
		assert.truthy(text:find("local review", 1, true))
		assert.truthy(text:find("Branch: feat/y", 1, true))
		assert.is_nil(text:find("pull request #", 1, true))
		-- the base branch and the scope travel with each question instead
		assert.is_nil(text:find("develop", 1, true))
		assert.is_nil(text:find("uncommitted", 1, true))
	end)

	it("skips fields that are missing or JSON null", function()
		local text = data.build_system_prompt({ pr_number = 7, pr_url = vim.NIL, base_ref = "main" })
		assert.truthy(text:find("pull request #7", 1, true))
		assert.is_nil(text:find("URL:", 1, true))
		assert.is_nil(text:find("Head branch", 1, true))
	end)

	it("returns nil without a review target", function()
		assert.is_nil(data.build_system_prompt(nil))
		assert.is_nil(data.build_system_prompt({}))
		assert.is_nil(data.build_system_prompt({ review_mode = "local" }))
	end)
end)

describe("chat.build_prompt_context", function()
	it("names the checked-out commit in a GitHub review's commit scope", function()
		local lines = data.build_prompt_context({
			review_mode = "github",
			pr_number = 1,
			scope = "commit",
			scope_commit_sha = "abc1234def",
		})
		assert.are.equal(1, #lines)
		assert.truthy(lines[1]:find("scope: commit abc1234def", 1, true))
		assert.truthy(lines[1]:find("checked out", 1, true))
		-- the same wording as a local review's commit scope
		local localc = data.build_prompt_context({
			review_mode = "local",
			local_session = { scope = "commit", scope_commit_sha = "abc1234def" },
		})
		assert.are.equal(lines[1], localc[1])
		assert.truthy(
			data.build_prompt_context({ review_mode = "github", scope = "commit" })[1]:find("scope: commit ?", 1, true)
		)
	end)

	it("adds nothing in a GitHub review of the whole pull request", function()
		assert.are.same(
			{},
			data.build_prompt_context({ review_mode = "github", pr_number = 1, scope = "full_pr", scope_commit_sha = "abc" })
		)
		assert.are.same({}, data.build_prompt_context({ review_mode = "github", pr_number = 1, base_ref = "main" }))
		assert.are.same({}, data.build_prompt_context(nil))
		assert.are.same({}, data.build_prompt_context({ review_mode = "local" }))
	end)

	it("gives the base branch and the scope of a local review in one line", function()
		local lines = data.build_prompt_context({
			review_mode = "local",
			local_session = { branch = "feat/y", base_ref = "develop", scope = "uncommitted" },
		})
		assert.are.equal(1, #lines)
		assert.truthy(lines[1]:find("base branch: develop", 1, true))
		assert.truthy(lines[1]:find("scope: uncommitted", 1, true))
	end)

	it("names the commit in the local commit scope", function()
		local lines = data.build_prompt_context({
			review_mode = "local",
			local_session = { base_ref = "main", scope = "commit", scope_commit_sha = "abc123" },
		})
		assert.truthy(lines[1]:find("scope: commit abc123", 1, true))
	end)

	it("skips what is missing", function()
		local lines = data.build_prompt_context({ review_mode = "local", local_session = { scope = "base" } })
		assert.truthy(lines[1]:find("scope: base", 1, true))
		assert.is_nil(lines[1]:find("base branch:", 1, true))
		assert.are.same({}, data.build_prompt_context({ review_mode = "local", local_session = {} }))
	end)
end)

describe("chat.build_prompt_input", function()
	it("puts the context lines and a blank line before the question", function()
		assert.are.equal("[ctx]\n\nwhy?\nreally", data.build_prompt_input({ "[ctx]" }, "why?\nreally"))
	end)

	it("returns the question alone without context", function()
		assert.are.equal("why?", data.build_prompt_input({}, "why?"))
		assert.are.equal("why?", data.build_prompt_input(nil, "why?"))
	end)
end)

describe("chat.split_stream_chunk", function()
	it("returns complete lines and keeps the unfinished tail", function()
		local lines, rest = data.split_stream_chunk("", "one\ntwo\nthr")
		assert.are.same({ "one", "two" }, lines)
		assert.are.equal("thr", rest)
	end)

	it("joins the tail with the next chunk", function()
		local lines, rest = data.split_stream_chunk("thr", "ee\nfour\n")
		assert.are.same({ "three", "four" }, lines)
		assert.are.equal("", rest)
	end)

	it("keeps a chunk without a newline as the tail", function()
		local lines, rest = data.split_stream_chunk("ab", "cd")
		assert.are.same({}, lines)
		assert.are.equal("abcd", rest)
	end)

	it("drops blank lines and CR line endings", function()
		local lines, rest = data.split_stream_chunk(nil, "a\r\n\nb\n")
		assert.are.same({ "a", "b" }, lines)
		assert.are.equal("", rest)
	end)
end)

describe("chat.parse_stream_line", function()
	it("returns a text event for a text delta", function()
		assert.are.same({ { kind = "text", text = "hi" } }, data.parse_stream_line(text_line("hi")))
	end)

	it("ignores sub-agent output", function()
		assert.are.same({}, data.parse_stream_line(text_line("hi", "toolu_parent")))
		assert.are.same({}, data.parse_stream_line(tool_line("Read", { file_path = "/r/a.lua" }, "toolu_parent")))
	end)

	it("returns tool events from a complete assistant message, not its text", function()
		local events = data.parse_stream_line(tool_line("Read", { file_path = "/r/a.lua" }))
		assert.are.same({ { kind = "tool", name = "Read", input = { file_path = "/r/a.lua" } } }, events)
	end)

	it("ignores partial tool input deltas and other stream events", function()
		local line = vim.json.encode({
			type = "stream_event",
			event = { type = "content_block_delta", delta = { type = "input_json_delta", partial_json = '{"a"' } },
			parent_tool_use_id = vim.NIL,
		})
		assert.are.same({}, data.parse_stream_line(line))
		local stop = vim.json.encode({ type = "stream_event", event = { type = "message_stop" } })
		assert.are.same({}, data.parse_stream_line(stop))
	end)

	it("marks the start of an assistant message", function()
		assert.are.same({ { kind = "message_start" } }, data.parse_stream_line(message_start_line()))
	end)

	it("reports the init line only among system lines", function()
		assert.are.same({ { kind = "init" } }, data.parse_stream_line(init_line()))
		local hook = vim.json.encode({ type = "system", subtype = "hook_started", session_id = ID })
		assert.are.same({}, data.parse_stream_line(hook))
	end)

	it("returns the full text of a successful result", function()
		assert.are.same({ { kind = "result", ok = true, text = "all" } }, data.parse_stream_line(success_line("all")))
	end)

	it("returns the errors of a failed result", function()
		local events = data.parse_stream_line(not_found_line(ID))
		assert.are.equal(1, #events)
		assert.is_false(events[1].ok)
		assert.are.equal("No conversation found with session ID: " .. ID, events[1].error)
	end)

	it("treats is_error with a result text as a failure carrying that text", function()
		local line = vim.json.encode({ type = "result", subtype = "success", is_error = true, result = "API Error: 529" })
		assert.are.same({ { kind = "result", ok = false, error = "API Error: 529" } }, data.parse_stream_line(line))
	end)

	it("falls back to the subtype for a failed result without details", function()
		local line = vim.json.encode({ type = "result", subtype = "error_max_turns", is_error = true })
		assert.are.equal("error_max_turns", data.parse_stream_line(line)[1].error)
	end)

	it("ignores unknown types, malformed JSON and non-strings", function()
		assert.are.same({}, data.parse_stream_line(vim.json.encode({ type = "rate_limit_event" })))
		assert.are.same({}, data.parse_stream_line(vim.json.encode({ type = "user", message = { content = {} } })))
		assert.are.same({}, data.parse_stream_line('{"type":"stream_ev'))
		assert.are.same({}, data.parse_stream_line("[1,2]"))
		assert.are.same({}, data.parse_stream_line(""))
		assert.are.same({}, data.parse_stream_line(nil))
	end)

	it("survives JSON null in nested fields", function()
		local line = vim.json.encode({ type = "stream_event", event = vim.NIL })
		assert.are.same({}, data.parse_stream_line(line))
		local assistant = vim.json.encode({ type = "assistant", message = { content = vim.NIL } })
		assert.are.same({}, data.parse_stream_line(assistant))
	end)
end)

describe("chat session errors", function()
	it("recognises a resumed session that does not exist", function()
		assert.is_true(data.is_session_not_found("No conversation found with session ID: " .. ID))
		assert.is_false(data.is_session_not_found("API Error: 500"))
		assert.is_false(data.is_session_not_found(nil))
	end)

	it("recognises a session id that is already in use", function()
		assert.is_true(data.is_session_in_use("Error: Session ID " .. ID .. " is already in use."))
		assert.is_false(data.is_session_in_use("No conversation found with session ID: " .. ID))
	end)

	it("retries a missing resumed session under a new id only", function()
		assert.are.equal("new", data.find_session_retry(true, "No conversation found with session ID: x"))
		assert.is_nil(data.find_session_retry(false, "No conversation found with session ID: x"))
		assert.is_nil(data.find_session_retry(true, "API Error: 500"))
	end)

	it("retries an id already in use by resuming it", function()
		assert.are.equal("resume", data.find_session_retry(false, "Error: Session ID x is already in use."))
		assert.is_nil(data.find_session_retry(true, "Error: Session ID x is already in use."))
	end)
end)

describe("chat.format_tool_use", function()
	it("shows a read path relative to the repository root", function()
		assert.are.equal(
			"Read lua/fude/foo.lua",
			data.format_tool_use("Read", { file_path = "/repo/lua/fude/foo.lua" }, "/repo")
		)
	end)

	it("keeps a path outside the root, including a sibling with the same prefix", function()
		assert.are.equal(
			"Read /repo-other/a.lua",
			data.format_tool_use("Read", { file_path = "/repo-other/a.lua" }, "/repo")
		)
	end)

	it("shows the pattern of Grep / Glob and the first line of a Bash command", function()
		assert.are.equal("Grep build_%w+", data.format_tool_use("Grep", { pattern = "build_%w+" }))
		assert.are.equal("Glob **/*.lua", data.format_tool_use("Glob", { pattern = "**/*.lua" }))
		assert.are.equal("Bash git log -3", data.format_tool_use("Bash", { command = "git log -3\necho x" }))
	end)

	it("shows only the name for unknown tools or missing input", function()
		assert.are.equal("WebFetch", data.format_tool_use("WebFetch", { url = "https://example.com" }))
		assert.are.equal("Read", data.format_tool_use("Read", nil))
		assert.are.equal("Read", data.format_tool_use("Read", { file_path = vim.NIL }))
	end)

	it("cuts a long detail without splitting a multi-byte character", function()
		local label = data.format_tool_use("Bash", { command = string.rep("あ", 200) })
		assert.are.equal("Bash " .. string.rep("あ", data.TOOL_DETAIL_WIDTH - 1) .. "…", label)
	end)
end)

describe("chat stored format", function()
	it("round-trips session id, started flag and messages", function()
		local stored = {
			session_id = ID,
			started = true,
			messages = {
				data.build_message("user", "why?", nil, "2099-01-01T00:00:00Z"),
				data.build_message("assistant", "because\n\nline", "cancelled", "2099-01-01T00:00:01Z"),
			},
		}
		assert.are.same(stored, data.deserialize_chat(data.serialize_chat(stored, "o/r:#1:chat")))
	end)

	it("does not keep a directory with the conversation", function()
		local text = vim.json.encode({ session_id = ID, started = true, root = "/old/worktree", messages = {} })
		assert.is_nil(data.deserialize_chat(text).root)
	end)

	it("round-trips an empty chat", function()
		assert.are.same(data.build_empty_chat(), data.deserialize_chat(data.serialize_chat(data.build_empty_chat())))
	end)

	it("returns an empty chat for missing or corrupt text", function()
		assert.are.same(data.build_empty_chat(), data.deserialize_chat(nil))
		assert.are.same(data.build_empty_chat(), data.deserialize_chat(""))
		assert.are.same(data.build_empty_chat(), data.deserialize_chat("{not json"))
		assert.are.same(data.build_empty_chat(), data.deserialize_chat('"text"'))
	end)

	it("drops a session id that is not a lowercase UUID, with its started flag", function()
		local text = vim.json.encode({ session_id = "--dangerously-skip-permissions", started = true, messages = {} })
		local loaded = data.deserialize_chat(text)
		assert.is_nil(loaded.session_id)
		assert.is_false(loaded.started)
		assert.is_nil(data.deserialize_chat(vim.json.encode({ session_id = ID:upper() })).session_id)
	end)

	it("skips messages of the wrong shape and unknown statuses", function()
		local text = vim.json.encode({
			session_id = ID,
			messages = {
				{ role = "user", text = "q" },
				{ role = "system", text = "x" },
				{ role = "assistant", text = 5 },
				"junk",
				{ role = "assistant", text = "a", status = "exploded", at = 12 },
			},
		})
		assert.are.same({
			{ role = "user", text = "q" },
			{ role = "assistant", text = "a" },
		}, data.deserialize_chat(text).messages)
	end)

	it("accepts only lowercase hyphenated UUIDs", function()
		assert.is_true(data.is_uuid(ID))
		assert.is_true(data.is_uuid(require("fude.local.store").generate_uuid()))
		assert.is_false(data.is_uuid(ID:upper()))
		assert.is_false(data.is_uuid(ID .. "0"))
		assert.is_false(data.is_uuid(nil))
	end)
end)

describe("chat storage", function()
	local tmp_dir

	before_each(function()
		config.setup({})
		tmp_dir = vim.fn.tempname()
		chat._dir = tmp_dir
	end)

	after_each(function()
		chat._dir = nil
		vim.fn.delete(tmp_dir, "rf")
		helpers.cleanup()
	end)

	it("keys a GitHub review by repo and PR number", function()
		local a = chat.current_key({ pr_number = 1, pr_url = "https://github.com/o/r/pull/1" })
		local b = chat.current_key({ pr_number = 2, pr_url = "https://github.com/o/r/pull/2" })
		local c = chat.current_key({ pr_number = 1, pr_url = "https://github.com/o/other/pull/1" })
		assert.are.equal("o/r:#1:chat", a)
		assert.are_not.equal(a, b)
		assert.are_not.equal(a, c)
	end)

	it("keys a local review by worktree and branch", function()
		local a = chat.current_key({ review_mode = "local", local_session = { worktree_root = "/w", branch = "x" } })
		local b = chat.current_key({ review_mode = "local", local_session = { worktree_root = "/w", branch = "y" } })
		assert.are.equal("local:/w:#x:chat", a)
		assert.are_not.equal(a, b)
	end)

	it("has no key without a review target", function()
		assert.is_nil(chat.current_key({}))
		assert.is_nil(chat.current_key())
	end)

	it("saves and loads a chat under the state directory", function()
		local stored = { session_id = ID, started = true, messages = { data.build_message("user", "q") } }
		assert.is_true(chat.save("o/r:#1:chat", stored))
		assert.are.same(stored, chat.load("o/r:#1:chat"))
		local files = vim.fn.glob(tmp_dir .. "/chat/*.json", false, true)
		assert.are.equal(1, #files)
		assert.are.same({}, vim.fn.glob(tmp_dir .. "/chat/*.tmp", false, true))
	end)

	it("keeps the chats of different targets apart", function()
		chat.save("o/r:#1:chat", { session_id = ID, started = true, messages = {} })
		assert.are.same(data.build_empty_chat(), chat.load("o/r:#2:chat"))
		assert.are.equal(ID, chat.load("o/r:#1:chat").session_id)
	end)

	it("loads an empty chat when nothing is stored or the file is corrupt", function()
		assert.are.same(data.build_empty_chat(), chat.load("o/r:#1:chat"))
		chat.save("o/r:#1:chat", { session_id = ID, started = true, messages = {} })
		local file = vim.fn.glob(tmp_dir .. "/chat/*.json", false, true)[1]
		vim.fn.writefile({ "{broken" }, file)
		assert.are.same(data.build_empty_chat(), chat.load("o/r:#1:chat"))
		assert.are.same(data.build_empty_chat(), chat.load(nil))
	end)

	it("reports a failed save", function()
		-- A file where the storage directory should be
		vim.fn.writefile({ "x" }, tmp_dir)
		local ok, err = chat.save("o/r:#1:chat", data.build_empty_chat())
		assert.is_false(ok)
		assert.is_string(err)
		assert.is_false((chat.save(nil, data.build_empty_chat())))
	end)

	it("discards only the given target's chat", function()
		chat.save("o/r:#1:chat", { session_id = ID, started = true, messages = { data.build_message("user", "q") } })
		chat.save("o/r:#2:chat", { session_id = ID, started = true, messages = {} })
		assert.is_true(chat.discard("o/r:#1:chat"))
		assert.are.same(data.build_empty_chat(), chat.load("o/r:#1:chat"))
		assert.are.equal(ID, chat.load("o/r:#2:chat").session_id)
		-- nothing stored: still a success
		assert.is_true(chat.discard("o/r:#1:chat"))
	end)

	it("refuses to discard without a review target", function()
		local ok, err = chat.discard()
		assert.is_false(ok)
		assert.is_string(err)
	end)
end)

describe("chat.is_available", function()
	after_each(function()
		helpers.cleanup()
	end)

	it("follows whether chat.cmd is executable", function()
		config.setup({ chat = { cmd = "fude-no-such-claude-command" } })
		assert.is_false(chat.is_available())
		-- nvim itself is always on PATH while the tests run
		config.setup({ chat = { cmd = vim.v.progpath } })
		assert.is_true(chat.is_available())
	end)

	it("is false for an unusable setting", function()
		config.setup({ chat = { cmd = "" } })
		assert.is_false(chat.is_available())
	end)
end)

describe("chat.send", function()
	local tmp_dir
	local KEY = "o/r:#7:chat"
	local runs
	local events

	--- Handlers that record what the chat reports.
	local function handlers()
		return {
			on_text = function(text)
				table.insert(events, { "text", text })
			end,
			on_tool = function(label)
				table.insert(events, { "tool", label })
			end,
			on_retry = function(kind)
				table.insert(events, { "retry", kind })
			end,
			on_done = function(result)
				table.insert(events, { "done", result })
			end,
		}
	end

	local function done_result()
		for _, e in ipairs(events) do
			if e[1] == "done" then
				return e[2]
			end
		end
		return nil
	end

	before_each(function()
		config.setup({})
		tmp_dir = vim.fn.tempname()
		chat._dir = tmp_dir
		runs = {}
		events = {}
		config.state.active = true
		config.state.review_mode = "github"
		config.state.pr_number = 7
		config.state.pr_url = "https://github.com/o/r/pull/7"
		config.state.base_ref = "main"
		config.state.head_ref = "feat"
		config.state.repo_root = "/repo"
		-- Never start a real claude: record the call and let the test feed output.
		helpers.mock(chat, "run", function(cmd, opts, on_chunk, on_exit)
			local run = { cmd = cmd, opts = opts, chunk = on_chunk, exit = on_exit, killed = false }
			table.insert(runs, run)
			return {
				kill = function()
					run.killed = true
				end,
			}
		end)
	end)

	after_each(function()
		chat._reset()
		chat._dir = nil
		vim.fn.delete(tmp_dir, "rf")
		helpers.cleanup()
	end)

	it("runs claude in the repo root with the question on stdin and a new session id", function()
		assert.is_true(chat.send("why this change?", handlers()))
		assert.are.equal(1, #runs)
		local run = runs[1]
		assert.are.equal("/repo", run.opts.cwd)
		assert.are.equal("why this change?", run.opts.stdin)
		assert.is_nil(index_of(run.cmd, "why this change?"))
		local id = run.cmd[index_of(run.cmd, "--session-id") + 1]
		assert.is_true(data.is_uuid(id))
		-- the id is stored before any answer arrives
		assert.are.equal(id, chat.load(KEY).session_id)
		assert.is_false(chat.load(KEY).started)
		assert.is_true(chat.is_running())
		assert.is_true(chat.is_running(KEY))
		assert.is_false(chat.is_running("o/r:#8:chat"))
	end)

	it("passes the configured command, tools, extra arguments and the review target", function()
		config.setup({ chat = { cmd = "my-claude", allowed_tools = { "Read" }, args = { "--model", "sonnet" } } })
		chat.send("q", handlers())
		local cmd = runs[1].cmd
		assert.are.equal("my-claude", cmd[1])
		assert.are.equal("Read", cmd[index_of(cmd, "--tools") + 1])
		assert.are.equal("sonnet", cmd[#cmd])
		local prompt = cmd[index_of(cmd, "--append-system-prompt") + 1]
		assert.truthy(prompt:find("pull request #7", 1, true))
		assert.truthy(prompt:find("Head branch: feat", 1, true))
	end)

	it("sends the local scope and base with the question, but keeps them out of the stored chat", function()
		config.reset_state()
		config.state.active = true
		config.state.review_mode = "local"
		config.state.local_session =
			{ id = "s1", worktree_root = "/repo", branch = "feat", base_ref = "main", scope = "unpushed" }
		chat.send("why?", handlers())
		local stdin = runs[1].opts.stdin
		assert.truthy(stdin:find("base branch: main", 1, true))
		assert.truthy(stdin:find("scope: unpushed", 1, true))
		assert.are.equal("\n\nwhy?", stdin:sub(-#"\n\nwhy?"))
		local system = runs[1].cmd[index_of(runs[1].cmd, "--append-system-prompt") + 1]
		assert.is_nil(system:find("unpushed", 1, true))

		-- the scope changes: the next question carries the new one
		runs[1].chunk(init_line() .. "\n" .. success_line("a") .. "\n")
		runs[1].exit(0, "")
		assert.are.equal("why?", done_result().prompt)
		config.state.local_session.scope = "uncommitted"
		chat.send("and now?", handlers())
		assert.truthy(runs[2].opts.stdin:find("scope: uncommitted", 1, true))

		local stored = chat.load(chat.current_key())
		assert.are.equal("why?", stored.messages[1].text)
	end)

	it("streams text as it arrives, across chunk boundaries", function()
		chat.send("q", handlers())
		local line = text_line("Hello") .. "\n" .. text_line(", world") .. "\n"
		local cut = math.floor(#line / 3)
		runs[1].chunk(line:sub(1, cut))
		assert.are.same({}, events)
		runs[1].chunk(line:sub(cut + 1))
		assert.are.same({ { "text", "Hello" }, { "text", ", world" } }, events)
	end)

	it("reports tool calls with a path relative to the repo root", function()
		chat.send("q", handlers())
		runs[1].chunk(tool_line("Read", { file_path = "/repo/lua/fude/foo.lua" }) .. "\n")
		assert.are.same({ { "tool", "Read lua/fude/foo.lua" } }, events)
	end)

	it("separates the text of messages before and after a tool call", function()
		chat.send("q", handlers())
		runs[1].chunk(message_start_line() .. "\n" .. text_line("Let me look.") .. "\n")
		runs[1].chunk(message_start_line() .. "\n" .. text_line("Found it.") .. "\n")
		runs[1].chunk(success_line("Found it.") .. "\n")
		runs[1].exit(0, "")
		assert.are.equal("Let me look.\n\nFound it.", done_result().text)
	end)

	it("stores the question and the answer when the run succeeds", function()
		chat.send("q1", handlers())
		runs[1].chunk(init_line() .. "\n" .. text_line("answer") .. "\n" .. success_line("answer") .. "\n")
		runs[1].exit(0, "")
		local result = done_result()
		assert.are.equal("done", result.status)
		assert.are.equal("answer", result.text)
		assert.is_false(chat.is_running())
		local stored = chat.load(KEY)
		assert.is_true(stored.started)
		assert.are.equal(2, #stored.messages)
		assert.are.equal("user", stored.messages[1].role)
		assert.are.equal("q1", stored.messages[1].text)
		assert.are.equal("assistant", stored.messages[2].role)
		assert.are.equal("answer", stored.messages[2].text)
		assert.are.equal("done", stored.messages[2].status)
	end)

	it("resumes the same session on the next question", function()
		chat.send("q1", handlers())
		local id = runs[1].cmd[index_of(runs[1].cmd, "--session-id") + 1]
		runs[1].chunk(init_line() .. "\n" .. success_line("a1") .. "\n")
		runs[1].exit(0, "")
		chat.send("q2", handlers())
		assert.are.equal(id, runs[2].cmd[index_of(runs[2].cmd, "--resume") + 1])
		assert.is_nil(index_of(runs[2].cmd, "--session-id"))
	end)

	it("continues a session restored from disk", function()
		chat.save(KEY, { session_id = ID, started = true, messages = { data.build_message("user", "old") } })
		chat.send("q", handlers())
		assert.are.equal(ID, runs[1].cmd[index_of(runs[1].cmd, "--resume") + 1])
		runs[1].chunk(success_line("a") .. "\n")
		runs[1].exit(0, "")
		assert.are.equal(3, #chat.load(KEY).messages)
		assert.are.equal("old", chat.load(KEY).messages[1].text)
	end)

	it("keeps --session-id until claude reported the session", function()
		chat.send("q1", handlers())
		local id = runs[1].cmd[index_of(runs[1].cmd, "--session-id") + 1]
		-- failed before the init line: the session was never created
		runs[1].exit(1, "Not logged in")
		chat.send("q1", handlers())
		assert.are.equal(id, runs[2].cmd[index_of(runs[2].cmd, "--session-id") + 1])
	end)

	it("uses the result text when no partial text arrived", function()
		chat.send("q", handlers())
		runs[1].chunk(success_line("whole answer") .. "\n")
		runs[1].exit(0, "")
		assert.are.equal("whole answer", done_result().text)
		assert.are.equal("whole answer", chat.load(KEY).messages[2].text)
	end)

	it("handles a last line without a trailing newline", function()
		chat.send("q", handlers())
		runs[1].chunk(success_line("tail"))
		runs[1].exit(0, "")
		assert.are.equal("done", done_result().status)
		assert.are.equal("tail", done_result().text)
	end)

	it("refuses a second question while one is being answered", function()
		chat.send("q1", handlers())
		local ok, reason = chat.send("q2", handlers())
		assert.is_false(ok)
		assert.are.equal(chat.ERR_BUSY, reason)
		assert.are.equal(1, #runs)
	end)

	it("refuses an empty question", function()
		local ok, reason = chat.send("  \n ", handlers())
		assert.is_false(ok)
		assert.are.equal(chat.ERR_EMPTY, reason)
		assert.are.equal(0, #runs)
		assert.is_false(chat.is_running())
	end)

	it("refuses without a review target or a review root", function()
		config.state.repo_root = nil
		assert.are.same({ false, chat.ERR_NO_ROOT }, { chat.send("q", handlers()) })
		config.reset_state()
		assert.are.same({ false, chat.ERR_NO_TARGET }, { chat.send("q", handlers()) })
		assert.are.equal(0, #runs)
	end)

	it("stores nothing of a question that failed before claude opened the session", function()
		chat.send("q", handlers())
		local line = vim.json.encode({ type = "result", subtype = "success", is_error = true, result = "API Error: 529" })
		runs[1].chunk(line .. "\n")
		runs[1].exit(1, "")
		local result = done_result()
		assert.are.equal("error", result.status)
		assert.are.equal("API Error: 529", result.error)
		assert.are.equal("q", result.prompt)
		assert.is_false(result.stored)
		assert.are.same({}, chat.load(KEY).messages)
		assert.is_false(chat.is_running())
	end)

	it("stores a failure after claude took the question, with the partial answer and the error", function()
		chat.send("q", handlers())
		local line = vim.json.encode({ type = "result", subtype = "error_max_turns", is_error = true })
		runs[1].chunk(init_line() .. "\n" .. text_line("half an answer") .. "\n" .. line .. "\n")
		runs[1].exit(1, "")
		local result = done_result()
		assert.are.equal("error", result.status)
		-- the question is in claude's session: it is not handed back for a resend
		assert.is_true(result.stored)
		local messages = chat.load(KEY).messages
		assert.are.equal(2, #messages)
		assert.are.equal("q", messages[1].text)
		assert.are.equal("half an answer", messages[2].text)
		assert.are.equal("error", messages[2].status)
		assert.are.equal(result.error, messages[2].error)
		-- reopening shows the error where the live conversation showed it
		local lines = data.format_chat_lines(messages)
		assert.is_true(vim.tbl_contains(lines, "**Error:** " .. result.error))
		-- and the next question continues that session
		chat.send("q2", handlers())
		assert.is_not_nil(index_of(runs[2].cmd, "--resume"))
	end)

	it("reports stderr for a non-zero exit without a result", function()
		chat.send("q", handlers())
		runs[1].exit(1, "Not logged in\n")
		assert.are.equal("error", done_result().status)
		assert.are.equal("Not logged in", done_result().error)
	end)

	it("takes a clean exit with answer text as an answer despite stderr output", function()
		chat.send("q", handlers())
		runs[1].chunk(init_line() .. "\n" .. text_line("the answer") .. "\n")
		runs[1].exit(0, "warning: something is deprecated\n")
		assert.are.equal("done", done_result().status)
		assert.are.equal("the answer", done_result().text)
		assert.are.equal("the answer", chat.load(KEY).messages[2].text)
	end)

	it("reports stderr for a clean exit that produced no answer", function()
		chat.send("q", handlers())
		runs[1].exit(0, "something went wrong\n")
		assert.are.equal("error", done_result().status)
		assert.are.equal("something went wrong", done_result().error)
	end)

	it("reports stderr when a failed run produced partial text", function()
		chat.send("q", handlers())
		runs[1].chunk(text_line("partial") .. "\n")
		runs[1].exit(1, "connection lost\n")
		assert.are.equal("error", done_result().status)
		assert.are.equal("connection lost", done_result().error)
	end)

	it("puts the checked-out commit in front of a question in a GitHub review's commit scope", function()
		config.state.scope = "commit"
		config.state.scope_commit_sha = "abc1234def"
		chat.send("why?", handlers())
		local stdin = runs[1].opts.stdin
		assert.truthy(stdin:find("scope: commit abc1234def", 1, true))
		assert.are.equal("why?", stdin:sub(-4))
		runs[1].chunk(init_line() .. "\n" .. success_line("a") .. "\n")
		runs[1].exit(0, "")
		assert.are.equal("why?", chat.load(KEY).messages[1].text)
		-- back in the whole pull request: nothing is added
		config.state.scope = "full_pr"
		config.state.scope_commit_sha = nil
		chat.send("and now?", handlers())
		assert.are.equal("and now?", runs[2].opts.stdin)
	end)

	it("tells claude in a GitHub review that a question may start with the commit under review", function()
		chat.send("q", handlers())
		local prompt = runs[1].cmd[index_of(runs[1].cmd, "--append-system-prompt") + 1]
		assert.truthy(prompt:find("the question starts with that commit", 1, true))
	end)

	describe("settings sources", function()
		it("keeps the pull request's project settings out of a GitHub review", function()
			chat.send("q", handlers())
			local cmd = runs[1].cmd
			assert.are.equal("user", cmd[index_of(cmd, "--setting-sources") + 1])
		end)

		it("reads the project settings in a local review", function()
			config.reset_state()
			config.state.active = true
			config.state.review_mode = "local"
			config.state.local_session =
				{ id = "s1", worktree_root = "/repo", branch = "feat", base_ref = "main", scope = "base" }
			chat.send("q", handlers())
			assert.is_nil(index_of(runs[1].cmd, "--setting-sources"))
		end)

		it("passes only the user's own --setting-sources from chat.args", function()
			config.setup({ chat = { args = { "--setting-sources", "user,project,local" } } })
			chat.send("q", handlers())
			local cmd = runs[1].cmd
			assert.are.equal("user,project,local", cmd[index_of(cmd, "--setting-sources") + 1])
			assert.is_nil(index_of(cmd, "user"))
		end)

		it("keeps the restriction on the retry of a question", function()
			chat.save(KEY, { session_id = ID, started = true, messages = {} })
			chat.send("q", handlers())
			runs[1].chunk(not_found_line(ID) .. "\n")
			runs[1].exit(1, "")
			assert.are.equal("user", runs[2].cmd[index_of(runs[2].cmd, "--setting-sources") + 1])
		end)
	end)

	describe("working directory", function()
		it("is the root the GitHub review was started in, not Neovim's current repository", function()
			-- e.g. vim-rooter or a manual :cd moved the cwd into another repository
			helpers.mock(require("fude.diff"), "get_repo_root", function()
				return "/elsewhere"
			end)
			chat.send("q", handlers())
			assert.are.equal("/repo", runs[1].opts.cwd)
		end)

		it("is the worktree root of a local review", function()
			config.reset_state()
			config.state.active = true
			config.state.review_mode = "local"
			config.state.repo_root = "/not-this"
			config.state.local_session =
				{ id = "s1", worktree_root = "/work/tree", branch = "feat", base_ref = "main", scope = "base" }
			chat.send("q", handlers())
			assert.are.equal("/work/tree", runs[1].opts.cwd)
		end)

		it("follows the review to another worktree and starts a new session when claude has none there", function()
			chat.send("q1", handlers())
			runs[1].chunk(init_line() .. "\n" .. success_line("a1") .. "\n")
			runs[1].exit(0, "")
			local first_id = chat.load(KEY).session_id
			-- the same PR reviewed later from another worktree (stop, :cd, start)
			config.reset_state()
			assert.is_nil(config.state.repo_root)
			config.state.active = true
			config.state.review_mode = "github"
			config.state.pr_number = 7
			config.state.pr_url = "https://github.com/o/r/pull/7"
			config.state.repo_root = "/other-worktree"
			events = {}
			chat.send("q2", handlers())
			assert.are.equal("/other-worktree", runs[2].opts.cwd)
			assert.are.equal(first_id, runs[2].cmd[index_of(runs[2].cmd, "--resume") + 1])
			events = {}
			-- claude keeps sessions per directory: the resume finds nothing there
			runs[2].chunk(not_found_line(first_id) .. "\n")
			runs[2].exit(1, "")
			assert.are.equal(3, #runs)
			assert.are.equal("/other-worktree", runs[3].opts.cwd)
			local new_id = runs[3].cmd[index_of(runs[3].cmd, "--session-id") + 1]
			assert.are_not.equal(first_id, new_id)
			assert.are.same({ "retry", "new" }, events[2])
			runs[3].chunk(init_line() .. "\n" .. success_line("a2") .. "\n")
			runs[3].exit(0, "")
			assert.are.equal("done", done_result().status)
			assert.are.equal(4, #chat.load(KEY).messages)
		end)
	end)

	describe("chat.find_chat_root", function()
		it("picks the review's root by mode and ignores unusable values", function()
			assert.are.equal("/r", data.find_chat_root("github", "/r", nil))
			assert.are.equal("/w", data.find_chat_root("local", "/r", { worktree_root = "/w" }))
			assert.is_nil(data.find_chat_root("local", "/r", nil))
			assert.is_nil(data.find_chat_root("local", "/r", { worktree_root = "" }))
			assert.is_nil(data.find_chat_root("github", nil, { worktree_root = "/w" }))
			assert.is_nil(data.find_chat_root("github", "", nil))
		end)
	end)

	it("reports the exit code when a failed run said nothing", function()
		chat.send("q", handlers())
		runs[1].exit(3, "")
		assert.are.equal("claude exited with code 3", done_result().error)
	end)

	it("reports an error when the command cannot be started", function()
		helpers.mock(chat, "run", function()
			return nil, "ENOENT"
		end)
		assert.is_true(chat.send("q", handlers()))
		assert.are.equal("error", done_result().status)
		assert.truthy(done_result().error:find("ENOENT", 1, true))
		assert.is_false(chat.is_running())
	end)

	it("starts over once under a new id when the resumed session is gone", function()
		chat.save(KEY, { session_id = ID, started = true, messages = { data.build_message("user", "old") } })
		chat.send("q", handlers())
		runs[1].chunk(not_found_line(ID) .. "\n")
		runs[1].exit(1, "No conversation found with session ID: " .. ID)
		assert.are.equal(2, #runs)
		-- the note is answer text, so it is shown and stored like the rest
		assert.are.same({ { "text", data.NEW_SESSION_NOTE .. "\n\n" }, { "retry", "new" } }, events)
		local new_id = runs[2].cmd[index_of(runs[2].cmd, "--session-id") + 1]
		assert.is_true(data.is_uuid(new_id))
		assert.are_not.equal(ID, new_id)
		assert.is_nil(index_of(runs[2].cmd, "--resume"))
		assert.are.equal("q", runs[2].opts.stdin)
		assert.are.equal(new_id, chat.load(KEY).session_id)

		runs[2].chunk(init_line() .. "\n" .. success_line("fresh") .. "\n")
		runs[2].exit(0, "")
		assert.are.equal("done", done_result().status)
		local stored = chat.load(KEY)
		assert.is_true(stored.started)
		-- the conversation log is kept; only claude's session is new
		assert.are.equal(3, #stored.messages)
		-- what is stored renders as the live conversation did: note, then answer
		assert.are.equal(data.NEW_SESSION_NOTE .. "\n\nfresh", stored.messages[3].text)
		assert.are.equal(stored.messages[3].text, done_result().text)
	end)

	it("keeps what the first attempt had shown in front of the note", function()
		chat.save(KEY, { session_id = ID, started = true, messages = {} })
		chat.send("q", handlers())
		runs[1].chunk(text_line("stray words") .. "\n" .. not_found_line(ID) .. "\n")
		runs[1].exit(1, "")
		runs[2].chunk(init_line() .. "\n" .. text_line("fresh") .. "\n" .. success_line("fresh") .. "\n")
		runs[2].exit(0, "")
		local shown = ""
		for _, e in ipairs(events) do
			if e[1] == "text" then
				shown = shown .. e[2]
			end
		end
		assert.are.equal("stray words\n\n" .. data.NEW_SESSION_NOTE .. "\n\nfresh", shown)
		assert.are.equal(shown, chat.load(KEY).messages[2].text)
	end)

	it("retries with the id it used when the stored chat cannot be read back", function()
		chat.send("q", handlers())
		local id = runs[1].cmd[index_of(runs[1].cmd, "--session-id") + 1]
		-- the file is gone or unreadable by the time the retry is decided
		vim.fn.delete(tmp_dir, "rf")
		runs[1].exit(1, "Error: Session ID " .. id .. " is already in use.")
		assert.are.equal(2, #runs)
		assert.are.equal(id, runs[2].cmd[index_of(runs[2].cmd, "--resume") + 1])
		for i = 1, #runs[2].cmd do
			assert.is_not_nil(runs[2].cmd[i])
		end
	end)

	it("reports that the chat could not be saved, also when the question fails", function()
		helpers.mock(chat, "save", function()
			return false, "EACCES: state directory"
		end)
		chat.send("q", handlers())
		runs[1].exit(1, "Not logged in")
		assert.are.equal("error", done_result().status)
		assert.are.equal("EACCES: state directory", done_result().save_error)
	end)

	it("does not start over a second time", function()
		chat.save(KEY, { session_id = ID, started = true, messages = {} })
		chat.send("q", handlers())
		runs[1].exit(1, "No conversation found with session ID: " .. ID)
		runs[2].exit(1, "No conversation found with session ID: whatever")
		assert.are.equal(2, #runs)
		assert.are.equal("error", done_result().status)
		assert.is_false(chat.is_running())
	end)

	it("resumes instead when the new id turns out to exist", function()
		chat.save(KEY, { session_id = ID, started = false, messages = {} })
		chat.send("q", handlers())
		runs[1].exit(1, "Error: Session ID " .. ID .. " is already in use.")
		assert.are.equal(2, #runs)
		assert.are.same({ { "retry", "resume" } }, events)
		assert.are.equal(ID, runs[2].cmd[index_of(runs[2].cmd, "--resume") + 1])
	end)

	it("drops late output of the process a retry replaced", function()
		chat.save(KEY, { session_id = ID, started = true, messages = {} })
		chat.send("q", handlers())
		runs[1].exit(1, "No conversation found with session ID: " .. ID)
		events = {}
		runs[1].chunk(text_line("stale") .. "\n")
		runs[1].exit(0, "")
		assert.are.same({}, events)
		assert.is_true(chat.is_running())
	end)

	it("cancels: kills the process, stores the partial answer as cancelled", function()
		chat.send("q", handlers())
		runs[1].chunk(init_line() .. "\n" .. text_line("partial") .. "\n")
		assert.is_true(chat.cancel())
		assert.is_true(runs[1].killed)
		assert.is_false(chat.is_running())
		local result = done_result()
		assert.are.equal("cancelled", result.status)
		assert.are.equal("partial", result.text)
		local stored = chat.load(KEY)
		assert.are.equal("q", stored.messages[1].text)
		assert.are.equal("partial", stored.messages[2].text)
		assert.are.equal("cancelled", stored.messages[2].status)
	end)

	it("ignores output and the exit of a cancelled process", function()
		chat.send("q", handlers())
		chat.cancel()
		events = {}
		runs[1].chunk(text_line("late") .. "\n" .. success_line("late") .. "\n")
		runs[1].exit(143, "")
		assert.are.same({}, events)
		assert.are.equal(2, #chat.load(KEY).messages)
		assert.are.equal("", chat.load(KEY).messages[2].text)
	end)

	it("cancel does nothing when no question is running", function()
		assert.is_false(chat.cancel())
	end)

	it("accepts a new question right after a cancel, and starts it once the stopped process is gone", function()
		chat.send("q1", handlers())
		runs[1].chunk(init_line() .. "\n")
		chat.cancel()
		assert.is_true(chat.send("q2", handlers()))
		assert.is_true(chat.is_running())
		-- two processes must not write the same session at once
		assert.are.equal(1, #runs)
		runs[1].exit(143, "")
		assert.are.equal(2, #runs)
		assert.are.equal("q2", runs[2].opts.stdin)
		assert.is_not_nil(index_of(runs[2].cmd, "--resume"))
	end)

	it("does not start a waiting question that was cancelled meanwhile", function()
		chat.send("q1", handlers())
		chat.cancel()
		chat.send("q2", handlers())
		chat.cancel()
		assert.is_false(chat.is_running())
		runs[1].exit(143, "")
		assert.are.equal(1, #runs)
	end)

	it("starts the waiting question anyway when the stopped process does not exit", function()
		local timeout = chat.DRAIN_TIMEOUT_MS
		chat.DRAIN_TIMEOUT_MS = 20
		chat.send("q1", handlers())
		chat.cancel()
		chat.send("q2", handlers())
		assert.are.equal(1, #runs)
		assert.is_true(helpers.wait_for(function()
			return #runs == 2
		end))
		chat.DRAIN_TIMEOUT_MS = timeout
		-- its late exit starts nothing more
		runs[1].exit(143, "")
		assert.are.equal(2, #runs)
	end)

	it("discard stops the running answer and stores nothing of it", function()
		chat.send("q", handlers())
		runs[1].chunk(init_line() .. "\n" .. text_line("partial") .. "\n")
		assert.is_true(chat.discard())
		assert.is_true(runs[1].killed)
		assert.is_false(chat.is_running())
		assert.are.equal("cancelled", done_result().status)
		assert.are.same(data.build_empty_chat(), chat.load(KEY))
		-- the next question starts a new session (once the stopped process is gone)
		chat.send("q2", handlers())
		runs[1].exit(143, "")
		assert.is_not_nil(index_of(runs[2].cmd, "--session-id"))
	end)

	it("discard of another target leaves the running answer alone", function()
		chat.send("q", handlers())
		chat.discard("o/r:#8:chat")
		assert.is_false(runs[1].killed)
		assert.is_true(chat.is_running())
	end)

	it("does not call handlers after the review session was reset, but still stores the answer", function()
		chat.send("q", handlers())
		config.reset_state()
		runs[1].chunk(init_line() .. "\n" .. text_line("late") .. "\n")
		runs[1].chunk(tool_line("Read", { file_path = "/repo/a.lua" }) .. "\n")
		runs[1].chunk(success_line("late") .. "\n")
		runs[1].exit(0, "")
		assert.are.same({}, events)
		assert.is_false(chat.is_running())
		assert.are.equal("late", chat.load(KEY).messages[2].text)
	end)

	it("does not call handlers for a failure after the review session was reset", function()
		chat.save(KEY, { session_id = ID, started = true, messages = {} })
		chat.send("q", handlers())
		config.reset_state()
		-- not even the session retry runs for a stopped session
		runs[1].exit(1, "No conversation found with session ID: " .. ID)
		assert.are.same({}, events)
		assert.are.equal(1, #runs)
		assert.is_false(chat.is_running())
	end)

	it("cancel after a reset stores the partial answer without calling handlers", function()
		chat.send("q", handlers())
		runs[1].chunk(text_line("partial") .. "\n")
		events = {}
		config.reset_state()
		assert.is_true(chat.cancel())
		assert.is_true(runs[1].killed)
		assert.are.same({}, events)
		assert.are.equal("partial", chat.load(KEY).messages[2].text)
		assert.are.equal("cancelled", chat.load(KEY).messages[2].status)
	end)
end)

describe("chat.run", function()
	it("streams stdout chunks in order, then reports the exit code and stderr", function()
		local out = {}
		local exit
		local handle = chat.run({ "sh", "-c", "cat; printf 'err' >&2; exit 3" }, { stdin = "a\nb\n" }, function(chunk)
			table.insert(out, chunk)
		end, function(code, stderr)
			exit = { code, stderr }
		end)
		assert.is_not_nil(handle)
		assert.is_true(helpers.wait_for(function()
			return exit ~= nil
		end))
		assert.are.equal("a\nb\n", table.concat(out))
		assert.are.same({ 3, "err" }, exit)
	end)

	it("kill stops the process", function()
		local exit
		local handle = chat.run({ "sleep", "30" }, {}, function() end, function(code)
			exit = code
		end)
		handle.kill()
		assert.is_true(helpers.wait_for(function()
			return exit ~= nil
		end))
		assert.are_not.equal(0, exit)
	end)

	it("returns an error when the command does not exist", function()
		local handle, err = chat.run({ "fude-no-such-claude-command" }, {}, function() end, function() end)
		assert.is_nil(handle)
		assert.is_string(err)
	end)
end)
