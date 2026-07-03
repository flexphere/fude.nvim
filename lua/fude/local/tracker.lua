--- Extmark-based line tracking for local review comments.
---
--- While a local session is active, each root comment gets an invisible
--- extmark in its buffer. Buffer edits move the extmark with the text, and on
--- `BufWritePost` the drifted positions are written back to the JSONL store
--- as `move` events (append-only re-anchor). Replies inherit the root's
--- position at materialize time, so only roots are tracked.
---
--- Uses a dedicated namespace ("fude_local_track") so `refresh_extmarks`
--- (which clears the main "fude" namespace) never wipes the tracking marks.
local M = {}
local config = require("fude.config")

local ns = vim.api.nvim_create_namespace("fude_local_track")

-- { [bufnr] = { [comment_id] = { end_id = number, start_id = number|nil } } }
local registry = {}

--- Root comments (non-reply, non-outdated) for a repo-relative path.
--- @param rel_path string
--- @return table[] comments
local function root_comments_for(rel_path)
	local out = {}
	for _, c in ipairs(config.state.comments or {}) do
		if c.path == rel_path and not c.in_reply_to_id and not c.is_outdated and type(c.line) == "number" then
			table.insert(out, c)
		end
	end
	return out
end

--- Place tracking extmarks for all root comments in a buffer.
--- Clears any previous tracking marks for the buffer first.
--- @param buf number buffer handle
--- @param rel_path string repo-relative path of the buffer
function M.sync_buffer(buf, rel_path)
	if not vim.api.nvim_buf_is_valid(buf) then
		registry[buf] = nil
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	registry[buf] = {}

	local line_count = vim.api.nvim_buf_line_count(buf)
	for _, comment in ipairs(root_comments_for(rel_path)) do
		local end_line = math.min(comment.line, line_count)
		local marks = {}
		local ok, end_id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, end_line - 1, 0, {})
		if ok then
			marks.end_id = end_id
			local start_line = comment.start_line
			if type(start_line) == "number" and start_line ~= comment.line and start_line <= line_count then
				local ok2, start_id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line - 1, 0, {})
				if ok2 then
					marks.start_id = start_id
				end
			end
			registry[buf][comment.id] = marks
		end
	end
end

--- Re-sync tracking extmarks in every loaded normal buffer that belongs to
--- the repository. Called after comment state is (re)built.
function M.sync_all()
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		return
	end
	local diff = require("fude.diff")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
			local rel_path = diff.to_repo_relative(vim.api.nvim_buf_get_name(buf))
			if rel_path then
				M.sync_buffer(buf, rel_path)
			end
		end
	end
end

--- Compute drifted comment positions in a buffer from its tracking extmarks.
--- Pure with respect to the store (reads extmarks only, appends nothing).
--- @param buf number buffer handle
--- @return table[] moves { id, path, start_line, end_line }
function M.collect_moves(buf)
	local moves = {}
	local marks = registry[buf]
	if not marks or not vim.api.nvim_buf_is_valid(buf) then
		return moves
	end

	local by_id = {}
	for _, c in ipairs(config.state.comments or {}) do
		by_id[c.id] = c
	end

	for comment_id, mark in pairs(marks) do
		local comment = by_id[comment_id]
		if comment and type(comment.line) == "number" then
			local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark.end_id, {})
			if pos and #pos > 0 then
				local new_end = pos[1] + 1
				local old_end = comment.line
				local old_start = comment.start_line or old_end
				local new_start
				if mark.start_id then
					local spos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark.start_id, {})
					new_start = (spos and #spos > 0) and (spos[1] + 1) or nil
				end
				-- Single-line comments (and lost start marks) keep the range span
				new_start = new_start or (new_end - (old_end - old_start))
				if new_start > new_end then
					new_start = new_end
				end
				if new_end ~= old_end or new_start ~= old_start then
					table.insert(moves, {
						id = comment_id,
						path = comment.path,
						start_line = new_start,
						end_line = new_end,
					})
				end
			end
		end
	end

	-- Deterministic order for the append sequence (registry is a hash map)
	table.sort(moves, function(a, b)
		return a.id < b.id
	end)
	return moves
end

--- BufWritePost handler: persist drifted comment positions as move events.
--- @param buf number buffer handle that was written
function M.on_buf_write(buf)
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		return
	end
	local moves = M.collect_moves(buf)
	if #moves == 0 then
		return
	end
	require("fude.comments.local_sync").move_comments(moves, function(err)
		if err then
			vim.notify("fude.nvim: Failed to re-anchor comments: " .. err, vim.log.levels.WARN)
		end
	end)
end

--- Remove all tracking extmarks and registry entries (session teardown).
function M.teardown()
	for buf in pairs(registry) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
		end
	end
	registry = {}
end

return M
