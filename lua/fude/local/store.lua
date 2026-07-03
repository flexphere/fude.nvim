--- Local review event store: append-only JSONL persistence for pre-PR reviews.
---
--- Unlike `drafts.lua` (unsubmitted input under stdpath("state")), this store
--- lives inside the worktree (`.fude/` by default) so external AI agents can
--- read comments and append replies. The JSONL file is the single contract:
--- one JSON object per line, each an immutable event. State is reconstructed
--- by `materialize()`, so edits/resolves never rewrite existing lines (safe
--- against concurrent appends from an agent process).
---
--- Event kinds:
---   session  — session metadata header (first line of a session file)
---   comment  — new thread root (path + start_line/end_line + body)
---   reply    — reply to a thread (in_reply_to = root comment id)
---   edit     — body replacement for an existing comment id
---   move     — line re-anchor for a comment id (extmark tracking writeback)
---   resolve  — mark a thread resolved (thread_id = root comment id)
---   reopen   — reopen a resolved thread
local M = {}
local util = require("fude.util")
local is_null = util.is_null

-- Directory override for tests (nil = "<repo_root>/.fude").
M._dir = nil

--- Event kinds that this store understands (unknown kinds are skipped).
local EVENT_KINDS = {
	session = true,
	comment = true,
	reply = true,
	edit = true,
	move = true,
	resolve = true,
	reopen = true,
}

-- === Pure functions ===

--- Generate a pseudo-random UUID v4 string.
--- Not cryptographically secure; uniqueness within a review session is enough.
--- @return string
function M.generate_uuid()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return (
		template:gsub("[xy]", function(c)
			local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
			return string.format("%x", v)
		end)
	)
end

--- Build a session id from a timestamp and a random suffix.
--- @param now number unix time
--- @return string e.g. "20260704-021530-a1b2c3"
function M.make_session_id(now)
	return os.date("!%Y%m%d-%H%M%S", now) .. "-" .. string.format("%06x", math.random(0, 0xffffff))
end

--- Serialize one event to a JSONL line (no trailing newline).
--- @param event table
--- @return string
function M.serialize_event(event)
	return vim.json.encode(event)
end

--- Parse one JSONL line into an event table. Returns nil for blank or
--- malformed lines (a corrupt line never breaks the whole file) and for
--- events whose `event` kind is unknown or whose `id` is missing (except
--- `session`, which is keyed by `session_id`).
--- @param line string|nil
--- @return table|nil
function M.parse_event_line(line)
	if not line or vim.trim(line) == "" then
		return nil
	end
	local ok, event = pcall(vim.json.decode, line)
	if not ok or type(event) ~= "table" or type(event.event) ~= "string" then
		return nil
	end
	if not EVENT_KINDS[event.event] then
		return nil
	end
	if event.event ~= "session" and type(event.id) ~= "string" then
		return nil
	end
	return event
end

--- Parse a whole JSONL document into an array of events (malformed lines skipped).
--- @param text string|nil
--- @return table[] events
function M.parse_events(text)
	local events = {}
	if not text or text == "" then
		return events
	end
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local event = M.parse_event_line(line)
		if event then
			table.insert(events, event)
		end
	end
	return events
end

--- Build a GitHub-compatible comment object from a comment/reply event.
--- The shape mirrors what `comments/data.lua` expects from the GitHub API:
--- id, path, line, start_line, body, user.login, created_at, updated_at,
--- in_reply_to_id. Local-only extras: author_type, resolved.
--- @param event table comment or reply event
--- @return table comment object
local function comment_from_event(event)
	local comment = {
		id = event.id,
		path = event.path,
		line = event.end_line or event.start_line,
		body = event.body or "",
		side = "RIGHT",
		user = { login = event.author or "unknown" },
		author_type = event.author_type or "human",
		created_at = event.created_at,
		updated_at = event.created_at,
		in_reply_to_id = event.in_reply_to,
		resolved = false,
	}
	if event.start_line and event.end_line and event.start_line ~= event.end_line then
		comment.start_line = event.start_line
		comment.start_side = "RIGHT"
	end
	return comment
end

--- Materialize an event array into session metadata and comment objects.
--- Events are applied in file order (append order). Unknown references
--- (edit/move/resolve for missing ids) are ignored.
--- @param events table[] parsed events
--- @return table result { session: table|nil, comments: table[], threads: table<string, table> }
---   threads values: { resolved: boolean, resolved_by: string|nil, resolved_at: string|nil }
function M.materialize(events)
	local session = nil
	local comments = {}
	local by_id = {}
	local threads = {}

	for _, event in ipairs(events or {}) do
		local kind = event.event
		if kind == "session" then
			session = session or event
		elseif kind == "comment" or kind == "reply" then
			if not by_id[event.id] then
				local comment = comment_from_event(event)
				by_id[event.id] = comment
				table.insert(comments, comment)
				if kind == "comment" then
					threads[event.id] = { resolved = false }
				end
			end
		elseif kind == "edit" then
			local target = by_id[event.id]
			if target and type(event.body) == "string" then
				target.body = event.body
				target.updated_at = event.created_at or target.updated_at
			end
		elseif kind == "move" then
			local target = by_id[event.id]
			if target and not is_null(event.end_line) then
				target.line = event.end_line
				if event.start_line and event.start_line ~= event.end_line then
					target.start_line = event.start_line
				else
					target.start_line = nil
				end
			end
		elseif kind == "resolve" or kind == "reopen" then
			local thread_id = event.thread_id
			if thread_id and threads[thread_id] then
				threads[thread_id].resolved = (kind == "resolve")
				threads[thread_id].resolved_by = (kind == "resolve") and event.author or nil
				threads[thread_id].resolved_at = (kind == "resolve") and event.created_at or nil
			end
		end
	end

	-- Propagate thread resolved state onto each comment (root and replies).
	for _, comment in ipairs(comments) do
		local root_id = comment.in_reply_to_id or comment.id
		local thread = threads[root_id]
		if thread then
			comment.resolved = thread.resolved
		end
	end

	return { session = session, comments = comments, threads = threads }
