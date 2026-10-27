local M = {}
local gh = require("fude.gh")

local CACHE_TTL = 300 -- 5 minutes
local pr_contexts = {}

--- Register a PR body without marking it as a comment input (which would
--- make ui.close_comment_ui close it). Each float owns its repository/cache.
--- @param buf number
--- @param opts table { cwd: string, base?: string, pr_number?: number }
function M.attach_pr(buf, opts)
	pr_contexts[buf] = {
		cwd = opts.cwd,
		base = opts.base,
		pr_number = opts.pr_number,
		tip = not opts.pr_number and require("fude.diff").get_head_sha(opts.cwd) or nil,
		cache = {},
	}
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			pr_contexts[buf] = nil
		end,
	})
end

--- Whether this buffer accepts fude completion (not ordinary Markdown).
--- @param buf number|nil defaults to the current buffer
--- @return boolean
function M.is_enabled(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	return vim.api.nvim_buf_is_valid(buf) and (vim.b[buf].fude_comment == true or pr_contexts[buf] ~= nil)
end

local cache = {
	collaborators = nil,
	collaborators_time = 0,
	issues = nil,
	issues_time = 0,
	commits = nil,
	commits_source = nil, -- reference to state.pr_commits used to build cache
}

--- Check if cached data is still valid.
--- @param data_cache table shared comment cache or a PR body's cache
--- @param key string cache key
--- @return boolean
local function cache_valid(data_cache, key)
	return data_cache[key] ~= nil and (os.time() - data_cache[key .. "_time"]) < CACHE_TTL
end

local function context_for(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	return pr_contexts[buf], buf
end

local function context_alive(ctx, buf)
	return ctx == nil or (vim.api.nvim_buf_is_valid(buf) and pr_contexts[buf] == ctx)
end

--- Fetch collaborators and return completion items via callback.
--- @param callback fun(items: table[])
--- @param buf number|nil completion request buffer
function M.fetch_mentions(callback, buf)
	local ctx
	ctx, buf = context_for(buf)
	local data_cache = ctx and ctx.cache or cache
	if cache_valid(data_cache, "collaborators") then
		return callback(data_cache.collaborators)
	end

	gh.get_collaborators(function(err, data)
		if not context_alive(ctx, buf) or err or not data then
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

		data_cache.collaborators = items
		data_cache.collaborators_time = os.time()
		callback(items)
	end, ctx and ctx.cwd)
end

--- Fetch issues/PRs and return completion items via callback.
--- @param callback fun(items: table[])
--- @param buf number|nil completion request buffer
function M.fetch_issues(callback, buf)
	local ctx
	ctx, buf = context_for(buf)
	local data_cache = ctx and ctx.cache or cache
	if cache_valid(data_cache, "issues") then
		return callback(data_cache.issues)
	end

	gh.get_repo_issues(function(err, data)
		if not context_alive(ctx, buf) or err or not data then
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

		data_cache.issues = items
		data_cache.issues_time = os.time()
		callback(items)
	end, ctx and ctx.cwd)
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
--- @param commit_entries table[] array of { sha, short_sha, message, author_name, date }
--- @return table[] items completion items
function M.build_commit_items(commit_entries)
	local items = {}
	local total = #commit_entries
	for i, c in ipairs(commit_entries) do
		local display = string.format("[%d/%d] %s %s (%s)", i, total, c.short_sha, c.message, c.author_name)
		table.insert(items, {
			label = display,
			insertText = c.short_sha,
			filterText = "_" .. display,
			sortText = string.format("%05d", i),
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

--- Parse git log's unit-separated fields; the subject is the final field so
--- tabs, pipes and separator characters in a subject remain intact.
--- @param output string
--- @return table[] entries compatible with build_commit_items
function M.parse_git_commits(output)
	local entries = {}
	for line in output:gmatch("[^\r\n]+") do
		local sha, short_sha, author, date, message = line:match("^([^\31]+)\31([^\31]+)\31([^\31]*)\31([^\31]*)\31(.*)$")
		if sha then
			table.insert(entries, { sha = sha, short_sha = short_sha, author_name = author, date = date, message = message })
		end
	end
	return entries
end

-- PR creation has no GitHub PR yet. Read the selected base..tip locally so
-- unpushed commits are available too, without blocking the editor on git log.
local function fetch_local_commits(ctx, buf, callback)
	if not ctx.tip then
		return callback(nil, {})
	end
	local function run(base, retry)
		local args = {
			"git",
			"log",
			"--no-show-signature",
			"--reverse",
			"--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s",
		}
		if not base then
			vim.list_extend(args, { "-n", "100" })
		end
		vim.list_extend(args, { "--end-of-options", base and (base .. ".." .. ctx.tip) or ctx.tip, "--" })
		vim.system(args, { text = true, cwd = ctx.cwd }, function(result)
			vim.schedule(function()
				if not context_alive(ctx, buf) then
					return callback("PR body closed")
				end
				if result.code ~= 0 and retry then
					return run("origin/" .. base, false)
				end
				if result.code ~= 0 then
					return callback(result.stderr or "git log failed")
				end
				callback(nil, M.parse_git_commits(result.stdout or ""))
			end)
		end)
	end
	run(ctx.base, ctx.base ~= nil)
end

local function fetch_pr_body_commits(ctx, buf, callback)
	if ctx.cache.commits then
		return callback(ctx.cache.commits)
	end
	if ctx.pending then
		table.insert(ctx.pending, callback)
		return
	end
	ctx.pending = { callback }
	local function done(err, entries)
		local items = {}
		if context_alive(ctx, buf) and not err then
			items = M.build_commit_items(entries or {})
			ctx.cache.commits = items
		end
		local pending = ctx.pending
		ctx.pending = nil
		for _, cb in ipairs(pending) do
			cb(items)
		end
	end
	if ctx.pr_number then
		gh.get_pr_commits(ctx.pr_number, function(err, raw)
			if not context_alive(ctx, buf) then
				return done("PR body closed")
			end
			done(err, not err and gh.parse_commit_entries(raw or {}) or nil)
		end, ctx.cwd)
	else
		fetch_local_commits(ctx, buf, done)
	end
end

--- Fetch commits from the PR body's own context, or the review session for
--- comment inputs. PR body results live until that body is wiped; review
--- results are invalidated when state.pr_commits changes.
--- @param callback fun(items: table[])
--- @param buf number|nil completion request buffer
function M.fetch_commits(callback, buf)
	local ctx
	ctx, buf = context_for(buf)
	if ctx then
		return fetch_pr_body_commits(ctx, buf, callback)
	end
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
