local M = {}

--- Normalize newlines by converting CRLF and CR to LF.
--- @param s string|nil input string
--- @return string normalized string
local function normalize_newlines(s)
	return (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

--- Calculate centered float window dimensions from percentage-based sizes.
--- @param columns number screen width
--- @param screen_lines number screen height
--- @param pct_w number width percentage (0-100)
--- @param pct_h number height percentage (0-100)
--- @return table { width: number, height: number, row: number, col: number }
function M.calculate_float_dimensions(columns, screen_lines, pct_w, pct_h)
	local width = math.floor(columns * pct_w / 100)
	local height = math.floor(screen_lines * pct_h / 100)
	local row = math.floor((screen_lines - height) / 2)
	local col = math.floor((columns - width) / 2)
	return { width = width, height = height, row = row, col = col }
end

--- Format comment objects into display lines and highlight ranges.
--- @param comments table[] list of comment objects
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comments_for_display(comments, format_date_fn)
	local lines = {}
	local hl_ranges = {}
	local comment_ranges = {}
	for i, comment in ipairs(comments) do
		local start_line = #lines
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
		local header = string.format("@%s  %s", author, created)
		table.insert(lines, header)
		table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })
		local comment_body = normalize_newlines(comment.body)
		for _, body_line in ipairs(vim.split(comment_body, "\n")) do
			table.insert(lines, body_line)
		end
		table.insert(comment_ranges, { start_line = start_line, end_line = #lines - 1, index = i })
		if i < #comments then
			table.insert(lines, "")
			table.insert(lines, string.rep("-", 40))
			table.insert(lines, "")
		end
	end
	return { lines = lines, hl_ranges = hl_ranges, comment_ranges = comment_ranges }
end

--- Normalize check fields into a consistent (status, conclusion) pair.
--- Handles both CheckRun (status/conclusion) and StatusContext (state) objects.
--- @param check table check run or status context object
--- @return string status, string conclusion
function M.normalize_check(check)
	-- CheckRun: has status/conclusion fields
	if check.status or check.conclusion then
		return check.status or "", check.conclusion or ""
	end

	-- StatusContext: has state field (uppercase: "SUCCESS", "FAILURE", "PENDING", "ERROR", "EXPECTED")
	local state = (check.state or ""):upper()
	if state == "SUCCESS" then
		return "COMPLETED", "SUCCESS"
	elseif state == "EXPECTED" then
		return "PENDING", ""
	elseif state == "FAILURE" then
		return "COMPLETED", "FAILURE"
	elseif state == "ERROR" then
		return "COMPLETED", "FAILURE"
	elseif state == "PENDING" then
		return "PENDING", ""
	end

	return "", ""
end

--- Map check conclusion/status to display symbol and highlight group.
--- @param check table check run or status context object from statusCheckRollup
--- @return string symbol, string hl_group
function M.format_check_status(check)
	local status, conclusion = M.normalize_check(check)

	-- Not yet completed
	if status == "IN_PROGRESS" or status == "QUEUED" or status == "PENDING" then
		return "●", "DiagnosticWarn"
	end

	-- Completed with conclusion
	if conclusion == "SUCCESS" then
		return "✓", "DiagnosticOk"
	elseif conclusion == "FAILURE" or conclusion == "TIMED_OUT" or conclusion == "STARTUP_FAILURE" then
		return "✗", "DiagnosticError"
	elseif conclusion == "NEUTRAL" or conclusion == "SKIPPED" then
		return "-", "Comment"
	elseif conclusion == "CANCELLED" or conclusion == "ACTION_REQUIRED" then
		return "!", "DiagnosticWarn"
	end

	return "?", "Comment"
end

--- Deduplicate checks by name, keeping the latest entry for each.
--- @param checks table[] statusCheckRollup array
--- @return table[] deduplicated checks preserving first-appearance order
function M.deduplicate_checks(checks)
	local seen = {}
	local order = {}
	for _, check in ipairs(checks) do
		local key = check.name or check.context or "unknown"
		if not seen[key] then
			table.insert(order, key)
		end
		seen[key] = check
	end
	local result = {}
	for _, key in ipairs(order) do
		table.insert(result, seen[key])
	end
	return result
end

--- Get sort priority for a check (lower = shown first).
--- @param check table check run or StatusContext object from statusCheckRollup
--- @return number priority, string name
local function check_sort_key(check)
	local status, conclusion = M.normalize_check(check)
	local name = check.name or check.context or "unknown"

	local priority
	if conclusion == "FAILURE" or conclusion == "TIMED_OUT" or conclusion == "STARTUP_FAILURE" then
		priority = 1
	elseif conclusion == "CANCELLED" or conclusion == "ACTION_REQUIRED" then
		priority = 2
	elseif conclusion == "SKIPPED" or conclusion == "NEUTRAL" then
		priority = 3
	elseif status == "IN_PROGRESS" or status == "QUEUED" or status == "PENDING" then
		priority = 4
	elseif conclusion == "SUCCESS" then
		priority = 5
	else
		priority = 6
	end

	return priority, name
end

--- Sort checks by priority: failures first, then cancelled/action-required, then skipped/neutral,
--- then in-progress, then success, then any remaining states.
--- Within the same priority, checks are sorted alphabetically by name.
--- @param checks table[] statusCheckRollup array
--- @return table[] sorted copy of checks
function M.sort_checks(checks)
	local sorted = {}
	for i, check in ipairs(checks) do
		sorted[i] = check
	end
	table.sort(sorted, function(a, b)
		local pa, na = check_sort_key(a)
		local pb, nb = check_sort_key(b)
		if pa ~= pb then
			return pa < pb
		end
		return na < nb
	end)
	return sorted
end

--- Build summary string for checks (e.g. "2/3 passed").
--- @param checks table[] statusCheckRollup array
--- @return string
function M.build_checks_summary(checks)
	if #checks == 0 then
		return ""
	end
	local passed = 0
	for _, check in ipairs(checks) do
		local _, conclusion = M.normalize_check(check)
		if conclusion == "SUCCESS" or conclusion == "NEUTRAL" or conclusion == "SKIPPED" then
			passed = passed + 1
		end
	end
	return string.format("%d/%d passed", passed, #checks)
end

--- Map review state to display symbol and highlight group.
--- @param state string review state ("APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING")
--- @return string symbol, string hl_group
function M.format_review_status(state)
	if state == "APPROVED" then
		return "✓", "DiagnosticOk"
	elseif state == "CHANGES_REQUESTED" then
		return "✗", "DiagnosticError"
	elseif state == "COMMENTED" then
		return "💬", "DiagnosticInfo"
	elseif state == "DISMISSED" then
		return "-", "Comment"
	elseif state == "PENDING" then
		return "●", "DiagnosticWarn"
	end
	return "?", "Comment"
end

--- Build a unified list of reviewers from review requests and latest reviews.
--- Reviewers who appear in both lists use the latestReviews state.
--- @param review_requests table[] reviewRequests from gh pr view (each has login)
--- @param latest_reviews table[] latestReviews from gh pr view (each has author.login, state)
--- @return table[] list of { login: string, state: string } sorted by login
function M.build_reviewers_list(review_requests, latest_reviews)
	local reviewers = {}
	local seen = {}

	-- Add reviewers from latestReviews first (they have actual review state)
	for _, review in ipairs(latest_reviews) do
		local login = review.author and review.author.login
		if login and not seen[login] then
			seen[login] = true
			table.insert(reviewers, { login = login, state = review.state or "COMMENTED" })
		end
	end

	-- Add remaining reviewers from reviewRequests as PENDING
	for _, req in ipairs(review_requests) do
		local login = req.login
		if login and not seen[login] then
			seen[login] = true
			table.insert(reviewers, { login = login, state = "PENDING" })
		end
	end

	table.sort(reviewers, function(a, b)
		return a.login < b.login
	end)

	return reviewers
end

--- Build summary string for reviewers (e.g. "1/2 approved").
--- @param reviewers table[] list of { login: string, state: string }
--- @return string
function M.build_reviewers_summary(reviewers)
	if #reviewers == 0 then
		return ""
	end
	local approved = 0
	for _, reviewer in ipairs(reviewers) do
		if reviewer.state == "APPROVED" then
			approved = approved + 1
		end
	end
	return string.format("%d/%d approved", approved, #reviewers)
end

--- Calculate layout for split-pane overview windows.
--- @param columns number screen width
--- @param screen_lines number screen height
--- @param pct_w number total width percentage (0-100)
--- @param pct_h number total height percentage (0-100)
--- @param right_pct number right pane width as percentage of total (0-100)
--- @return table { left: { width, height, row, col }, right: { width, height, row, col } }
function M.calculate_overview_layout(columns, screen_lines, pct_w, pct_h, right_pct)
	local min_left = 20
	local min_right = 15
	local min_inner = min_left + min_right

	right_pct = math.max(0, math.min(100, right_pct))
	local total_width = math.max(math.floor(columns * pct_w / 100), min_inner + 4)
	local height = math.floor(screen_lines * pct_h / 100)
	local top_row = math.floor((screen_lines - height) / 2)
	local start_col = math.floor((columns - total_width) / 2)
	-- Each window has 2 border chars (left+right), 2 windows = 4 border chars total
	local inner = total_width - 4
	local right_width = math.min(math.max(math.floor(inner * right_pct / 100), min_right), inner - min_left)
	local left_width = inner - right_width
	return {
		left = { width = left_width, height = height, row = top_row, col = start_col },
		right = { width = right_width, height = height, row = top_row, col = start_col + left_width + 2 },
	}
end

--- Calculate upper window height for reply view.
--- @param line_count number total lines of formatted comments
--- @param min_height number minimum height
--- @param max_height number maximum height
--- @return number height
function M.calculate_comments_height(line_count, min_height, max_height)
	return math.max(min_height, math.min(line_count, max_height))
end

--- Calculate dimensions for reply window (upper + lower).
--- @param screen_cols number screen width
--- @param screen_lines number screen height
--- @param comment_line_count number total lines of formatted comments
--- @param opts table|nil options
---   { min_upper_height?: number, max_upper_pct?: number, lower_height?: number,
---     max_width?: number, width_pct?: number }
--- @return table { width: number, upper_height: number, lower_height: number, row: number, col: number }
function M.calculate_reply_window_dimensions(screen_cols, screen_lines, comment_line_count, opts)
	opts = opts or {}
	local width_pct = opts.width_pct or 0.6
	local max_width = opts.max_width or 80
	local min_upper = opts.min_upper_height or 3
	local max_upper_pct = opts.max_upper_pct or 0.5
	local lower_height = opts.lower_height or 5

	local width = math.min(math.floor(screen_cols * width_pct), max_width)
	local max_upper = math.floor(screen_lines * max_upper_pct)
	local upper_height = M.calculate_comments_height(comment_line_count, min_upper, max_upper)

	local total_height = upper_height + lower_height
	local row = math.floor((screen_lines - total_height) / 2)
	local col = math.floor((screen_cols - width) / 2)

	return {
		width = width,
		upper_height = upper_height,
		lower_height = lower_height,
		row = row,
		col = col,
	}
end

--- Format comments for reply window display with detailed highlight ranges.
--- @param comments table[] list of comment objects
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_reply_comments_for_display(comments, format_date_fn)
	local lines = {}
	local hl_ranges = {}
	for i, comment in ipairs(comments) do
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
		local header = string.format("@%s (%s):", author, created)
		local header_line_idx = #lines
		table.insert(lines, header)
		-- Author highlight: from 0 to end of @username
		local author_end = #author + 1 -- "@" + username
		table.insert(hl_ranges, { line = header_line_idx, col_start = 0, col_end = author_end, hl = "ReviewCommentAuthor" })
		-- Timestamp highlight: inside parentheses
		local ts_start = author_end + 2 -- " ("
		local ts_end = ts_start + #created
		table.insert(
			hl_ranges,
			{ line = header_line_idx, col_start = ts_start, col_end = ts_end, hl = "ReviewCommentTimestamp" }
		)

		local comment_body = normalize_newlines(comment.body)
		for _, body_line in ipairs(vim.split(comment_body, "\n")) do
			table.insert(lines, body_line)
		end

		if i < #comments then
			table.insert(lines, "")
			table.insert(lines, string.rep("-", 40))
			table.insert(lines, "")
		end
	end
	return { lines = lines, hl_ranges = hl_ranges }
end

--- Build display lines for the left pane of PR overview (header, description, comments).
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[], sections: table, comment_positions: number[] }
function M.build_overview_left_lines(pr_info, issue_comments, format_date_fn)
	local lines = {}
	local hl_ranges = {}
	local sections = {}
	local comment_positions = {}

	-- PR header
	local title = string.format("PR #%d: %s", pr_info.number or 0, pr_info.title or "")
	table.insert(lines, title)
	table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })

	local author = pr_info.author and pr_info.author.login or "unknown"
	table.insert(lines, string.format("State: %s    Author: @%s", pr_info.state or "UNKNOWN", author))

	table.insert(lines, string.format("Base: %s <- %s", pr_info.baseRefName or "", pr_info.headRefName or ""))
	table.insert(lines, pr_info.url or "")

	-- Description
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	local desc_header_line = #lines
	table.insert(lines, "DESCRIPTION")
	sections.description = #lines -- 1-indexed
	table.insert(hl_ranges, { line = desc_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 50))

	local body = normalize_newlines(pr_info.body)
	if body == "" then
		table.insert(lines, "(no description)")
	else
		for _, body_line in ipairs(vim.split(body, "\n")) do
			table.insert(lines, body_line)
		end
	end

	-- Comments
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	local comments_header_line = #lines
	table.insert(lines, string.format("COMMENTS (%d)", #issue_comments))
	sections.comments = #lines -- 1-indexed
	table.insert(hl_ranges, { line = comments_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 50))

	if #issue_comments == 0 then
		table.insert(lines, "(no comments)")
	else
		for i, comment in ipairs(issue_comments) do
			local comment_author = comment.user and comment.user.login or "unknown"
			local created = format_date_fn(comment.created_at)
			table.insert(lines, "")
			local header = string.format("@%s  %s", comment_author, created)
			table.insert(lines, header)
			table.insert(comment_positions, #lines) -- 1-indexed header line
			table.insert(hl_ranges, { line = #lines - 1, hl = "Special" })
			local comment_body = normalize_newlines(comment.body)
			for _, body_line in ipairs(vim.split(comment_body, "\n")) do
				table.insert(lines, body_line)
			end
			if i < #issue_comments then
				table.insert(lines, "")
				table.insert(lines, string.rep("-", 30))
			end
		end
	end

	-- Footer
	table.insert(lines, "")
	table.insert(lines, " ]s/[s: sections  ]c/[c: comments  C: comment  R: refresh  <Tab>: switch  q: close")
	table.insert(hl_ranges, { line = #lines - 1, hl = "Comment" })

	return { lines = lines, hl_ranges = hl_ranges, sections = sections, comment_positions = comment_positions }
end

--- Build display lines for the right pane of PR overview (reviewers, assignees, labels, CI status).
--- @param pr_info table PR data from gh pr view
--- @return table { lines: string[], hl_ranges: table[], check_urls: table }
function M.build_overview_right_lines(pr_info)
	local lines = {}
	local hl_ranges = {}

	-- Reviewers
	local review_requests = pr_info.reviewRequests or {}
	local latest_reviews = pr_info.latestReviews or {}
	local reviewers = M.build_reviewers_list(review_requests, latest_reviews)

	local reviewers_header_line = #lines
	local reviewers_summary = M.build_reviewers_summary(reviewers)
	if reviewers_summary ~= "" then
		table.insert(lines, string.format("REVIEWERS (%s)", reviewers_summary))
	else
		table.insert(lines, "REVIEWERS")
	end
	table.insert(hl_ranges, { line = reviewers_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 25))

	if #reviewers == 0 then
		table.insert(lines, "(no reviewers)")
	else
		for _, reviewer in ipairs(reviewers) do
			local symbol, hl = M.format_review_status(reviewer.state)
			table.insert(lines, string.format("%s @%s  %s", symbol, reviewer.login, reviewer.state:lower()))
			table.insert(hl_ranges, { line = #lines - 1, hl = hl })
		end
	end

	-- Assignees
	local assignees = pr_info.assignees or {}
	table.insert(lines, "")
	local assignees_header_line = #lines
	table.insert(lines, "ASSIGNEES")
	table.insert(hl_ranges, { line = assignees_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 25))

	if #assignees == 0 then
		table.insert(lines, "(no assignees)")
	else
		for _, assignee in ipairs(assignees) do
			local login = assignee.login or assignee
			table.insert(lines, "@" .. login)
		end
	end

	-- Labels
	local labels = pr_info.labels or {}
	table.insert(lines, "")
	local labels_header_line = #lines
	table.insert(lines, "LABELS")
	table.insert(hl_ranges, { line = labels_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 25))

	if #labels == 0 then
		table.insert(lines, "(no labels)")
	else
		for _, label in ipairs(labels) do
			local name = label.name or label
			table.insert(lines, name)
		end
	end

	-- CI Status
	local raw_checks = pr_info.statusCheckRollup or {}
	local checks = M.sort_checks(M.deduplicate_checks(raw_checks))
	local check_urls = {}
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 25))
	local ci_header_line = #lines
	local summary = M.build_checks_summary(checks)
	if summary ~= "" then
		table.insert(lines, string.format("CI STATUS (%s)", summary))
	else
		table.insert(lines, "CI STATUS")
	end
	table.insert(hl_ranges, { line = ci_header_line, hl = "Title" })
	table.insert(lines, string.rep("-", 25))

	if #checks == 0 then
		table.insert(lines, "(no checks)")
	else
		for _, check in ipairs(checks) do
			local name = check.name or check.context or "unknown"
			local symbol, hl = M.format_check_status(check)
			local norm_status, norm_conclusion = M.normalize_check(check)
			local conclusion = norm_conclusion ~= "" and norm_conclusion or norm_status
			table.insert(lines, string.format("%s %s  %s", symbol, name, conclusion:lower()))
			table.insert(hl_ranges, { line = #lines - 1, hl = hl })
			local url = check.detailsUrl or check.targetUrl
			if url then
				check_urls[#lines - 1] = url
			end
		end
	end

	return { lines = lines, hl_ranges = hl_ranges, check_urls = check_urls }
end

--- Calculate 3-pane layout for comment browser.
--- @param columns number screen width
--- @param screen_lines number screen height
--- @param pct_w number total width percentage (0-100)
--- @param pct_h number total height percentage (0-100)
--- @param left_pct number left pane width as percentage of inner width (0-100), default 35
--- @param lower_pct number right-lower height as percentage of right height (0-100), default 25
--- @return table { left, right_upper, right_lower: { width, height, row, col } }
function M.calculate_comment_browser_layout(columns, screen_lines, pct_w, pct_h, left_pct, lower_pct)
	left_pct = left_pct or 35
	lower_pct = lower_pct or 25

	local min_left = 20
	local min_right = 25
	local min_upper = 5
	local min_lower = 5

	local total_width = math.max(math.floor(columns * pct_w / 100), min_left + min_right + 4)
	local total_height = math.max(math.floor(screen_lines * pct_h / 100), min_upper + min_lower)
	local top_row = math.floor((screen_lines - total_height) / 2)
	local start_col = math.floor((columns - total_width) / 2)

	-- 2 windows horizontally = 4 border chars total (left+right per window)
	local inner = total_width - 4
	local left_width = math.max(math.floor(inner * left_pct / 100), min_left)
	local right_width = math.max(inner - left_width, min_right)
	-- Re-clamp left if right was clamped up
	left_width = inner - right_width

	-- Vertical split of right side (3 row gap between upper and lower)
	local right_inner = total_height - 3 -- subtract gap between upper/lower
	local lower_height = math.max(math.floor(right_inner * lower_pct / 100), min_lower)
	local upper_height = math.max(right_inner - lower_height, min_upper)
	-- Re-clamp lower if upper was clamped up, but keep minimum
	lower_height = math.max(right_inner - upper_height, min_lower)

	local right_col = start_col + left_width + 2

	return {
		left = { width = left_width, height = total_height, row = top_row, col = start_col },
		right_upper = { width = right_width, height = upper_height, row = top_row, col = right_col },
		right_lower = {
			width = right_width,
			height = lower_height,
			row = top_row + upper_height + 3, -- gap between upper and lower panes
			col = right_col,
		},
	}
end

--- Format entries for the comment browser left pane.
--- Each entry occupies exactly 1 line for direct cursor-to-entry mapping.
--- @param entries table[] from build_comment_browser_entries
--- @param max_width number available character width
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comment_browser_list(entries, max_width, format_date_fn)
	local lines = {}
	local hl_ranges = {}

	for i, entry in ipairs(entries) do
		local line_idx = i - 1 -- 0-indexed for highlights
		local text
		if entry.type == "issue" then
			local date = format_date_fn(entry.last_ts)
			text = string.format("%s  PR Comment", date)
			-- Highlight "PR Comment" label
			local pr_start = #date + 2
			local pr_end = pr_start + #"PR Comment"
			table.insert(hl_ranges, { line = line_idx, col_start = pr_start, col_end = pr_end, hl = "DiagnosticInfo" })
		else
			local date = format_date_fn(entry.last_ts)
			if entry.is_pending then
				text = string.format("%s  [pending]  %s:%d", date, entry.path, entry.line)
				local pending_start = #date + 2
				local pending_end = pending_start + #"[pending]"
				table.insert(
					hl_ranges,
					{ line = line_idx, col_start = pending_start, col_end = pending_end, hl = "DiagnosticHint" }
				)
			else
				text = string.format("%s  @%s  %s:%d", date, entry.author, entry.path, entry.line)
				local author_start = #date + 2
				local author_end = author_start + 1 + #entry.author -- "@" + name
				table.insert(hl_ranges, { line = line_idx, col_start = author_start, col_end = author_end, hl = "Title" })
			end
		end

		if max_width > 0 and #text > max_width then
			text = text:sub(1, max_width - 3) .. "..."
		end
		table.insert(lines, text)
	end

	return { lines = lines, hl_ranges = hl_ranges }
end

--- Format a comment thread for the comment browser right upper pane.
--- For review comments: shows the full thread (root + replies).
--- For issue comments: shows all issue comments.
--- @param entry table a single entry from build_comment_browser_entries
--- @param all_comments table[] flat array of all review comments (for thread lookup)
--- @param all_issue_comments table[] all PR-level issue comments
--- @param format_date_fn fun(s: string): string
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comment_browser_thread(entry, all_comments, all_issue_comments, format_date_fn)
	if entry.type == "issue" then
		-- Show all issue comments as a thread
		return M.format_reply_comments_for_display(all_issue_comments or {}, format_date_fn)
	end

	-- Review comment: get the full thread
	local data = require("fude.comments.data")
	local first_comment = entry.comments[1]
	if not first_comment then
		return { lines = { "(no comments)" }, hl_ranges = {} }
	end

	local thread = data.get_comment_thread(first_comment.id, all_comments or {})
	if #thread == 0 then
		thread = entry.comments
	end

	return M.format_reply_comments_for_display(thread, format_date_fn)
end

return M
