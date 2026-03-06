local M = {}

--- Compute the file line number (RIGHT side) from a diff_hunk and position.
--- The review-specific endpoint (GET /reviews/{id}/comments) returns `position`
--- instead of `line` for pending review comments. This converts position to line.
--- @param diff_hunk string the diff hunk text from the API
--- @param position number 1-indexed position within the diff hunk
--- @return number|nil line number in the new file
function M.line_from_diff_hunk(diff_hunk, position)
	if not diff_hunk or not position then
		return nil
	end
	local new_start = tonumber(diff_hunk:match("%+(%d+)"))
	if not new_start then
		return nil
	end
	local new_line = new_start
	local pos = 0
	for hunk_line in diff_hunk:gmatch("[^\n]+") do
		if not hunk_line:match("^@@") then
			pos = pos + 1
			if hunk_line:sub(1, 1) ~= "-" then
				-- Context or addition: belongs to new file
				if pos == position then
					return new_line
				end
				new_line = new_line + 1
			end
		end
	end
	return nil
end

--- Build a nested lookup map from a flat array of comments.
--- @param comments table[] flat array of comment objects
--- @return table<string, table<number, table[]>> map[path][line] = {comments}
function M.build_comment_map(comments)
	local map = {}
	for _, c in ipairs(comments) do
		local path = c.path
		local line = c.line or c.original_line
		if path and line then
			if not map[path] then
				map[path] = {}
			end
			if not map[path][line] then
				map[path][line] = {}
			end
			table.insert(map[path][line], c)
		end
	end
	return map
end

--- Find the next comment line after current_line, with wrap-around.
--- @param current_line number
--- @param sorted_lines number[]
--- @return number|nil
function M.find_next_comment_line(current_line, sorted_lines)
	if #sorted_lines == 0 then
		return nil
	end
	for _, line in ipairs(sorted_lines) do
		if line > current_line then
			return line
		end
	end
	return sorted_lines[1]
end

