local M = {}
local util = require("fude.util")

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

-- Prefix of the get_pr_by_commit error for a commit with no PR (see is_no_pr_error).
local NO_PR_FOR_COMMIT = "No PR found for commit "

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
			return callback(NO_PR_FOR_COMMIT .. sha:sub(1, 7), nil)
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
	local fields = "number,title,body,labels,assignees,state,isDraft,author,"
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
--- Paginated: the endpoint returns reviews oldest first, 30 per page, and
--- every standalone review comment creates one COMMENTED review, so on a
--- long-reviewed PR the viewer's pending review (the newest) sits past the
--- first page and would otherwise never be detected.
--- @param pr_number number
--- @param callback fun(err: string|nil, reviews: table|nil)
function M.get_reviews(pr_number, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews",
		"--paginate",
	}, callback)
end

--- Get comments for a specific review (paginated, 30 per page otherwise).
--- @param pr_number number
--- @param review_id number
--- @param callback fun(err: string|nil, comments: table|nil)
function M.get_review_comments(pr_number, review_id, callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/reviews/" .. review_id .. "/comments",
		"--paginate",
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

--- Re-request a review from users who have already reviewed.
--- @param pr_number number
--- @param reviewers string[] logins to re-request; an empty list yields an error callback
--- @param callback fun(err: string|nil, data: table|nil)
function M.re_request_review(pr_number, reviewers, callback)
	-- An empty Lua table encodes as a JSON object, not an array; reject it
	-- instead of sending a malformed payload.
	if #reviewers == 0 then
		callback("reviewers must be non-empty", nil)
		return
	end

	local json_payload = vim.json.encode({ reviewers = reviewers })

	M.run_json({
		"api",
		"repos/{owner}/{repo}/pulls/" .. pr_number .. "/requested_reviewers",
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
--- @param attachments string[]|nil local file paths to upload via --attach (requires gh >= 2.99.0)
--- @param base string|nil base branch name; nil lets gh pick the repository default
--- @param callback fun(err: string|nil, data: table|nil)
function M.create_draft_pr(title, body, attachments, base, callback)
	local args = { "pr", "create", "--draft", "--title", title, "--body", body }
	if base and base ~= "" then
		vim.list_extend(args, { "--base", base })
	end
	for _, path in ipairs(attachments or {}) do
		vim.list_extend(args, { "--attach", path })
	end
	M.run(args, function(err, stdout)
		if err then
			callback(err, nil)
			return
		end
		local url = stdout and vim.trim(stdout) or ""
		callback(nil, { url = url })
	end)
end

local OPEN_PR_STACK_QUERY = [[
query($owner: String!, $name: String!, $ref: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) {
      associatedPullRequests(states: OPEN, first: 1) {
        nodes {
          url baseRefName stackEntry { position }
          stack { number size entries(last: 1) { nodes { pullRequest { url headRefName } } } }
        }
      }
    }
  }
}]]

--- Parse the top PR of a GraphQL `PullRequestStack` fetched with `entries(last: 1)`.
--- @param stack table|nil `stack` object
--- @return table|nil { url: string, branch: string }, nil when missing or malformed
function M.parse_stack_top(stack)
	local entries = type(stack) == "table" and stack.entries
	local nodes = type(entries) == "table" and entries.nodes
	local node = type(nodes) == "table" and nodes[#nodes]
	local pr = type(node) == "table" and node.pullRequest
	if type(pr) ~= "table" or type(pr.url) ~= "string" or type(pr.headRefName) ~= "string" then
		return nil
	end
	return { url = pr.url, branch = pr.headRefName }
end

--- Parse the `get_open_pr_stack` GraphQL response.
--- The PRs come from the branch ref of this repository
--- (`ref.associatedPullRequests`), so PRs opened from forks with a branch of
--- the same name never appear and need no filtering.
--- @param data table|nil decoded response
--- @return table|nil info { url: string, base_ref: string|nil, stack_number: number|nil,
---   stack_size: number|nil, stack_position: number|nil (1-based, bottom first),
---   stack_top: { url: string, branch: string }|nil (the PR at the top of the stack) }, nil when there is no open PR
function M.parse_open_pr_stack(data)
	local repo = type(data) == "table" and type(data.data) == "table" and data.data.repository
	local ref = type(repo) == "table" and repo.ref
	local prs = type(ref) == "table" and ref.associatedPullRequests
	local nodes = type(prs) == "table" and prs.nodes
	local node = type(nodes) == "table" and nodes[1]
	if type(node) ~= "table" or type(node.url) ~= "string" then
		return nil
	end
	local function number_field(t, key)
		return type(t) == "table" and type(t[key]) == "number" and t[key] or nil
	end
	return {
		url = node.url,
		base_ref = type(node.baseRefName) == "string" and node.baseRefName or nil,
		stack_number = number_field(node.stack, "number"),
		stack_size = number_field(node.stack, "size"),
		stack_position = number_field(node.stackEntry, "position"),
		stack_top = M.parse_stack_top(node.stack),
	}
end

--- Get the open PR whose head is `branch`, with the GitHub stack it belongs to.
--- A missing PR is an empty result rather than an error, so "no PR" and a
--- failed lookup (auth, network, ...) reach the caller separately.
--- @param branch string head branch name
--- @param callback fun(err: string|nil, info: table|nil) err is set only when the lookup failed;
---   info is the `parse_open_pr_stack` result (stack fields nil when the PR is in no stack),
---   nil when there is no open PR
function M.get_open_pr_stack(branch, callback)
	M.run_json({
		"api",
		"graphql",
		"-F",
		"owner={owner}",
		"-F",
		"name={repo}",
		"-f",
		"ref=refs/heads/" .. branch,
		"-f",
		"query=" .. OPEN_PR_STACK_QUERY,
	}, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		callback(nil, M.parse_open_pr_stack(data))
	end)
end

-- `first: 100`: a stack taller than that loses its top PRs in the picker
local PR_STACK_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      stack {
        entries(first: 100) {
          nodes { pullRequest { number title state headRefName baseRefName } }
        }
      }
    }
  }
}]]

