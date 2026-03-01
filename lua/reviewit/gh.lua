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

--- Get PR info for the current branch.
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_pr_info(callback)
	M.run_json({ "pr", "view", "--json", "number,baseRefName,headRefName,url" }, callback)
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
	M.run_json({
		"pr",
		"view",
		"--json",
		"number,title,body,labels,state,author,baseRefName,headRefName,url",
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

--- Get repository collaborators (for @mention completion).
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_collaborators(callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/collaborators",
		"--paginate",
	}, callback)
end

--- Get repository issues and PRs (for #reference completion).
--- @param callback fun(err: string|nil, data: table|nil)
function M.get_repo_issues(callback)
	M.run_json({
		"api",
		"repos/{owner}/{repo}/issues?state=all&per_page=100&sort=updated&direction=desc",
	}, callback)
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

return M