--- Find the previous comment line before current_line, with wrap-around.
--- @param current_line number
--- @param sorted_lines number[]
--- @return number|nil
function M.find_prev_comment_line(current_line, sorted_lines)
	if #sorted_lines == 0 then
		return nil
	end
	for i = #sorted_lines, 1, -1 do
		if sorted_lines[i] < current_line then
			return sorted_lines[i]
		end
	end
	return sorted_lines[#sorted_lines]
end

--- Find a comment by its ID in the comment map.
--- @param comment_id number
--- @param comment_map table<string, table<number, table[]>>
--- @return table|nil { path: string, line: number, comment: table }
function M.find_comment_by_id(comment_id, comment_map)
	for path, file_lines in pairs(comment_map) do
		for line, cmts in pairs(file_lines) do
			for _, c in ipairs(cmts) do
				if c.id == comment_id then
					return { path = path, line = tonumber(line), comment = c }
				end
			end
		end
	end
	return nil
end

--- Get all comments in a thread given any comment in the thread.
--- @param comment_id number
--- @param all_comments table[] flat array of all comments
--- @return table[] thread comments sorted by created_at
function M.get_comment_thread(comment_id, all_comments)
	-- Build lookup by id
	local by_id = {}
	for _, c in ipairs(all_comments) do
		by_id[c.id] = c
	end

	-- Find root by following in_reply_to_id chain
	local current = by_id[comment_id]
	if not current then
		return {}
	end

	while current.in_reply_to_id and by_id[current.in_reply_to_id] do
		current = by_id[current.in_reply_to_id]
	end
	local root_id = current.id

	-- Collect all comments in thread (root + replies)
	local thread = { current }
	for _, c in ipairs(all_comments) do
		if c.id ~= root_id then
			-- Check if this comment's chain leads to root
			local node = c
			while node.in_reply_to_id and by_id[node.in_reply_to_id] do
				node = by_id[node.in_reply_to_id]
			end
			if node.id == root_id then
				table.insert(thread, c)
			end
		end
	end

	-- Sort by created_at
	table.sort(thread, function(a, b)
		return (a.created_at or "") < (b.created_at or "")
	end)

	return thread
end

--- Parse a draft key string into its components.
--- @param key string "path:start:end" or "reply:comment_id"
--- @return table|nil parsed key components
function M.parse_draft_key(key)
	if key == "issue_comment" then
		return { type = "issue_comment" }
	end
	local reply_id = key:match("^reply:(%d+)$")
	if reply_id then
		return { type = "reply", comment_id = tonumber(reply_id) }
	end
	local path, sl, el = key:match("^(.+):(%d+):(%d+)$")
	if path then
		return { type = "comment", path = path, start_line = tonumber(sl), end_line = tonumber(el) }
	end
	return nil
end

--- Build pending_comments from review comments array.
--- @param comments table[] array of review comment objects from GitHub
--- @return table<string, table> map of key -> comment data
function M.build_pending_comments_from_review(comments)
	local result = {}
	for _, c in ipairs(comments) do
		local path = c.path
		local line = c.line or c.original_line
		local start_line = c.start_line or line
		if path and line then
			local key = path .. ":" .. start_line .. ":" .. line
			result[key] = {
				id = c.id,
				path = path,
				body = c.body,
				line = line,
				side = c.side or "RIGHT",
			}
			if start_line ~= line then
				result[key].start_line = start_line
				result[key].start_side = c.start_side or "RIGHT"
			end
		end
	end
	return result
end

--- Build a review comment object from parsed draft key components.
--- @param path string repo-relative file path
--- @param start_line number start line number
--- @param end_line number end line number
--- @param body string comment body
--- @return table review comment object for GitHub API
function M.build_review_comment_object(path, start_line, end_line, body)
	local comment = {
		path = path,
		body = body,
		line = end_line,
		side = "RIGHT",
	}
	if start_line ~= end_line then
		comment.start_line = start_line
		comment.start_side = "RIGHT"
	end
	return comment
end

--- Convert pending_comments table to array of review comment objects.
--- @param pending_comments table<string, table> map of key -> comment data
--- @return table[] array of review comment objects
function M.pending_comments_to_array(pending_comments)
	local result = {}
	for _, comment_data in pairs(pending_comments) do
		table.insert(result, comment_data)
	end
	return result
end

--- Get the line range for a comment (start_line to line).
--- @param comment table comment object from GitHub API
--- @return number start_line, number end_line
function M.get_comment_line_range(comment)
	local end_line = tonumber(comment.line) or tonumber(comment.original_line) or 1
	local start_line = tonumber(comment.start_line) or end_line
	return start_line, end_line
end

--- Get the reply target ID for a comment.
--- GitHub API doesn't allow replying to replies, so we need to find the top-level comment.
--- @param comment_id number the comment ID
--- @param comment_map table the comment map
--- @return number the ID to use for reply (either original or in_reply_to_id)
function M.get_reply_target_id(comment_id, comment_map)
	local found = M.find_comment_by_id(comment_id, comment_map)
	if found and found.comment.in_reply_to_id then
		return found.comment.in_reply_to_id
	end
	return comment_id
end

--- Get comments at a specific file and line from a comment map.
--- @param comment_map table<string, table<number, table[]>>
--- @param rel_path string repo-relative file path
--- @param line number line number
--- @return table[] comments
function M.get_comments_at(comment_map, rel_path, line)
	if not comment_map[rel_path] then
		return {}
	end
	return comment_map[rel_path][line] or {}
end

--- Get all line numbers with comments for a file from a comment map.
--- @param comment_map table<string, table<number, table[]>>
--- @param rel_path string repo-relative file path
--- @return number[] sorted line numbers
function M.get_comment_lines(comment_map, rel_path)
	if not comment_map[rel_path] then
		return {}
	end
	local lines = {}
	for line, _ in pairs(comment_map[rel_path]) do
		table.insert(lines, tonumber(line))
	end
	table.sort(lines)
	return lines
end

--- Build sorted Telescope entries from a comment map.
--- @param comment_map table<string, table<number, table[]>>
--- @param repo_root string
--- @param format_date_fn fun(s: string): string
--- @param pending_review_id number|nil pending review ID for labeling
--- @return table[] entries sorted by last_ts descending
function M.build_comment_entries(comment_map, repo_root, format_date_fn, pending_review_id)
	local entries = {}
	for path, file_lines in pairs(comment_map) do
		for line_key, comments in pairs(file_lines) do
			local line = math.floor(tonumber(line_key) or 1)
			local first = comments[1]
			local last = comments[#comments]
			local is_pending = false
			if pending_review_id then
				for _, c in ipairs(comments) do
					if c.pull_request_review_id == pending_review_id then
						is_pending = true
						break
					end
				end
			end
			local author = first.user and first.user.login or "unknown"
			local last_ts = last.created_at or ""
			local last_date = format_date_fn(last_ts)
			local body_preview = (first.body or ""):gsub("\r?\n", " ")
			if #body_preview > 60 then
				body_preview = body_preview:sub(1, 57) .. "..."
			end
			local label = is_pending and "[pending]" or ("@" .. author)
			local detail = string.format("%s:%d  %s  %s", path, line, label, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s:%d %s", path, line, first.body or ""),
				filename = repo_root .. "/" .. path,
				lnum = line,
				last_ts = last_ts,
				last_date = last_date,
				detail = detail,
				comments = comments,
				is_pending = is_pending or false,
			})
		end
	end
	table.sort(entries, function(a, b)
		return a.last_ts > b.last_ts
	end)
	return entries
end

return M