--- Parse the `get_pr_stack` GraphQL response.
--- Entries come bottom first (the order `entries(last: 1)` relies on for the top).
--- Malformed nodes are skipped.
--- @param data table|nil decoded response
--- @return table[]|nil prs { number, title, state, head_ref, base_ref }[] bottom first,
---   nil when the PR is in no stack
function M.parse_pr_stack(data)
	local repo = type(data) == "table" and type(data.data) == "table" and data.data.repository
	local pr = type(repo) == "table" and repo.pullRequest
	local stack = type(pr) == "table" and pr.stack
	local entries = type(stack) == "table" and stack.entries
	local nodes = type(entries) == "table" and entries.nodes
	if type(nodes) ~= "table" then
		return nil
	end
	local prs = {}
	for _, node in ipairs(nodes) do
		local p = type(node) == "table" and node.pullRequest
		if type(p) == "table" and type(p.number) == "number" and type(p.headRefName) == "string" then
			table.insert(prs, {
				number = p.number,
				title = type(p.title) == "string" and p.title or "",
				state = type(p.state) == "string" and p.state or "",
				head_ref = p.headRefName,
				base_ref = type(p.baseRefName) == "string" and p.baseRefName or "",
			})
		end
	end
	return prs
end

--- Get the GitHub stack the PR belongs to.
--- @param pr_number number
--- @param callback fun(err: string|nil, prs: table[]|nil) prs is the `parse_pr_stack` result
---   (nil when the PR is in no stack); err is set only when the lookup failed
function M.get_pr_stack(pr_number, callback)
	M.run_json({
		"api",
		"graphql",
		"-F",
		"owner={owner}",
		"-F",
		"name={repo}",
		"-F",
		"number=" .. pr_number,
		"-f",
		"query=" .. PR_STACK_QUERY,
	}, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		callback(nil, M.parse_pr_stack(data))
	end)
