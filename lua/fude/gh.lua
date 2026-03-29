local M = {}

--- Run a gh command asynchronously.
--- @param args string[] arguments to pass to `gh`
--- @param callback fun(err: string|nil, stdout: string|nil)
--- @param stdin string|nil optional stdin data
function M.run(args, callback, stdin)
	local opts = { text = true }
	if stdin then
		opts.stdin = stdin
	end
	vim.system(vim.list_extend({ "gh" }, args), opts, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(result.stderr or "gh command failed", nil)
			else
				callback(nil, result.stdout)
			end
		end)
	end)
end

--- Run a gh command and parse the JSON output.
--- @param args string[] arguments to pass to `gh`
--- @param callback fun(err: string|nil, data: table|nil)
--- @param stdin string|nil optional stdin data
function M.run_json(args, callback, stdin)
	M.run(args, function(err, stdout)
		if err then
			return callback(err, nil)
		end
		local ok, parsed = pcall(vim.json.decode, stdout)
		if not ok then
			return callback("JSON parse error: " .. tostring(parsed), nil)
		end
		callback(nil, parsed)
	end, stdin)
end

--- Parse commits API response into PR info format.
--- Prefers open PRs when multiple results exist.
--- @param data table[]|nil array of PR objects from commits/{sha}/pulls API
--- @return table|nil pr_info {number, baseRefName, headRefName, url, state} or nil
function M.parse_pr_from_commit_api(data)
	if not data or #data == 0 then
		return nil
	end
	-- Prefer open PR
	local pr = data[1]
	for _, p in ipairs(data) do
		if p.state == "open" then
			pr = p
			break
		end
	end
	return {
		number = pr.number,
		baseRefName = (pr.base and pr.base.ref) or "",
		headRefName = (pr.head and pr.head.ref) or "",
		url = pr.html_url,
		state = pr.state,
	}
end

--- Find PR associated with a commit SHA (fallback for detached HEAD).
--- @param sha string commit SHA
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_pr_by_commit(sha, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/commits/" .. sha .. "/pulls",
	}, function(err, data)
		if err then
			return callback(err, nil)
		end
		local pr_info = M.parse_pr_from_commit_api(data)
		if not pr_info then
			return callback("No PR found for commit " .. sha:sub(1, 7), nil)
		end
		callback(nil, pr_info)
	end)
end

--- Get PR info for the current branch.
--- Detects detached HEAD synchronously and uses commit-based lookup directly,
--- avoiding `gh pr view` which may hang without a branch.
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_pr_info(callback)
	-- Detect detached HEAD: use commit-based lookup directly
	local ref_result = vim.system({ "git", "symbolic-ref", "--quiet", "HEAD" }, { text = true }):wait()
	if ref_result.code ~= 0 then
		local sha, sha_err = M.get_head_sha()
		if not sha then
			return callback(sha_err or "Not in a git repository", nil)
		end
		return M.get_pr_by_commit(sha, callback)
	end
	M.run_json({ "pr", "view", "--json", "number,baseRefName,headRefName,url,state" }, callback)
end

--- Get the list of files changed in a PR.
--- @param pr_number number
--- @param callback fun(err: string|nil, files: table|nil)
function M.get_pr_files(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/files",
		"--paginate",
	}, callback)
end

--- Get review comments on a PR.
--- @param pr_number number
--- @param callback fun(err: string|nil, comments: table|nil)
function M.get_pr_comments(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/comments",
		"--paginate",
	}, callback)
end

--- Create a single-line review comment.
--- @param pr_number number
--- @param commit_id string
--- @param path string repo-relative file path
--- @param line number line number in the file
--- @param body string comment body
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_comment(pr_number, commit_id, path, line, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/comments",
		"--method",
		"POST",
		"-f",
		"body=" .. body,
		"-f",
		"commit_id=" .. commit_id,
		"-f",
		"path=" .. path,
		"-F",
		"line=" .. line,
		"-f",
		"side=RIGHT",
	}, callback)
end

