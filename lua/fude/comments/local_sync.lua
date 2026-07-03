--- Local review comment backend: JSONL-backed CRUD for pre-PR sessions.
---
--- Mirrors the external shape of `comments/sync.lua` (load_comments,
--- reply_to_comment, edit_comment, delete_comment with the same callback
--- signatures) so `comments.lua` can dispatch to either backend by review
--- mode. All operations are synchronous file appends followed by a re-read;
--- callbacks are kept for shape compatibility with the async GitHub backend.
local M = {}
local config = require("fude.config")
local store = require("fude.local.store")
local data = require("fude.comments.data")

--- @return string UTC ISO-8601 timestamp
local function now_iso()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Count lines of each commented file, preferring loaded buffer contents
--- (unsaved edits) over the on-disk file. Missing files get no entry, which
--- `store.apply_outdated` treats as "file gone".
--- @param repo_root string
--- @param paths string[] repo-relative paths
--- @return table<string, number> path -> line count
local function get_line_counts(repo_root, paths)
	local counts = {}
	for _, path in ipairs(paths) do
		local abs = repo_root .. "/" .. path
		local bufnr = vim.fn.bufnr(abs)
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			counts[path] = vim.api.nvim_buf_line_count(bufnr)
		elseif vim.fn.filereadable(abs) == 1 then
			local ok, lines = pcall(vim.fn.readfile, abs)
			if ok then
				counts[path] = #lines
			end
		end
	end
	return counts
end

--- Collect the distinct paths referenced by materialized comments.
--- @param comments table[]
--- @return string[] sorted paths
local function comment_paths(comments)
	local set = {}
	for _, c in ipairs(comments) do
		if type(c.path) == "string" then
			set[c.path] = true
		end
	end
	local paths = vim.tbl_keys(set)
	table.sort(paths)
	return paths
end

--- Re-read the session JSONL and rebuild comment state (synchronous).
--- Same external shape as `sync.load_comments`.
--- @param callback fun()|nil invoked after comments are applied
--- @param opts table|nil { silent = boolean } suppress notifications when true
function M.load_comments(callback, opts)
	local state = config.state
	local session = state.local_session
	if not session then
		if callback then
			callback()
		end
		return
	end

	local events = store.read_events(session.file)
	local comments = store.materialize(events).comments
	store.apply_outdated(comments, get_line_counts(session.worktree_root, comment_paths(comments)))
	state.comments = comments
	state.comment_map = data.build_comment_map(comments)
	require("fude.ui").refresh_extmarks()
	require("fude.local.tracker").sync_all()

	if not (opts and opts.silent) then
		vim.notify(string.format("fude.nvim: Loaded %d comments", #comments), vim.log.levels.INFO)
	end
	if callback then
		callback()
	end
end

--- Append one event and refresh comment state.
--- @param event table
--- @param callback fun(err: string|nil)
local function append_and_refresh(event, callback)
	local session = config.state.local_session
	if not session then
		callback("No local review session")
		return
	end
	local ok, err = store.append_event(session.file, event)
	if not ok then
		callback(err or "Failed to write review file")
		return
	end
	M.load_comments(nil, { silent = true })
	callback(nil)
end

--- Create a new comment thread at a line range.
--- @param path string repo-relative file path
--- @param start_line number
--- @param end_line number
--- @param body string comment body
--- @param context string|nil surrounding source lines (best-effort re-anchor aid)
--- @param callback fun(err: string|nil)
function M.create_comment(path, start_line, end_line, body, context, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	append_and_refresh(
		store.build_comment_event({
			id = store.generate_uuid(),
			path = path,
			start_line = start_line,
			end_line = end_line,
			body = body,
			author = state.github_user,
			author_type = "human",
			created_at = now_iso(),
			context = context,
		}),
		callback
	)
end

--- Reply to a comment thread. Same shape as `sync.reply_to_comment`.
--- @param comment_id string target root comment id
--- @param body string reply body
--- @param callback fun(err: string|nil)
function M.reply_to_comment(comment_id, body, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	append_and_refresh(
		store.build_reply_event({
			id = store.generate_uuid(),
			thread_id = comment_id,
			body = body,
			author = state.github_user,
			author_type = "human",
			created_at = now_iso(),
		}),
		callback
	)
end

--- Edit a comment body. Same shape as `sync.edit_comment`.
--- @param comment_id string target comment id
--- @param body string new comment body
--- @param callback fun(err: string|nil)
function M.edit_comment(comment_id, body, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	append_and_refresh(
		store.build_edit_event({
			id = comment_id,
			body = body,
			author = state.github_user,
			created_at = now_iso(),
		}),
		callback
	)
end

--- Delete a comment (append-only: the event hides it from the materialized
--- view, the audit trail stays in the JSONL). Same shape as `sync.delete_comment`.
--- @param comment_id string target comment id
--- @param callback fun(err: string|nil)
function M.delete_comment(comment_id, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	append_and_refresh(
		store.build_delete_event({
			id = comment_id,
			author = state.github_user,
			created_at = now_iso(),
		}),
		callback
	)
end

--- Persist re-anchored comment positions as move events (batch), then
--- refresh state once. Used by the extmark tracker on BufWritePost.
--- @param moves table[] { id, path, start_line, end_line }
--- @param callback fun(err: string|nil)
function M.move_comments(moves, callback)
	local state = config.state
	local session = state.local_session
	if not state.active or not session then
		callback("Not active")
		return
	end
	local created_at = now_iso()
	for _, move in ipairs(moves or {}) do
		local ok, err = store.append_event(
			session.file,
			store.build_move_event({
				id = move.id,
				path = move.path,
				start_line = move.start_line,
				end_line = move.end_line,
				created_at = created_at,
			})
		)
		if not ok then
			callback(err or "Failed to write review file")
			return
		end
	end
	M.load_comments(nil, { silent = true })
	callback(nil)
end

--- Toggle a thread's resolved status (resolve <-> reopen).
--- @param thread_id string root comment id
--- @param currently_resolved boolean current resolved state of the thread
--- @param callback fun(err: string|nil, resolved: boolean|nil) resolved = new state
function M.toggle_resolved(thread_id, currently_resolved, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	local kind = currently_resolved and "reopen" or "resolve"
	local new_resolved = (kind == "resolve")
	append_and_refresh(
		store.build_status_event(kind, {
			id = store.generate_uuid(),
			thread_id = thread_id,
			author = state.github_user,
			created_at = now_iso(),
		}),
		function(err)
			if err then
				callback(err, nil)
				return
			end
			callback(nil, new_resolved)
		end
	)
end

return M