end

--- Check out a PR's head branch in the current worktree (`gh pr checkout`).
--- @param pr_number number
--- @param callback fun(err: string|nil)
function M.checkout_pr(pr_number, callback)
	M.run({ "pr", "checkout", tostring(pr_number) }, function(err)
		callback(err)
	end)
end

--- Link PRs into a GitHub stacked PR chain via the gh-stack extension
--- (`gh stack link`, which does not depend on gh-stack's local tracking state).
--- `refs` are PR URLs in stack order (bottom → top); a first ref that is an
--- existing stack number appends the rest to the top of that stack. Without a
--- stack number, gh-stack creates a new stack, or updates the stack the PRs
--- belong to only when every PR already in it is listed.
--- @param refs string[] stack number and/or PR URLs
--- @param base string|nil base branch for the bottom of a new stack (`--base`; gh-stack
---   defaults to the default branch and retargets the bottom PR to it)
--- @param callback fun(err: string|nil)
function M.link_stack(refs, base, callback)
	local args = { "stack", "link" }
	if base then
		vim.list_extend(args, { "--base", base })
	end
	vim.list_extend(args, refs)
	M.run(args, function(err)
		callback(err)
	end)
end

--- Check the stack command and repository API without creating or changing PRs.
--- A successful read does not guarantee a later stack mutation will succeed.
--- @param callback fun(err: string|nil)
function M.check_stack_available(callback)
	M.run({ "stack", "link", "--help" }, function(err)
		if err then
			callback("gh stack link is unavailable: " .. err)
			return
		end
		-- This is a capability probe, not a listing: one result is sufficient.
		M.run({ "api", "repos/{owner}/{repo}/stacks?per_page=1" }, function(api_err)
			callback(api_err and ("Cannot access repository stacks: " .. api_err) or nil)
		end)
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

--- Resolve which PR a `gh pr view`-style command should target.
--- An explicit number is used as is. On a detached HEAD the number is looked up
--- from the commit, since `gh pr view` without a branch may hang. Otherwise nil
--- is passed on, letting gh pick the current branch's PR.
--- @param pr_number number|nil
--- @param callback fun(err: string|nil, pr_number: number|nil)
local function resolve_pr_number(pr_number, callback)
	if pr_number then
		return callback(nil, pr_number)
	end
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
			callback(nil, pr_data.number)
		end)
	end
	callback(nil, nil)
end

--- Get PR title and body for editing.
--- When pr_number is nil, detects detached HEAD and resolves PR number first
--- to avoid `gh pr view` hanging without a branch.
--- Includes the PR url so callers can derive the repo slug without an active
--- review session (state.pr_url only exists while a review is active).
--- @param pr_number number|nil PR number (nil to use current branch's PR)
--- @param callback fun(err: string|nil, data: table|nil) data = { title, body, url }
function M.get_pr_title_body(pr_number, callback)
	local function fetch(num)
		local args = { "pr", "view", "--json", "title,body,url" }
		if num then
			table.insert(args, 3, tostring(num))
		end
		M.run_json(args, function(err, data)
			if err then
				return callback(err, nil)
			end
			-- JSON null decodes to vim.NIL (truthy userdata), which would slip
			-- through `or ""` and crash string consumers (repo_slug, vim.split)
			callback(nil, {
				title = util.null_to(data.title, ""),
				body = util.null_to(data.body, ""),
				url = util.null_to(data.url),
			})
		end)
	end

	resolve_pr_number(pr_number, function(err, num)
		if err then
			return callback(err, nil)
		end
		fetch(num)
	end)
end

--- Get the PR's open/closed/merged state and draft flag.
--- @param pr_number number|nil PR number (nil to use current branch's PR)
--- @param callback fun(err: string|nil, data: table|nil) data = { number, state, is_draft, url }
function M.get_pr_state(pr_number, callback)
	resolve_pr_number(pr_number, function(resolve_err, num)
		if resolve_err then
			return callback(resolve_err, nil)
		end
		local args = { "pr", "view", "--json", "number,state,isDraft,url" }
		if num then
			table.insert(args, 3, tostring(num))
		end
		M.run_json(args, function(err, data)
			if err then
				return callback(err, nil)
			end
			callback(nil, {
				number = util.null_to(data.number),
				state = util.null_to(data.state, ""),
				is_draft = data.isDraft == true,
				url = util.null_to(data.url),
			})
		end)
	end)
end

--- Whether a PR lookup error means there simply is no PR, as opposed to an
--- auth or network failure, which also exits non-zero. Covers both lookups
--- `resolve_pr_number` can make: `gh pr view` on a branch and, on a detached
--- HEAD, `get_pr_by_commit`.
--- @param err string|nil
--- @return boolean
function M.is_no_pr_error(err)
	if type(err) ~= "string" then
		return false
	end
	return err:find("no pull requests found", 1, true) ~= nil or err:find(NO_PR_FOR_COMMIT, 1, true) == 1
end

--- Build the gh arguments that move a PR to another state.
--- @param action string "ready" | "draft" | "close" | "reopen"
--- @param pr_number number
--- @return string[]|nil args nil for an unknown action
function M.build_pr_state_args(action, pr_number)
	local num = tostring(pr_number)
	if action == "ready" then
		return { "pr", "ready", num }
	elseif action == "draft" then
		return { "pr", "ready", num, "--undo" }
	elseif action == "close" then
		return { "pr", "close", num }
	elseif action == "reopen" then
		return { "pr", "reopen", num }
	end
	return nil
end

--- Move a PR to another state (ready for review, draft, closed, reopened).
--- @param action string "ready" | "draft" | "close" | "reopen"
--- @param pr_number number
--- @param callback fun(err: string|nil)
function M.set_pr_state(action, pr_number, callback)
	local args = M.build_pr_state_args(action, pr_number)
	if not args then
		return callback("Unknown PR state action: " .. tostring(action))
	end
	M.run(args, function(err, _)
		callback(err)
	end)
end

--- Edit PR title and body.
--- @param pr_number number|nil PR number (nil to use current branch's PR)
--- @param title string
--- @param body string
--- @param attachments string[]|nil local file paths to upload via --attach (requires gh >= 2.99.0)
--- @param callback fun(err: string|nil)
function M.edit_pr(pr_number, title, body, attachments, callback)
	local args = { "pr", "edit", "--title", title, "--body", body }
	if pr_number then
		table.insert(args, 3, tostring(pr_number))
	end
	for _, path in ipairs(attachments or {}) do
		vim.list_extend(args, { "--attach", path })
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
	-- comments(first: 1) intentionally fetches only the top-level comment per thread:
	-- thread_map keys reply targets by their root comment id (get_reply_target_id resolves
	-- replies to their top-level), and outdated info is per-thread so the root is sufficient.
	-- This avoids pagination issues for threads with many replies.
	return string.format(
		[[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      reviewThreads(first: 100, after: %s) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isOutdated
          isResolved
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

--- Parse review threads from GraphQL response into thread_info_map and thread_map.
--- @param data table GraphQL response data
--- @return table<number, table> thread_info_map { [id] = { is_outdated, is_resolved, original_line } }
--- @return table<number, string> thread_map { [comment_id] = thread_node_id }
--- @return boolean has_next
--- @return string|nil end_cursor
function M.parse_review_threads_response(data)
	local pr = data.data and data.data.repository and data.data.repository.pullRequest
	if not pr then
		return {}, {}, false, nil
	end
	local thread_info_map = {}
	local thread_map = {}
	local threads = pr.reviewThreads
	if threads and threads.nodes then
		for _, thread in ipairs(threads.nodes) do
			local is_outdated = thread.isOutdated or false
			local is_resolved = thread.isResolved or false
			local thread_id = thread.id
			local comments = thread.comments and thread.comments.nodes
			if comments then
				for _, c in ipairs(comments) do
					if c.databaseId then
						thread_info_map[c.databaseId] = {
							is_outdated = is_outdated,
							is_resolved = is_resolved,
							original_line = c.originalLine,
						}
						if thread_id then
							thread_map[c.databaseId] = thread_id
						end
					end
				end
			end
		end
	end
	local page_info = threads and threads.pageInfo or {}
	return thread_info_map, thread_map, page_info.hasNextPage or false, page_info.endCursor
end

--- Fetch review threads for a PR (with pagination).
--- Returns per-thread info (outdated/resolved) and a comment_id → thread_node_id mapping.
--- @param pr_number number
--- @param callback fun(err: string|nil, thread_info_map: table|nil, thread_map: table<number, string>|nil)
function M.get_review_threads(pr_number, callback)
	M.get_repo_owner(function(owner_err, owner, repo)
		if owner_err then
			return callback(owner_err, nil, nil)
		end

		local all_infos = {}
		local all_threads = {}

		local function fetch_page(cursor)
			local query = M.build_review_threads_query(owner, repo, pr_number, cursor)
			M.run_json({ "api", "graphql", "-f", "query=" .. query }, function(err, response_data)
				if err then
					return callback(err, nil, nil)
				end
				local thread_info_map, thread_map, has_next, end_cursor = M.parse_review_threads_response(response_data)
				for id, info in pairs(thread_info_map) do
					all_infos[id] = info
				end
				for id, tid in pairs(thread_map) do
					all_threads[id] = tid
				end
				if has_next and end_cursor then
					fetch_page(end_cursor)
				else
					callback(nil, all_infos, all_threads)
				end
			end)
		end

		fetch_page(nil)
	end)
end

--- Reply to a review thread, attached to an existing pending review.
--- The REST `pulls/{pr}/comments/{id}/replies` endpoint fails with 422 when a
--- pending review exists, so this GraphQL mutation is used instead.
--- @param thread_id string GraphQL node ID of the review thread
--- @param review_id string GraphQL node ID of the pending review
--- @param body string reply body
--- @param callback fun(err: string|nil, data: table|nil)
function M.add_review_thread_reply(thread_id, review_id, body, callback)
	local query = [[
mutation($threadId: ID!, $reviewId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: $threadId,
    pullRequestReviewId: $reviewId,
    body: $body
  }) {
    comment { id databaseId }
  }
}]]
	M.run_json({
		"api",
		"graphql",
		"-f",
		"query=" .. query,
		"-f",
		"threadId=" .. thread_id,
		"-f",
		"reviewId=" .. review_id,
		"-f",
		"body=" .. body,
	}, callback)
end

--- Build the GraphQL mutation that resolves or unresolves a review thread.
--- @param resolved boolean true for resolveReviewThread, false for unresolveReviewThread
--- @return string query
function M.build_resolve_thread_mutation(resolved)
	local name = resolved and "resolveReviewThread" or "unresolveReviewThread"
	return string.format(
		[[
mutation($threadId: ID!) {
  %s(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}]],
		name
	)
end

--- Resolve or unresolve a review thread.
--- @param thread_id string GraphQL node ID of the review thread
--- @param resolved boolean desired resolved state
--- @param callback fun(err: string|nil, data: table|nil)
function M.set_review_thread_resolved(thread_id, resolved, callback)
	M.run_json({
		"api",
		"graphql",
		"-f",
		"query=" .. M.build_resolve_thread_mutation(resolved),
		"-f",
		"threadId=" .. thread_id,
	}, callback)
end

return M