--- Create a multi-line review comment.
--- @param pr_number number
--- @param commit_id string
--- @param path string repo-relative file path
--- @param start_line number start line number
--- @param end_line number end line number
--- @param body string comment body
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_comment_range(pr_number, commit_id, path, start_line, end_line, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/comments",
		"--method",
		"POST",
		"-f",
		"body=" .. body,
		"-f",
		"commit_id=" .. commit_id,
		"-f",
		"path=" .. path,
		"-F",
		"line=" .. end_line,
		"-F",
		"start_line=" .. start_line,
		"-f",
		"side=RIGHT",
		"-f",
		"start_side=RIGHT",
	}, callback)
end

--- Reply to an existing review comment.
--- @param pr_number number
--- @param comment_id number
--- @param body string reply body
--- @param callback fun(err: string|nil, data: table|nil)
function M.reply_to_comment(pr_number, comment_id, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/comments/" .. comment_id .. "/replies",
		"--method",
		"POST",
		"-f",
		"body=" .. body,
	}, callback)
end

--- Get extended PR info for overview display.
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_pr_overview(callback)
	local fields = "number,title,body,labels,assignees,state,author,"
		.. "baseRefName,headRefName,url,statusCheckRollup,reviewRequests,latestReviews"
	M.run_json({
		"pr",
		"view",
		"--json",
		fields,
	}, callback)
end

--- Get issue-level comments on a PR (non-code-bound comments).
--- @param pr_number number
--- @param callback fun(err: string|nil, comments: table|nil)
function M.get_issue_comments(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/issues/" .. pr_number .. "/comments",
		"--paginate",
	}, callback)
end

--- Create an issue-level comment on a PR.
--- @param pr_number number
--- @param body string comment body
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_issue_comment(pr_number, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/issues/" .. pr_number .. "/comments",
		"--method",
		"POST",
		"-f",
		"body=" .. body,
	}, callback)
end

--- Update an issue-level comment.
--- @param comment_id number
--- @param body string new comment body
--- @param callback fun(err: string|nil, data: table|nil)
function M.update_issue_comment(comment_id, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/issues/comments/" .. comment_id,
		"--method",
		"PATCH",
		"-f",
		"body=" .. body,
	}, callback)
end

--- Delete an issue-level comment.
--- @param comment_id number
--- @param callback fun(err: string|nil)
function M.delete_issue_comment(comment_id, callback)
	M.run({
		"api",
		"repos/{owner}/{repo}/issues/comments/" .. comment_id,
		"--method",
		"DELETE",
	}, function(err, _)
		callback(err)
	end)
end

--- Get repository collaborators (for @mention completion).
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_collaborators(callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/collaborators",
		"--paginate",
	}, callback)
end

--- Build the GraphQL query string for fetching PR viewed files.
--- @param owner string
--- @param repo string
--- @param pr_number number
--- @param cursor string|nil pagination cursor
--- @return string query
function M.build_viewed_files_query(owner, repo, pr_number, cursor)
	local after = cursor and ('"' .. cursor .. '"') or "null"
	return string.format(
		[[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      id
      files(first: 100, after: %s) {
        pageInfo { hasNextPage endCursor }
        nodes { path viewerViewedState }
      }
    }
  }
}]],
		owner,
		repo,
		pr_number,
		after
	)
end

--- Parse viewed files from GraphQL response into a path->state map.
--- @param data table GraphQL response data
--- @return table<string, string> viewed_map, string|nil pr_node_id, boolean has_next, string|nil end_cursor
function M.parse_viewed_files_response(data)
	local pr = data.data and data.data.repository and data.data.repository.pullRequest
	if not pr then
		return {}, nil, false, nil
	end
	local viewed_map = {}
	local files = pr.files
	if files and files.nodes then
		for _, node in ipairs(files.nodes) do
			viewed_map[node.path] = node.viewerViewedState
		end
	end
	local page_info = files and files.pageInfo or {}
	return viewed_map, pr.id, page_info.hasNextPage or false, page_info.endCursor
end

--- Get the owner and repo name from gh CLI.
--- @param callback fun(err: string|nil, owner: string|nil, repo: string|nil)
function M.get_repo_owner(callback)
	M.run_json({ "repo", "view", "--json", "owner,name" }, function(err, data)
		if err then
			return callback(err)
		end
		callback(nil, data.owner.login, data.name)
	end)