end

--- Mark comments whose anchor no longer fits the current file as outdated.
--- A comment is outdated when its path is missing from `line_counts` (file
--- deleted) or its line exceeds the file's current line count. Mutates and
--- returns `comments`. `line_counts` maps repo-relative path -> line count
--- (nil entry = file missing).
--- @param comments table[] materialized comment objects
--- @param line_counts table<string, number>
--- @return table[] comments
function M.apply_outdated(comments, line_counts)
	for _, comment in ipairs(comments or {}) do
		local count = comment.path and line_counts[comment.path] or nil
		local line = tonumber(comment.line)
		if not count or (line and line > count) then
			comment.is_outdated = true
			comment.original_line = comment.line
			comment.line = vim.NIL
		end
	end
	return comments
end

--- Build a session header event.
--- @param opts table { id, base_ref, base_sha, head_sha, branch, worktree_root, created_at }
--- @return table session event
function M.build_session_event(opts)
	return {
		event = "session",
		session_id = opts.id,
		base_ref = opts.base_ref,
		base_sha = opts.base_sha,
		head_sha = opts.head_sha,
		branch = opts.branch,
		worktree_root = opts.worktree_root,
		created_at = opts.created_at,
	}
end

--- Build a comment (thread root) event.
--- @param opts table { id, path, start_line, end_line, body, author, author_type, created_at, context }
--- @return table comment event
function M.build_comment_event(opts)
	return {
		event = "comment",
		id = opts.id,
		thread_id = opts.id,
		path = opts.path,
		start_line = opts.start_line,
		end_line = opts.end_line,
		body = opts.body,
		author = opts.author,
		author_type = opts.author_type or "human",
		created_at = opts.created_at,
		context = opts.context,
	}
end

--- Build a reply event.
--- @param opts table { id, thread_id, body, author, author_type, created_at }
--- @return table reply event
function M.build_reply_event(opts)
	return {
		event = "reply",
		id = opts.id,
		thread_id = opts.thread_id,
		in_reply_to = opts.thread_id,
		body = opts.body,
		author = opts.author,
		author_type = opts.author_type or "human",
		created_at = opts.created_at,
	}
end

--- Build an edit event.
--- @param opts table { id, body, author, created_at }
--- @return table edit event
function M.build_edit_event(opts)
	return {
		event = "edit",
		id = opts.id,
		body = opts.body,
		author = opts.author,
		created_at = opts.created_at,
	}
end

--- Build a move (line re-anchor) event.
--- @param opts table { id, path, start_line, end_line, created_at }
--- @return table move event
function M.build_move_event(opts)
	return {
		event = "move",
		id = opts.id,
		path = opts.path,
		start_line = opts.start_line,
		end_line = opts.end_line,
		created_at = opts.created_at,
	}
end

--- Build a resolve or reopen event.
--- @param kind string "resolve"|"reopen"
--- @param opts table { id, thread_id, author, created_at }
--- @return table event
function M.build_status_event(kind, opts)
	return {
		event = kind,
		id = opts.id,
		thread_id = opts.thread_id,
		author = opts.author,
		created_at = opts.created_at,
	}
end

-- === IO layer ===

--- Resolve the store directory for a repo root.
--- @param repo_root string
--- @return string
function M.store_dir(repo_root)
	return M._dir or (repo_root .. "/.fude")
end

--- Path of a session's JSONL file.
--- @param repo_root string
--- @param session_id string
--- @return string
function M.session_file(repo_root, session_id)
	return M.store_dir(repo_root) .. "/reviews/" .. session_id .. ".jsonl"
end

--- Path of the current-session pointer file.
--- @param repo_root string
--- @return string
function M.current_file(repo_root)
	return M.store_dir(repo_root) .. "/current.json"
end

--- Append one event to a session file, creating parent directories.
--- @param path string session JSONL path
--- @param event table
--- @return boolean ok, string|nil err
function M.append_event(path, event)
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local line = M.serialize_event(event) .. "\n"
	local f, err = io.open(path, "a")
	if not f then
		return false, err or ("Cannot open " .. path)
	end
	f:write(line)
	f:close()
	return true
end

--- Read and parse all events from a session file. Returns {} when missing.
--- @param path string session JSONL path
--- @return table[] events
function M.read_events(path)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local text = f:read("*a") or ""
	f:close()
	return M.parse_events(text)
end

--- Write the current-session pointer file.
--- @param repo_root string
--- @param session table { id, base_ref, base_sha, head_sha, branch, worktree_root, created_at }
--- @return boolean ok, string|nil err
function M.write_current(repo_root, session)
	local path = M.current_file(repo_root)
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local ok, err = pcall(vim.fn.writefile, vim.split(vim.json.encode(session), "\n"), path)
	if not ok then
		return false, tostring(err)
	end
	return true
end

--- Read the current-session pointer. Returns nil when missing or malformed.
--- @param repo_root string
--- @return table|nil session
function M.read_current(repo_root)
	local path = M.current_file(repo_root)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	local ok2, session = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok2 or type(session) ~= "table" or type(session.id) ~= "string" then
		return nil
	end
	return session
end

--- Remove the current-session pointer (no-op when missing).
--- @param repo_root string
function M.clear_current(repo_root)
	local path = M.current_file(repo_root)
	if vim.fn.filereadable(path) == 1 then
		pcall(vim.fn.delete, path)
	end
end

return M
