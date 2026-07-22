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

--- Read the current lines of each commented file. Returns two maps:
---   `lines`  — buffer contents when loaded (so an in-progress edit doesn't
---              falsely mark a comment outdated), else the on-disk file. Used
---              for outdated line-count checks.
---   `closed` — on-disk lines for files NOT open in a loaded buffer only. Fed
---              to `store.reanchor`, so re-anchoring (which persists `move`
---              events) never acts on unsaved buffer content — open buffers are
---              the extmark tracker's domain and persist on save.
--- Missing files get no entry, which `store.apply_outdated` treats as "gone".
--- @param repo_root string
--- @param paths string[] repo-relative paths
--- @return table<string, string[]> lines, table<string, string[]> closed
local function read_commented_files(repo_root, paths)
	local lines, closed = {}, {}
	for _, path in ipairs(paths) do
		local abs = repo_root .. "/" .. path
		local bufnr = vim.fn.bufnr(abs)
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			lines[path] = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		elseif vim.fn.filereadable(abs) == 1 then
			local ok, disk = pcall(vim.fn.readfile, abs)
			if ok then
				lines[path] = disk
				closed[path] = disk
			end
		end
	end
	return lines, closed
end

--- Derive per-path line counts from a path -> lines map.
--- @param file_lines table<string, string[]>
--- @return table<string, number>
local function line_counts_of(file_lines)
	local counts = {}
	for path, lines in pairs(file_lines) do
		counts[path] = #lines
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
	local result = store.materialize(events)
	local comments = result.comments

	-- Context-based re-anchor: recover comments whose line drifted while the
	-- buffer was CLOSED (e.g. an external agent edit) and persist the confident
	-- matches as move events so agents see the updated positions. Only closed
	-- files are fed in, so unsaved edits in open buffers are never written back
	-- here — the extmark tracker owns open buffers and persists on save.
	local file_lines, closed_lines = read_commented_files(session.worktree_root, comment_paths(comments))
	local moves = store.reanchor(comments, closed_lines)
	if #moves > 0 then
		local created = now_iso()
		local append_err = nil
		for _, mv in ipairs(moves) do
			local ok, err = store.append_event(
				session.file,
				store.build_move_event({
					id = mv.id,
					path = mv.path,
					start_line = mv.start_line,
					end_line = mv.end_line,
					created_at = created,
				})
			)
			if not ok then
				append_err = append_err or err or "write failed"
			end
		end
		-- reanchor already mutated `comments` in memory. If persisting a move
		-- failed (disk full / permissions / conflict), memory and the JSONL would
		-- diverge, so re-materialize from disk (which includes any moves that DID
		-- persist) to keep state consistent with the file. Surface the error so
		-- the cause (disk full / permissions) is diagnosable.
		if append_err then
			vim.notify(
				"fude.nvim: Failed to persist comment re-anchor (" .. append_err .. "); using on-disk positions",
				vim.log.levels.WARN
			)
			comments = store.materialize(store.read_events(session.file)).comments
		end
	end

	store.apply_outdated(comments, line_counts_of(file_lines))

	-- Normalize the local `resolved` flag onto the display-facing `is_resolved`,
	-- gated by `resolved.show`. This mirrors how `sync.lua` only sets
	-- `is_resolved` at fetch time when `resolved.show` is enabled, so the whole
	-- display layer (util/format/inline/extmarks) can read `is_resolved` alone.
	-- `resolved` is kept as the toggle source of truth (see comments.lua).
	local show_resolved = not (config.opts.resolved and config.opts.resolved.show == false)
	for _, c in ipairs(comments) do
		c.is_resolved = (show_resolved and c.resolved) or nil
	end

	state.comments = comments
	state.comment_map = data.build_comment_map(comments)
	state.viewed_files = result.viewed
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

--- Set the viewed state of a file (append-only; last write wins). Refreshes
--- state.viewed_files. There is no GitHub round-trip in local review mode.
--- @param path string repo-relative file path
--- @param viewed boolean true = VIEWED, false = UNVIEWED
--- @param callback fun(err: string|nil)
function M.set_viewed(path, viewed, callback)
	local state = config.state
	if not state.active or not state.local_session then
		callback("Not active")
		return
	end
	append_and_refresh(
		store.build_viewed_event({
			id = store.generate_uuid(),
			path = path,
			viewed = viewed,
			author = state.github_user,
			created_at = now_iso(),
		}),
		callback
	)
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
