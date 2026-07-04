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
---   delete   — remove a comment id from the materialized view (audit stays)
---   viewed   — mark a file viewed/unviewed (path + viewed bool; last write wins)
local M = {}
local util = require("fude.util")
local is_null = util.is_null

-- Seed the RNG once at load. Neovim does not seed math.random, so without this
-- every fresh process emits the identical generate_uuid()/make_session_id()
-- sequence — two sessions started in the same second would collide on the
-- session file, and comment ids would repeat across sessions (breaking agents
-- that aggregate multiple .fude/reviews/*.jsonl). hrtime gives per-process entropy.
math.randomseed(vim.uv.hrtime())

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
	delete = true,
	viewed = true,
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
--- in_reply_to_id. Local-only extras: author_type, resolved, context (the
--- source lines at creation, used for re-anchoring).
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
		context = type(event.context) == "string" and event.context or nil,
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
--- @return table result { session, comments, threads, viewed }
---   threads: table<string, { resolved, resolved_by, resolved_at }>
---   viewed: table<string, "VIEWED"|"UNVIEWED"> (last write wins per path)
function M.materialize(events)
	local session = nil
	local comments = {}
	local by_id = {}
	local threads = {}
	local viewed = {}

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
		elseif kind == "delete" then
			local target = by_id[event.id]
			if target then
				target._deleted = true
			end
		elseif kind == "viewed" then
			if type(event.path) == "string" then
				viewed[event.path] = event.viewed and "VIEWED" or "UNVIEWED"
			end
		end
	end

	-- Drop deleted comments from the materialized view (the events remain on
	-- disk as an audit trail). A reply whose root was deleted has no position
	-- of its own, so it is not re-anchored below and falls out of comment_map —
	-- deleting a root effectively retires its whole thread from the view.
	local visible = {}
	for _, comment in ipairs(comments) do
		if not comment._deleted then
			table.insert(visible, comment)
		end
	end
	comments = visible

	-- Propagate thread state onto each comment. Replies carry no position of
	-- their own (reply events have no path/line), so they inherit the root's
	-- current path/line — including any later move events — which keeps them
	-- visible in comment_map at the thread's anchor line, like the GitHub API.
	for _, comment in ipairs(comments) do
		local root_id = comment.in_reply_to_id or comment.id
		local root = by_id[root_id]
		if comment.in_reply_to_id and root and not root._deleted then
			comment.path = root.path
			comment.line = root.line
		end
		local thread = threads[root_id]
		if thread then
			comment.resolved = thread.resolved
		end
	end

	return { session = session, comments = comments, threads = threads, viewed = viewed }
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

--- Whether the file `lines` contain `ctx` as a contiguous run starting at the
--- 1-based `start` line.
--- @param lines string[] file lines
--- @param start number 1-based candidate start line
--- @param ctx string[] context lines to match
--- @return boolean
local function lines_match(lines, start, ctx)
	if start < 1 or start + #ctx - 1 > #lines then
		return false
	end
	for i = 1, #ctx do
		if lines[start + i - 1] ~= ctx[i] then
			return false
		end
	end
	return true
end

--- Find the unique 1-based start line where `ctx` occurs contiguously in
--- `lines`. Returns nil when there is no match or more than one.
--- @param lines string[]
--- @param ctx string[]
--- @return number|nil
local function unique_match(lines, ctx)
	if #ctx == 0 then
		return nil
	end
	local found, pos = 0, nil
	for s = 1, #lines - #ctx + 1 do
		if lines_match(lines, s, ctx) then
			found = found + 1
			pos = s
			if found > 1 then
				return nil
			end
		end
	end
	return (found == 1) and pos or nil
end

-- Comment position is maintained by three cooperating layers. A maintainer
-- should read them together:
--   1. `fude.local.tracker` — live extmark tracking for OPEN buffers; persists
--      a `move` event on BufWritePost. Precise, owns open buffers.
--   2. `M.reanchor` (below) — context-match re-anchor for CLOSED files only
--      (external/agent edits the tracker can't see); persists a `move`. Its
--      caller (`local_sync.load_comments`) feeds it disk content for closed
--      files only, so it never writes back unsaved buffer positions.
--   3. `M.apply_outdated` — marks `is_outdated` when a line is past EOF or its
--      file is gone and neither layer above could recover it.
-- The two `move` writers converge through append-only last-write materialize:
-- after a re-anchor move, `lines_match` succeeds at the new line on the next
-- load, so no further move is emitted (idempotent).

--- Re-anchor comments whose stored line no longer matches their saved context.
--- For each root comment carrying a `context` block, if the current file lines
--- at its range don't match the context, search the file for a unique
--- contiguous match and move the comment there. Ambiguous or missing matches
--- are left as-is (apply_outdated handles genuinely-lost anchors). Mutates the
--- passed comments (root lines + reply re-propagation) and returns the moves to
--- persist. Pure w.r.t. the store (no IO).
--- @param comments table[] materialized comments
--- @param file_lines_map table<string, string[]> path -> current file lines (nil = missing)
--- @return table[] moves { id, path, start_line, end_line }
function M.reanchor(comments, file_lines_map)
	file_lines_map = file_lines_map or {}
	local moves = {}
	local by_id = {}
	for _, c in ipairs(comments or {}) do
		by_id[c.id] = c
	end

	for _, c in ipairs(comments or {}) do
		if not c.in_reply_to_id and type(c.context) == "string" and c.context ~= "" and type(c.path) == "string" then
			local lines = file_lines_map[c.path]
			local end_line = tonumber(c.line)
			if lines and end_line then
				local start_line = tonumber(c.start_line) or end_line
				local ctx = vim.split(c.context, "\n", { plain = true })
				if not lines_match(lines, start_line, ctx) then
					local match = unique_match(lines, ctx)
					if match then
						local new_start, new_end = match, match + #ctx - 1
						if new_start ~= start_line or new_end ~= end_line then
							c.line = new_end
							c.start_line = (new_start ~= new_end) and new_start or nil
							table.insert(moves, { id = c.id, path = c.path, start_line = new_start, end_line = new_end })
						end
					end
				end
			end
		end
	end

	-- Replies inherit the (possibly re-anchored) root's position.
	for _, c in ipairs(comments or {}) do
		if c.in_reply_to_id then
			local root = by_id[c.in_reply_to_id]
			if root and not root._deleted then
				c.path = root.path
				c.line = root.line
				c.start_line = root.start_line
			end
		end
	end

	table.sort(moves, function(a, b)
		return a.id < b.id
	end)
	return moves
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

--- Build a delete event (removes a comment from the materialized view).
--- @param opts table { id, author, created_at }
--- @return table delete event
function M.build_delete_event(opts)
	return {
		event = "delete",
		id = opts.id,
		author = opts.author,
		created_at = opts.created_at,
	}
end

--- Build a viewed event (marks a file viewed/unviewed).
--- @param opts table { id, path, viewed (boolean), author, created_at }
--- @return table viewed event
function M.build_viewed_event(opts)
	return {
		event = "viewed",
		id = opts.id,
		path = opts.path,
		viewed = opts.viewed and true or false,
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

--- Map a branch name to a current-session map key. A detached HEAD (nil
--- branch) shares one slot so it is still resumable.
--- @param branch string|nil
--- @return string
local function branch_key(branch)
	return branch or "__detached__"
end

--- Read the whole current-session pointer map (`{ [branch] = session }`).
--- Migrates the pre-branch flat single-session format on read: an old pointer
--- (a session object with a top-level `id`) is treated as the entry for its
--- own branch. Returns {} when missing or malformed.
--- @param repo_root string
--- @return table<string, table>
local function read_current_map(repo_root)
	local path = M.current_file(repo_root)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	local ok2, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok2 or type(data) ~= "table" then
		return {}
	end
	-- Backward compat: a legacy single-session pointer (flat object with id).
	if type(data.id) == "string" then
		return { [branch_key(data.branch)] = data }
	end
	return data
end

--- Write the current-session pointer for a branch, preserving other branches'
--- entries so reviews on different branches in the same worktree don't collide.
--- @param repo_root string
--- @param branch string|nil the session's branch
--- @param session table { id, base_ref, base_sha, head_sha, branch, worktree_root, created_at, scope }
--- @return boolean ok, string|nil err
function M.write_current(repo_root, branch, session)
	local map = read_current_map(repo_root)
	map[branch_key(branch)] = session
	local path = M.current_file(repo_root)
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local ok, err = pcall(vim.fn.writefile, vim.split(vim.json.encode(map), "\n"), path)
	if not ok then
		return false, tostring(err)
	end
	return true
end

--- Read the current-session pointer for a branch. Returns nil when there is no
--- session for that branch or it is malformed.
--- @param repo_root string
--- @param branch string|nil
--- @return table|nil session
function M.read_current(repo_root, branch)
	local session = read_current_map(repo_root)[branch_key(branch)]
	if type(session) ~= "table" or type(session.id) ~= "string" then
		return nil
	end
	return session
end

--- Remove the current-session pointer for a branch (no-op when absent). Deletes
--- the file once no branch entries remain.
--- @param repo_root string
--- @param branch string|nil
function M.clear_current(repo_root, branch)
	local map = read_current_map(repo_root)
	local key = branch_key(branch)
	if map[key] == nil then
		return
	end
	map[key] = nil
	local path = M.current_file(repo_root)
	if vim.tbl_isempty(map) then
		if vim.fn.filereadable(path) == 1 then
			pcall(vim.fn.delete, path)
		end
		return
	end
	pcall(vim.fn.writefile, vim.split(vim.json.encode(map), "\n"), path)
end

return M