end

--- Fetch viewed state for all changed files in a PR (with pagination).
--- @param pr_number number
--- @param callback fun(err: string|nil, viewed_map: table<string, string>|nil, pr_node_id: string|nil)
function M.get_pr_viewed_files(pr_number, callback)
	M.get_repo_owner(function(owner_err, owner, repo)
		if owner_err then
			return callback(owner_err)
		end

		local all_viewed = {}
		local node_id = nil

		local function fetch_page(cursor)
			local query = M.build_viewed_files_query(owner, repo, pr_number, cursor)
			M.run_json({ "api", "graphql", "-f", "query=" .. query }, function(err, data)
				if err then
					return callback(err)
				end
				local viewed_map, pr_id, has_next, end_cursor = M.parse_viewed_files_response(data)
				if pr_id then
					node_id = pr_id
				end
				for path, state in pairs(viewed_map) do
					all_viewed[path] = state
				end
				if has_next and end_cursor then
					fetch_page(end_cursor)
				else
					callback(nil, all_viewed, node_id)
				end
			end)
		end

		fetch_page(nil)
	end)
end

--- Mark a file as viewed in a PR.
--- @param pr_node_id string GraphQL node ID of the PR
--- @param path string repo-relative file path
--- @param callback fun(err: string|nil)
function M.mark_file_viewed(pr_node_id, path, callback)
	local query = [[
mutation($prId: ID!, $path: String!) {
  markFileAsViewed(input: {pullRequestId: $prId, path: $path}) {
    pullRequest { id }
  }
}]]
	M.run_json(
		{ "api", "graphql", "-f", "query=" .. query, "-f", "prId=" .. pr_node_id, "-f", "path=" .. path },
		function(err, _)
			callback(err)
		end
	)
end

--- Unmark a file as viewed in a PR.
--- @param pr_node_id string GraphQL node ID of the PR
--- @param path string repo-relative file path
--- @param callback fun(err: string|nil)
function M.unmark_file_viewed(pr_node_id, path, callback)
	local query = [[
mutation($prId: ID!, $path: String!) {
  unmarkFileAsViewed(input: {pullRequestId: $prId, path: $path}) {
    pullRequest { id }
  }
}]]
	M.run_json(
		{ "api", "graphql", "-f", "query=" .. query, "-f", "prId=" .. pr_node_id, "-f", "path=" .. path },
		function(err, _)
			callback(err)
		end
	)
end

--- Get repository issues and PRs (for #reference completion).
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_repo_issues(callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/issues?state=all&per_page=100&sort=updated&direction=desc",
	}, callback)
end

--- Get the list of commits in a PR.
--- @param pr_number number
--- @param callback fun(err: string|nil, commits: table|nil)
function M.get_pr_commits(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/commits",
		"--paginate",
	}, callback)
end

--- Get the files changed in a specific commit.
--- @param commit_sha string
--- @param callback fun(err: string|nil, files: table|nil)
function M.get_commit_files(commit_sha, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/commits/" .. commit_sha,
	}, function(err, data)
		if err then
			return callback(err, nil)
		end
		callback(nil, data.files)
	end)
end

--- Parse raw commit API objects into normalized entries.
--- @param raw_commits table[] array of commit objects from GitHub API
--- @return table[] entries array of { sha, short_sha, message, author_name, date }
function M.parse_commit_entries(raw_commits)
	local entries = {}
	for _, c in ipairs(raw_commits) do
		local commit = c.commit or {}
		local author = commit.author or {}
		local message = commit.message or ""
		-- Use only the first line of the commit message
		local first_line = message:match("^([^\n]*)") or message
		table.insert(entries, {
			sha = c.sha,
			short_sha = (c.sha or ""):sub(1, 7),
			message = first_line,
			author_name = author.name or "",
			date = author.date or "",
		})
	end
	return entries
end

--- Get the HEAD commit SHA (synchronous, local git operation).
--- @return string|nil sha, string|nil err
function M.get_head_sha()
	local result = vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait()
	if result.code == 0 then
		return vim.trim(result.stdout), nil
	end
	return nil, "Failed to get HEAD SHA"
