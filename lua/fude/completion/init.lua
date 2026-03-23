local M = {}
local gh = require("fude.gh")

local CACHE_TTL = 300 -- 5 minutes

local cache = {
	collaborators = nil,
	collaborators_time = 0,
	issues = nil,
	issues_time = 0,
	commits = nil,
	commits_source = nil, -- reference to state.pr_commits used to build cache
}

--- Check if cached data is still valid.
--- @param key string cache key
--- @return boolean
local function cache_valid(key)
	return cache[key] ~= nil and (os.time() - cache[key .. "_time"]) < CACHE_TTL
end

--- Fetch collaborators and return completion items via callback.
--- @param callback fun(items: table[])
function M.fetch_mentions(callback)
	if cache_valid("collaborators") then
		return callback(cache.collaborators)
	end

	gh.get_collaborators(function(err, data)
		if err or not data then
			return callback({})
		end

		local items = {}
		for _, user in ipairs(data) do
			local login = user.login
			if login then
				table.insert(items, {
					label = "@" .. login,
					insertText = "@" .. login,
					filterText = "@" .. login,
					kind = 12, -- Value
					documentation = {
						kind = "markdown",
						value = string.format("**@%s**\nGitHub collaborator", login),
					},
				})
			end
		end

		cache.collaborators = items
		cache.collaborators_time = os.time()
		callback(items)
	end)
end

--- Fetch issues/PRs and return completion items via callback.
--- @param callback fun(items: table[])
function M.fetch_issues(callback)
	if cache_valid("issues") then
		return callback(cache.issues)
	end

	gh.get_repo_issues(function(err, data)
		if err or not data then
			return callback({})
		end

		local items = {}
		for _, issue in ipairs(data) do
			local number = issue.number
			local title = issue.title or ""
			local state = issue.state or "unknown"
			local author = issue.user and issue.user.login or "unknown"
			local is_pr = issue.pull_request ~= nil
			local kind_label = is_pr and "PR" or "Issue"

			if number then
				table.insert(items, {
					label = string.format("#%d %s", number, title),
					insertText = "#" .. number,
					filterText = string.format("#%d %s", number, title),
					kind = 15, -- Reference
					documentation = {
						kind = "markdown",
						value = string.format("**%s #%d**: %s\nState: %s | Author: @%s", kind_label, number, title, state, author),
					},
				})
			end
		end

		cache.issues = items
		cache.issues_time = os.time()
		callback(items)
	end)
end

--- Determine completion context from text before cursor.
--- @param line_before_cursor string
--- @return string|nil "mention", "issue", "commit", or nil
function M.get_context(line_before_cursor)
	if line_before_cursor:match("@[%w_%-]*$") then
		return "mention"
	end
	if line_before_cursor:match("#%d*$") then
		return "issue"
	end
	if line_before_cursor:match("_[%w%d%[%]/%(%) ]*$") then
		return "commit"
	end
	return nil
end

--- Build completion items from PR commit entries.
--- Items are ordered newest-first for display in completion menus.
--- @param commit_entries table[] array of { sha, short_sha, message, author_name, date }
--- @return table[] items completion items (newest first)
function M.build_commit_items(commit_entries)
	local items = {}
	local total = #commit_entries
	-- Build items in reverse order (newest first) for completion display
	for i = total, 1, -1 do
		local c = commit_entries[i]
		local idx = #items + 1
		local display = string.format("[%d/%d] %s %s (%s)", i, total, c.short_sha, c.message, c.author_name)
		table.insert(items, {
			label = display,
			insertText = c.short_sha,
			filterText = "_",
			sortText = string.format("%05d", idx),
			kind = 15, -- Reference
			documentation = {
				kind = "markdown",
				value = string.format(
					"**Commit %s**\n%s\nAuthor: %s\nDate: %s",
					c.sha or c.short_sha,
					c.message,
					c.author_name,
					c.date
				),
			},
		})
	end
	return items
end

--- Fetch PR commit entries and return completion items via callback.
--- Results are cached and invalidated when state.pr_commits changes.
--- @param callback fun(items: table[])
function M.fetch_commits(callback)
	local config = require("fude.config")
	local raw_commits = config.state.pr_commits
	if not raw_commits or #raw_commits == 0 then
		return callback({})
	end
	if cache.commits ~= nil and cache.commits_source == raw_commits then
		return callback(cache.commits)
	end
	local entries = gh.parse_commit_entries(raw_commits)
	cache.commits = M.build_commit_items(entries)
	cache.commits_source = raw_commits
	callback(cache.commits)
end

--- Invalidate the cache (e.g. after creating a comment).
function M.invalidate_cache()
	cache.collaborators = nil
	cache.collaborators_time = 0
	cache.issues = nil
	cache.issues_time = 0
	cache.commits = nil
	cache.commits_source = nil
end

return M
