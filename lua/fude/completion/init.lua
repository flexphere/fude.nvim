local M = {}
local gh = require("fude.gh")

local CACHE_TTL = 300 -- 5 minutes

local cache = {
	collaborators = nil,
	collaborators_time = 0,
	issues = nil,
	issues_time = 0,
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
--- @return string|nil "mention", "issue", or nil
function M.get_context(line_before_cursor)
	if line_before_cursor:match("@[%w_%-]*$") then
		return "mention"
	end
	if line_before_cursor:match("#%d*$") then
		return "issue"
	end
	return nil
end

--- Invalidate the cache (e.g. after creating a comment).
function M.invalidate_cache()
	cache.collaborators = nil
	cache.collaborators_time = 0
	cache.issues = nil
	cache.issues_time = 0
end

return M