end

--- Get all reviews on a PR.
--- @param pr_number number
--- @param callback fun(err: string|nil, reviews: table|nil)
function M.get_reviews(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews",
	}, callback)
end

--- Get comments for a specific review.
--- @param pr_number number
--- @param review_id number
--- @param callback fun(err: string|nil, comments: table|nil)
function M.get_review_comments(pr_number, review_id, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews/" .. review_id .. "/comments",
	}, callback)
end

--- Delete a review (only pending reviews can be deleted).
--- @param pr_number number
--- @param review_id number
--- @param callback fun(err: string|nil)
function M.delete_review(pr_number, review_id, callback)
	M.run({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews/" .. review_id,
		"--method",
		"DELETE",
	}, function(err, _)
		callback(err)
	end)
end

--- Create a pending review with comments (no event = PENDING state).
--- @param pr_number number
--- @param commit_id string HEAD commit SHA
--- @param review_comments table[] array of {path, line, start_line?, body, side?}
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_pending_review(pr_number, commit_id, review_comments, callback)
	local payload = {
		commit_id = commit_id,
		comments = review_comments,
	}
	local json_payload = vim.json.encode(payload)

	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews",
		"--method",
		"POST",
		"--input",
		"-",
	}, callback, json_payload)
end

--- Submit an existing pending review.
--- @param pr_number number
--- @param review_id number
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param body string|nil review body (optional)
--- @param callback fun(err: string|nil, data: table|nil)
function M.submit_review(pr_number, review_id, event, body, callback)
	local payload = {
		event = event,
	}
	if body and body ~= "" then
		payload.body = body
	end
	local json_payload = vim.json.encode(payload)

	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews/" .. review_id .. "/events",
		"--method",
		"POST",
		"--input",
		"-",
	}, callback, json_payload)
end

--- Create a PR review with comments.
--- @param pr_number number
--- @param commit_id string HEAD commit SHA
--- @param body string|nil review body (optional)
--- @param event string "COMMENT", "APPROVE", or "REQUEST_CHANGES"
--- @param review_comments table[] array of {path, line, start_line?, body}
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_review(pr_number, commit_id, body, event, review_comments, callback)
	local payload = {
		commit_id = commit_id,
		event = event,
		comments = review_comments,
	}
	if body and body ~= "" then
		payload.body = body
	end
	local json_payload = vim.json.encode(payload)

	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews",
		"--method",
		"POST",
		"--input",
		"-",
	}, callback, json_payload)
end

--- Create a draft PR on the current branch.
--- @param title string PR title
--- @param body string PR body
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_draft_pr(title, body, callback)
	M.run({
		"pr",
		"create",
		"--draft",
		"--title",
		title,
		"--body",
		body,
	}, function(err, stdout)
		if err then
			callback(err, nil)
			return
		end
		local url = stdout and vim.trim(stdout) or ""
		callback(nil, { url = url })
	end)
end

--- Get the authenticated GitHub username.
--- @param callback fun(err: string|nil, login: string|nil)
function M.get_authenticated_user(callback)
	M.run({ "api", "user", "--jq", ".login" }, function(err, stdout)
		if err then
			return callback(err, nil)
		end
		callback(nil, stdout and vim.trim(stdout) or nil)
	end)
end

--- Update a review comment body.
--- @param comment_id number
--- @param body string new comment body
--- @param callback fun(err: string|nil, data: table|nil)
function M.update_comment(comment_id, body, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/comments/" .. comment_id,
		"--method",
		"PATCH",
		"-f",
		"body=" .. body,
	}, callback)
end

--- Get PR title and body for editing.
--- When pr_number is nil, detects detached HEAD and resolves PR number first
--- to avoid `gh pr view` hanging without a branch.
--- @param pr_number number|nil PR number (nil to use current branch's PR)
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_pr_title_body(pr_number, callback)
	local function fetch(num)
		local args = { "pr", "view", "--json", "title,body" }
		if num then
			table.insert(args, 3, tostring(num))
		end
		M.run_json(args, function(err, data)
			if err then
				return callback(err, nil)
			end
			callback(nil, { title = data.title or "", body = data.body or "" })
		end)
	end

	if pr_number then
		return fetch(pr_number)
	end

	-- Detect detached HEAD: resolve PR number via commit SHA first
	local ref_result = vim.system({ "git", "symbolic-ref", "--quiet", "HEAD" }, { text = true }):wait()
	if ref_result.code ~= 0 then
		local sha, sha_err = M.get_head_sha()
		if not sha then
			return callback(sha_err or "Not in a git repository", nil)
		end
		return M.get_pr_by_commit(sha, function(err, pr_data)
			if err then
				return callback(err, nil)
			end
			fetch(pr_data.number)
		end)
	end

	fetch(nil)
end

--- Edit PR title and body.
--- @param pr_number number|nil PR number (nil to use current branch's PR)
--- @param title string
--- @param body string
--- @param callback fun(err: string|nil)
function M.edit_pr(pr_number, title, body, callback)
	local args = { "pr", "edit", "--title", title, "--body", body }
	if pr_number then
		table.insert(args, 3, tostring(pr_number))
	end
	M.run(args, function(err, _)
		callback(err)
	end)
end

--- Delete a review comment.
--- @param comment_id number
--- @param callback fun(err: string|nil)
function M.delete_comment(comment_id, callback)
	M.run({
		"api",
		"repos/{owner}/{repo}/pulls/comments/" .. comment_id,
		"--method",
		"DELETE",
	}, function(err, _)
		callback(err)
	end)
end

--- Build the GraphQL query string for fetching PR review threads.
--- @param owner string
--- @param repo string
--- @param pr_number number
--- @param cursor string|nil pagination cursor
--- @return string query
function M.build_review_threads_query(owner, repo, pr_number, cursor)
	local after = cursor and ('"' .. cursor .. '"') or "null"
	return string.format(
		[[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      reviewThreads(first: 100, after: %s) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isOutdated
          comments(first: 1) {
            nodes { databaseId path originalLine }
          }
        }
      }
    }
  }
}]],
		owner,
		repo,
		pr_number,
		after
	)
end

--- Parse review threads from GraphQL response into an outdated_map.
--- @param data table GraphQL response data
--- @return table<number, table> outdated_map { [id] = { is_outdated, original_line } }
--- @return boolean has_next
--- @return string|nil end_cursor
function M.parse_review_threads_response(data)
	local pr = data.data and data.data.repository and data.data.repository.pullRequest
	if not pr then
		return {}, false, nil
	end
	local outdated_map = {}
	local threads = pr.reviewThreads
	if threads and threads.nodes then
		for _, thread in ipairs(threads.nodes) do
			local is_outdated = thread.isOutdated or false
			local comments = thread.comments and thread.comments.nodes
			if comments then
				for _, c in ipairs(comments) do
					if c.databaseId then
						outdated_map[c.databaseId] = {
							is_outdated = is_outdated,
							original_line = c.originalLine,
						}
					end
				end
			end
		end
	end
	local page_info = threads and threads.pageInfo or {}
	return outdated_map, page_info.hasNextPage or false, page_info.endCursor
end

--- Fetch review threads for a PR (with pagination).
--- Returns a map of comment IDs to their outdated status and original line.
--- @param pr_number number
--- @param callback fun(err: string|nil, outdated_map: table<number, table>|nil)
function M.get_review_threads(pr_number, callback)
	M.get_repo_owner(function(owner_err, owner, repo)
		if owner_err then
			return callback(owner_err, nil)
		end

		local all_outdated = {}

		local function fetch_page(cursor)
			local query = M.build_review_threads_query(owner, repo, pr_number, cursor)
			M.run_json({ "api", "graphql", "-f", "query=" .. query }, function(err, response_data)
				if err then
					return callback(err, nil)
				end
				local outdated_map, has_next, end_cursor = M.parse_review_threads_response(response_data)
				for id, info in pairs(outdated_map) do
					all_outdated[id] = info
				end
				if has_next and end_cursor then
					fetch_page(end_cursor)
				else
					callback(nil, all_outdated)
				end
			end)
		end

		fetch_page(nil)
	end)
end

return M
