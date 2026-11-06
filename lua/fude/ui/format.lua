local M = {}
local util = require("fude.util")

--- Normalize newlines by converting CRLF and CR to LF.
--- @param s string|nil input string
--- @return string normalized string
function M.normalize_newlines(s)
	return (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

--- Default width of the separator between comments when the caller does not
--- know the window width.
M.DEFAULT_SEPARATOR_WIDTH = 40

--- Build the separator line drawn between comments.
--- Callers pass the text width of the window showing the thread so the line
--- spans it; without a width it falls back to DEFAULT_SEPARATOR_WIDTH.
--- @param width number|nil window text width
--- @return string separator
function M.build_comment_separator(width)
	if type(width) ~= "number" then
		width = M.DEFAULT_SEPARATOR_WIDTH
	end
	return string.rep("-", math.max(1, math.floor(width)))
end

--- Format a multi-line comment range as "L20-L29".
--- @param start_line number|nil 1-indexed first line
--- @param end_line number|nil 1-indexed last line
--- @return string|nil label, nil for a single line or an invalid range
function M.format_line_range(start_line, end_line)
	if type(start_line) ~= "number" or type(end_line) ~= "number" or start_line >= end_line then
		return nil
	end
	return string.format("L%d-L%d", start_line, end_line)
end

--- Build the end-of-line marker shown on the first line of a multi-line
--- comment range while the cursor is on the comment ("↓ comment L20-L29").
--- The arrow points down because the comment is drawn on the range's last line.
--- @param start_line number 1-indexed first line
--- @param end_line number 1-indexed last line
--- @return string marker text ("" for a single line or an invalid range)
function M.build_range_start_marker(start_line, end_line)
	local range = M.format_line_range(start_line, end_line)
	if not range then
		return ""
	end
	return "↓ comment " .. range
end

--- Build status badges for a comment header (" [agent]", " [approved]", ...).
--- Local review comments carry author_type ("human"|"agent"); plain GitHub
--- comments get "". A submitted review body (`review_state`, see
--- `comments/data.build_pr_level_comments`) is badged with its state in lower
--- case, e.g. ` [changes requested]`. Resolved state is intentionally NOT
--- badged per comment: it is a thread-level flag propagated to every comment,
--- so it is shown once on the thread head (the inline border label
--- `[resolved thread]`) and in the comment viewer title, not repeated on each
--- header.
--- @param comment table comment object
--- @return string badge suffix ("" when none apply)
function M.comment_badges(comment)
	local badges = ""
	if comment.author_type == "agent" then
		badges = badges .. " [agent]"
	end
	if type(comment.review_state) == "string" and comment.review_state ~= "" then
		badges = badges .. " [" .. (comment.review_state:lower():gsub("_", " ")) .. "]"
	end
	return badges
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
--- @param separator_width number|nil width of the separator between comments (see build_comment_separator)
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comments_for_display(comments, format_date_fn, separator_width)
	local lines = {}
	local hl_ranges = {}
	local comment_ranges = {}
	for i, comment in ipairs(comments) do
		local start_line = #lines
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
		local header = string.format("@%s  %s%s", author, created, M.comment_badges(comment))
		table.insert(lines, header)
		table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })
		local comment_body = M.normalize_newlines(comment.body)
		for _, body_line in ipairs(vim.split(comment_body, "\n")) do
			table.insert(lines, body_line)
		end
		table.insert(comment_ranges, { start_line = start_line, end_line = #lines - 1, index = i })
		if i < #comments then
			table.insert(lines, "")
			table.insert(lines, M.build_comment_separator(separator_width))
			table.insert(lines, "")
		end
	end
	return { lines = lines, hl_ranges = hl_ranges, comment_ranges = comment_ranges }
end

--- Build the title for the comment viewer float.
--- Appends the resolved label when every comment shown is resolved.
--- @param comments table[] list of comment objects
--- @param resolved_opts table|nil { label: string } (see config.defaults.resolved)
--- @return string title
function M.build_comments_float_title(comments, resolved_opts)
	if util.all_comments_resolved(comments) then
		local label = (resolved_opts and resolved_opts.label) or "[resolved]"
		return string.format(" Comments (%d) %s ", #comments, label)
	end
	return string.format(" Comments (%d) ", #comments)
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

--- Mark of a review that commented: the Nerd Font octicon comment glyph
--- (`nf-oct-comment`), one cell wide like the other status marks, unlike the
--- two-cell 💬 emoji, which pushed its name out of line.
M.COMMENTED_MARK = ""

--- Map review state to display symbol and highlight group.
--- @param state string review state ("APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING")
--- @return string symbol, string hl_group
function M.format_review_status(state)
	if state == "APPROVED" then
		return "✓", "DiagnosticOk"
	elseif state == "CHANGES_REQUESTED" then
		return "✗", "DiagnosticError"
	elseif state == "COMMENTED" then
		return M.COMMENTED_MARK, "DiagnosticInfo"
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
		-- author can be JSON null, which decodes to truthy vim.NIL
		local author = type(review.author) == "table" and review.author or nil
		local login = author and author.login
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

--- GitHub's Copilot code reviewer. The GraphQL side (`gh pr view`'s
--- reviewRequests and latestReviews) names it by its bare login, the REST
--- side (`requested_reviewers`) by the `[bot]` form; the pickers show it as
--- `@copilot`, as the GitHub UI does. Unlike other bots it can be requested,
--- so it is exempt from the bot / non-collaborator exclusions below and is
--- always offered, since nothing tells in advance whether Copilot code
--- review is enabled for the repository (GitHub refuses the request if not).
M.COPILOT_REVIEWER = {
	login = "copilot-pull-request-reviewer",
	api_login = "copilot-pull-request-reviewer[bot]",
	display = "copilot",
}

--- Whether a reviewer login (GraphQL or REST form) is Copilot.
--- @param login any
--- @return boolean
function M.is_copilot_login(login)
	return login == M.COPILOT_REVIEWER.login or login == M.COPILOT_REVIEWER.api_login
end

--- The login the REST API wants for a reviewer: Copilot's `[bot]` form, else
--- the login as given.
--- @param login string
--- @return string
local function api_login(login)
	if M.is_copilot_login(login) then
		return M.COPILOT_REVIEWER.api_login
	end
	return login
end

--- The name a reviewer is shown under (`@copilot` for Copilot).
--- @param login string
--- @return string
function M.reviewer_display_name(login)
	if M.is_copilot_login(login) then
		return M.COPILOT_REVIEWER.display
	end
	return login
end

--- Build candidates for review re-request: users who already submitted a review,
--- excluding users with a pending re-request, unsubmitted (PENDING) reviews,
--- the PR author, bots other than Copilot, and non-collaborators (the API only
--- accepts re-requests for repository collaborators, and Copilot).
--- @param review_requests table[] reviewRequests from gh pr view (each has login)
--- @param latest_reviews table[] latestReviews from gh pr view (each has author.login, authorAssociation, state)
--- @param author_login string|nil PR author login (re-requesting from the author is rejected by the API)
--- @return table[] list of { login: string, state: string } sorted by login; `login` is what the API
---   takes (Copilot's `[bot]` form), shown through `reviewer_display_name`
function M.build_re_request_candidates(review_requests, latest_reviews, author_login)
	local requested = {}
	for _, req in ipairs(review_requests) do
		-- Team review requests have no login; re-requesting teams is out of scope
		if req.login then
			requested[api_login(req.login)] = true
		end
	end

	local candidates = {}
	local seen = {}
	for _, review in ipairs(latest_reviews) do
		-- author can be JSON null, which decodes to truthy vim.NIL
		local author = type(review.author) == "table" and review.author or nil
		local login = author and author.login
		local copilot = M.is_copilot_login(login)
		local is_bot = author and author.is_bot and not copilot
		-- PENDING means the review has not been submitted yet; only
		-- submitted reviews qualify for a re-request
		local state = review.state or "COMMENTED"
		local submitted = state ~= "PENDING"
		-- The API only accepts re-requests for collaborators (and Copilot);
		-- gh's latestReviews.author does not export is_bot, so
		-- authorAssociation is the practical signal for other bots.
		-- A missing/non-string association is kept so an unexpected gh
		-- output change degrades to the API's own 422 instead of silently
		-- emptying the candidate list.
		local association = review.authorAssociation
		local non_collaborator = not copilot
			and type(association) == "string"
			and association ~= "OWNER"
			and association ~= "MEMBER"
			and association ~= "COLLABORATOR"
		if login then
			login = api_login(login)
		end
		if
			login
			and submitted
			and not non_collaborator
			and not seen[login]
			and not requested[login]
			and login ~= author_login
			and not is_bot
		then
			seen[login] = true
			table.insert(candidates, { login = login, state = state })
		end
	end

	table.sort(candidates, function(a, b)
		return M.reviewer_display_name(a.login) < M.reviewer_display_name(b.login)
	end)

	return candidates
end

--- Sort entries in place by a string field, case-insensitively, with the
--- original string as the tie-break so the order is total.
--- @param entries table[]
--- @param field string
local function sort_by_name(entries, field)
	table.sort(entries, function(a, b)
		local la, lb = a[field]:lower(), b[field]:lower()
		if la ~= lb then
			return la < lb
		end
		return a[field] < b[field]
	end)
end

--- Sort rank of a reviewer picker row: approved, changes requested,
--- commented, dismissed, requested (review in progress), then everyone else.
local REVIEWER_RANK = { APPROVED = 1, CHANGES_REQUESTED = 2, COMMENTED = 3, DISMISSED = 4 }
local REQUESTED_RANK = 5
local OTHER_RANK = 6

--- @param entry table { requested, review_state }
--- @return number
local function reviewer_rank(entry)
	if entry.requested then
		return REQUESTED_RANK
	end
	return REVIEWER_RANK[entry.review_state] or OTHER_RANK
end

--- Build the entries of the overview's reviewer picker: repository
--- collaborators with write access, users with a pending review request,
--- collaborators who already reviewed, and always Copilot (see
--- COPILOT_REVIEWER). The PR author (GitHub rejects requesting the author),
--- other bots, teams (no login) and collaborators without write access are
--- left out; a user with a pending request is always kept, so the request
--- can be removed. Rows are ordered approved, changes requested, commented,
--- dismissed, requested, then the rest, each group sorted by the name shown.
--- @param collaborators table[] `repos/{owner}/{repo}/collaborators` items ({ login, type, permissions });
---   empty when listing failed
--- @param review_requests table[] reviewRequests from gh pr view (users have login, teams do not)
--- @param latest_reviews table[] latestReviews from gh pr view (author.login, authorAssociation, state)
--- @param author_login string|nil PR author login
--- @return table[] list of { login: string, requested: boolean, review_state: string|nil }; `login` is
---   what the API takes (Copilot's `[bot]` form), shown through `reviewer_display_name`
function M.build_reviewer_entries(collaborators, review_requests, latest_reviews, author_login)
	-- GitHub accepts review requests only from users with write access.
	-- Indexed first so a read-only member is excluded whichever list names
	-- them; `permissions` absent is kept, so an unexpected response shape
	-- degrades to the API's own 422 instead of an empty list.
	local read_only = {}
	for _, user in ipairs(collaborators or {}) do
		local permissions = type(user) == "table" and type(user.permissions) == "table" and user.permissions or nil
		if permissions and permissions.push == false and type(user.login) == "string" then
			read_only[user.login] = true
		end
	end

	local by_login = {}
	local entries = {}
	local function add(login, requested)
		if type(login) ~= "string" or login == "" or login == author_login then
			return nil
		end
		login = api_login(login)
		if read_only[login] and not requested and not by_login[login] then
			return nil
		end
		if not by_login[login] then
			by_login[login] = { login = login, requested = false }
			table.insert(entries, by_login[login])
		end
		return by_login[login]
	end

	for _, req in ipairs(review_requests or {}) do
		local entry = type(req) == "table" and add(req.login, true) or nil
		if entry then
			entry.requested = true
		end
	end

	for _, review in ipairs(latest_reviews or {}) do
		-- review and author can be JSON null, which decodes to truthy vim.NIL
		local author = type(review) == "table" and type(review.author) == "table" and review.author or nil
		if author then
			-- Same rule as build_re_request_candidates: requesting a
			-- non-collaborator is rejected by the API, Copilot excepted.
			local copilot = M.is_copilot_login(author.login)
			local association = review.authorAssociation
			local non_collaborator = not copilot
				and type(association) == "string"
				and association ~= "OWNER"
				and association ~= "MEMBER"
				and association ~= "COLLABORATOR"
			local state = type(review.state) == "string" and review.state or "COMMENTED"
			if (copilot or not author.is_bot) and not non_collaborator and state ~= "PENDING" then
				local entry = add(author.login)
				if entry then
					entry.review_state = state
				end
			end
		end
	end

	for _, user in ipairs(collaborators or {}) do
		if type(user) == "table" and user.type ~= "Bot" then
			add(user.login)
		end
	end
	-- Copilot is offered whether or not it has been involved yet
	add(M.COPILOT_REVIEWER.api_login)

	table.sort(entries, function(a, b)
		local ra, rb = reviewer_rank(a), reviewer_rank(b)
		if ra ~= rb then
			return ra < rb
		end
		local na, nb = M.reviewer_display_name(a.login), M.reviewer_display_name(b.login)
		local la, lb = na:lower(), nb:lower()
		if la ~= lb then
			return la < lb
		end
		return na < nb
	end)
	return entries
end

--- Format a review state enum for display (`CHANGES_REQUESTED` →
--- `changes requested`).
--- @param state string
--- @return string
function M.format_review_state_label(state)
	return (state:lower():gsub("_", " "))
end

--- Describe a reviewer picker row: whether a review is requested now and
--- the state of the user's latest review, kept apart so a requested user
--- whose last review was dismissed does not read as "dismissed" only.
--- @param requested boolean
--- @param review_state string|nil latest review state (APPROVED, DISMISSED, ...)
--- @return string|nil nil when there is nothing to say
function M.format_reviewer_detail(requested, review_state)
	local parts = {}
	if requested then
		table.insert(parts, "review requested")
	end
	if type(review_state) == "string" and review_state ~= "" then
		table.insert(parts, "last review: " .. M.format_review_state_label(review_state))
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ", ")
end

--- Build the entries of the overview's label picker: every repository label,
--- applied ones first, each group sorted by name. A label on the PR that the
--- repository listing lacks is still shown, so it can be removed.
--- @param repo_labels table[] `repos/{owner}/{repo}/labels` items ({ name, description })
--- @param pr_labels table[] labels from gh pr view ({ name, description })
--- @return table[] list of { name: string, description: string|nil, applied: boolean }
function M.build_label_entries(repo_labels, pr_labels)
	local by_name = {}
	local entries = {}
	local function add(label)
		if type(label) ~= "table" or type(label.name) ~= "string" or label.name == "" then
			return nil
		end
		if not by_name[label.name] then
			local description = type(label.description) == "string" and label.description ~= "" and label.description or nil
			by_name[label.name] = { name = label.name, description = description, applied = false }
			table.insert(entries, by_name[label.name])
		end
		return by_name[label.name]
	end

	for _, label in ipairs(repo_labels or {}) do
		add(label)
	end
	for _, label in ipairs(pr_labels or {}) do
		local entry = add(label)
		if entry then
			entry.applied = true
		end
	end

	local applied, others = {}, {}
	for _, entry in ipairs(entries) do
		table.insert(entry.applied and applied or others, entry)
	end
	sort_by_name(applied, "name")
	sort_by_name(others, "name")
	return vim.list_extend(applied, others)
end

--- Mark and highlight group for a toggle picker row.
--- @param on boolean whether the item is applied (label) / requested (reviewer)
--- @return string mark, string hl_group
function M.format_toggle_mark(on)
	if on then
		return "●", "DiagnosticOk"
	end
	return "○", "Comment"
end

--- Mark and highlight groups for a reviewer picker row, following the
--- GitHub web UI: a pending request (review in progress) wins over the
--- user's previous review, since it is what the reviewer owes now. The
--- name is grey for a user with no pending request, so the requested users
--- stand out, except an approval (green name) and a dismissed review
--- (normal name).
--- @param requested boolean
--- @param review_state string|nil latest review state (APPROVED, DISMISSED, ...)
--- @return string mark, string mark_hl, string|nil text_hl highlight for the name
function M.format_reviewer_mark(requested, review_state)
	if requested then
		return "●", "DiagnosticWarn", nil
	elseif review_state == "APPROVED" then
		return "✓", "DiagnosticOk", "DiagnosticOk"
	elseif review_state == "CHANGES_REQUESTED" then
		return "✗", "DiagnosticError", "Comment"
	elseif review_state == "COMMENTED" then
		return M.COMMENTED_MARK, "DiagnosticInfo", "Comment"
	elseif review_state == "DISMISSED" then
		return "↻", "Comment", nil
	end
	return "○", "Comment", "Comment"
end

--- Format one toggle picker row as plain text (`● name  (detail)`), used by
--- vim.ui.select and as the display text of Telescope.
--- @param text string item name
--- @param mark string row mark (from format_toggle_mark / format_reviewer_mark)
--- @param detail string|nil extra information shown in parentheses
--- @return string
function M.format_toggle_entry(text, mark, detail)
	local line = mark .. " " .. text
	if detail and detail ~= "" then
		line = line .. "  (" .. detail .. ")"
	end
	return line
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

--- Lines that put one line of text in the middle of a `width` x `height`
--- window, left / right and top / bottom (blank lines above, spaces before).
--- @param text string
--- @param text_width number display width of `text` (the caller measures it)
--- @param width number window width
--- @param height number window height
--- @return string[] lines
--- @return number row 0-based line of the text
--- @return number col byte column where the text starts
function M.build_centered_lines(text, text_width, width, height)
	local row = math.max(0, math.floor((height - 1) / 2))
	local col = math.max(0, math.floor((width - text_width) / 2))
	local lines = {}
	for _ = 1, row do
		table.insert(lines, "")
	end
	table.insert(lines, string.rep(" ", col) .. text)
	return lines, row, col
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
--- @param separator_width number|nil width of the separator between comments (see build_comment_separator)
--- @return table { lines: string[], hl_ranges: table[], comment_ranges: table[] }
---   comment_ranges: { start_line, end_line (0-indexed, header to last body line), index }
function M.format_reply_comments_for_display(comments, format_date_fn, separator_width)
	local lines = {}
	local hl_ranges = {}
	local comment_ranges = {}
	for i, comment in ipairs(comments) do
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
		local header = string.format("@%s (%s):%s", author, created, M.comment_badges(comment))
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

		local comment_body = M.normalize_newlines(comment.body)
		for _, body_line in ipairs(vim.split(comment_body, "\n")) do
			table.insert(lines, body_line)
		end
		table.insert(comment_ranges, { start_line = header_line_idx, end_line = #lines - 1, index = i })

		if i < #comments then
			table.insert(lines, "")
			table.insert(lines, M.build_comment_separator(separator_width))
			table.insert(lines, "")
		end
	end
	return { lines = lines, hl_ranges = hl_ranges, comment_ranges = comment_ranges }
end

--- Find the comment shown on a buffer line from the `comment_ranges` the
--- format functions return. Lines outside every range (separators, headings,
--- footers) belong to no comment. Pure.
--- @param comment_ranges table[]|nil { start_line, end_line, index }, 0-indexed lines
--- @param line number 0-indexed buffer line
--- @return number|nil index into the formatted comment list
function M.find_comment_index_at_line(comment_ranges, line)
	for _, range in ipairs(comment_ranges or {}) do
		if line >= range.start_line and line <= range.end_line then
			return range.index
		end
	end
	return nil
end

--- Build display lines for the left pane of PR overview (header, description, comments).
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- `issue_comments` nil means they are still being fetched: the COMMENTS
--- section then holds a spinner row (`opts.loading_mark` highlighted
--- `opts.loading_hl`, then COMMENTS_LOADING_TEXT) at `loading_row`. The section
--- starts at `comments_start` (0-indexed, its blank separator line) and runs to
--- the end of the pane with the footer, so it can be rebuilt in place.
--- @param format_date_fn fun(s: string): string
--- @param opts { loading_mark: string|nil, loading_hl: string|nil }|nil
--- @return table { lines: string[], hl_ranges: table[], sections: table, comment_positions: number[],
---   comment_ranges: table[], comments_start: number, loading_row: number|nil } comment_positions are
---   1-indexed header lines; comment_ranges ({ start_line, end_line, index } into issue_comments) are
---   0-indexed like the other format functions
function M.build_overview_left_lines(pr_info, issue_comments, format_date_fn, opts)
	opts = opts or {}
	local lines = {}
	local hl_ranges = {}
	local sections = {}
	local comment_positions = {}
	local comment_ranges = {}

	-- author can be JSON null, which decodes to truthy vim.NIL
	local author = type(pr_info.author) == "table" and pr_info.author.login or nil
	if type(author) ~= "string" then
		author = "unknown"
	end
	-- state can be JSON null (truthy vim.NIL), which would break the concatenation
	local state = type(pr_info.state) == "string" and pr_info.state or "UNKNOWN"
	-- Same rule as pr.format_pr_state: a closed draft is reported as closed
	if pr_info.isDraft == true and state == "OPEN" then
		state = state .. " (draft)"
	end
	-- JSON-quoted strings are also valid YAML double-quoted scalars. Never
	-- interpolate raw metadata: ':' / '#' / newlines could change its structure.
	table.insert(lines, "---")
	local function add_string(key, value)
		-- Neovim 0.10 escapes slashes; YAML does not need that escape.
		local quoted = vim.json.encode(type(value) == "string" and value or ""):gsub("(\\+)/", function(escapes)
			-- An even run encodes literal backslashes; only an odd run also
			-- escapes the slash. Preserve the literal backslashes in either case.
			if #escapes % 2 == 1 then
				escapes = escapes:sub(2)
			end
			return escapes .. "/"
		end)
		table.insert(lines, key .. ": " .. quoted)
	end
	add_string("state", state)
	add_string("author", "@" .. author)
	-- Where ui/avatars draws the author's avatar: between `author: ` and
	-- the quoted login (0-indexed line, byte column)
	local avatar_positions = {}
	if author ~= "unknown" then
		table.insert(avatar_positions, { line = #lines - 1, col = #"author: ", login = author })
	end
	add_string("base", pr_info.baseRefName)
	add_string("head", pr_info.headRefName)
	add_string("url", pr_info.url)
	local function count_text(value)
		-- Missing counts mean unknown, not zero.
		if type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value) then
			return string.format("%.0f", value)
		end
	end
	local function highlight_count(start_col, text, group)
		table.insert(hl_ranges, {
			line = #lines - 1,
			col_start = start_col,
			col_end = start_col + #text,
			hl = group,
		})
	end
	local files = count_text(pr_info.changedFiles)
	if files then
		local prefix = "file_changed: "
		table.insert(lines, prefix .. files)
		highlight_count(#prefix, files, "ReviewFileCount")
	end
	local additions, deletions = count_text(pr_info.additions), count_text(pr_info.deletions)
	if additions and deletions then
		local prefix = "line_changed: "
		local added, deleted = "+" .. additions, "-" .. deletions
		table.insert(lines, prefix .. '"' .. added .. " " .. deleted .. '"')
		highlight_count(#prefix + 1, added, "DiagnosticOk")
		highlight_count(#prefix + #added + 2, deleted, "DiagnosticError")
		highlight_count(#prefix, '"', "Normal")
		highlight_count(#prefix + #added + 1, " ", "Normal")
		highlight_count(#prefix + #added + #deleted + 2, '"', "Normal")
	end
	table.insert(lines, "---")
	table.insert(lines, "")
	table.insert(lines, string.format("# #%d %s", pr_info.number or 0, pr_info.title or ""))

	-- Description
	table.insert(lines, "")
	sections.description = #lines + 1 -- 1-indexed first body line

	local body = M.normalize_newlines(pr_info.body)
	if body == "" then
		table.insert(lines, "(no description)")
	else
		for _, body_line in ipairs(vim.split(body, "\n")) do
			table.insert(lines, body_line)
		end
	end

	-- Comments: the section runs to the end of the pane (with the footer),
	-- so it can be rebuilt in place (from comments_start) once they arrive.
	local comments_start = #lines
	local loading_row
	table.insert(lines, "")
	if type(issue_comments) ~= "table" then
		table.insert(lines, "## COMMENTS")
		sections.comments = #lines -- 1-indexed
		local mark = opts.loading_mark or ""
		table.insert(lines, mark ~= "" and (mark .. " " .. M.COMMENTS_LOADING_TEXT) or M.COMMENTS_LOADING_TEXT)
		loading_row = #lines - 1
		if mark ~= "" then
			table.insert(hl_ranges, { line = loading_row, col_start = 0, col_end = #mark, hl = opts.loading_hl or "Comment" })
		end
		table.insert(hl_ranges, { line = loading_row, col_start = mark ~= "" and #mark or 0, hl = "Comment" })
	else
		table.insert(lines, string.format("## COMMENTS (%d)", #issue_comments))
		sections.comments = #lines -- 1-indexed
	end

	-- Nothing under the heading but the spinner row while they are fetched
	if loading_row then
		issue_comments = {}
	elseif #issue_comments == 0 then
		table.insert(lines, "(no comments)")
	end
	if #issue_comments > 0 then
		for i, comment in ipairs(issue_comments) do
			local comment_author = comment.user and comment.user.login or "unknown"
			local created = format_date_fn(comment.created_at)
			table.insert(lines, "")
			local header = string.format("### @%s  %s%s", comment_author, created, M.comment_badges(comment))
			table.insert(lines, header)
			table.insert(comment_positions, #lines) -- 1-indexed header line
			table.insert(hl_ranges, { line = #lines - 1, hl = "Special" })
			local start_line = #lines - 1
			local comment_body = M.normalize_newlines(comment.body)
			for _, body_line in ipairs(vim.split(comment_body, "\n")) do
				table.insert(lines, body_line)
			end
			table.insert(comment_ranges, { start_line = start_line, end_line = #lines - 1, index = i })
		end
	end

	-- Footer
	table.insert(lines, "")
	table.insert(
		lines,
		" ]s/[s: sections  ]c/[c: comments  o: open  C: comment/reviewer/label  r: re-request  za: fold"
			.. "  R: refresh  <Tab>: switch  q: close"
	)
	table.insert(hl_ranges, { line = #lines - 1, hl = "Comment" })

	return {
		lines = lines,
		hl_ranges = hl_ranges,
		sections = sections,
		comment_positions = comment_positions,
		comment_ranges = comment_ranges,
		avatar_positions = avatar_positions,
		comments_start = comments_start,
		loading_row = loading_row,
	}
end

--- Text of the COMMENTS row shown while the PR-level comments are being fetched.
M.COMMENTS_LOADING_TEXT = "Loading comments…"
--- Text of the REVIEWERS row shown while the reviewers are being fetched.
M.REVIEWERS_LOADING_TEXT = "Loading reviewers…"
--- Text of the REVIEWERS row when the reviewers could not be fetched.
M.REVIEWERS_FAILED_TEXT = "(could not load reviewers)"

--- Build display lines for the right pane of PR overview (reviewers, assignees, labels, CI status).
--- `avatar_positions` (`{ line, col, login }`, 0-indexed line, byte column) is
--- where ui/avatars draws each reviewer's avatar: after the status symbol.
--- The CI STATUS section comes last and starts at `ci_start` (0-indexed, its
--- blank separator line); `pr_info.statusCheckRollup` nil means the checks are
--- still being fetched (see build_overview_ci_lines for `opts`).
--- `pr_info.reviewers_loading` means the reviewers are still being fetched:
--- REVIEWERS then holds a spinner row (`opts.loading_mark`) at
--- `reviewers_loading_row`; `pr_info.reviewers_failed` shows
--- REVIEWERS_FAILED_TEXT instead.
--- @param pr_info table PR data from gh pr view
--- @param opts table|nil passed to build_overview_ci_lines
--- @return table { lines: string[], hl_ranges: table[], check_urls: table, avatar_positions: table[],
---   ci_start: number, loading_row: number|nil, reviewers_loading_row: number|nil }
function M.build_overview_right_lines(pr_info, opts)
	opts = opts or {}
	local lines = {}
	local hl_ranges = {}
	local avatar_positions = {}
	local reviewers_loading_row

	-- Reviewers: a spinner row while they are being fetched
	if pr_info.reviewers_failed then
		table.insert(lines, "## REVIEWERS")
		table.insert(lines, M.REVIEWERS_FAILED_TEXT)
		table.insert(hl_ranges, { line = #lines - 1, hl = "Comment" })
	elseif pr_info.reviewers_loading then
		table.insert(lines, "## REVIEWERS")
		local mark = opts.loading_mark or ""
		table.insert(lines, mark ~= "" and (mark .. " " .. M.REVIEWERS_LOADING_TEXT) or M.REVIEWERS_LOADING_TEXT)
		reviewers_loading_row = #lines - 1
		if mark ~= "" then
			table.insert(
				hl_ranges,
				{ line = reviewers_loading_row, col_start = 0, col_end = #mark, hl = opts.loading_hl or "Comment" }
			)
		end
		table.insert(hl_ranges, { line = reviewers_loading_row, col_start = mark ~= "" and #mark or 0, hl = "Comment" })
	else
		local reviewers = M.build_reviewers_list(pr_info.reviewRequests or {}, pr_info.latestReviews or {})
		local reviewers_summary = M.build_reviewers_summary(reviewers)
		if reviewers_summary ~= "" then
			table.insert(lines, string.format("## REVIEWERS (%s)", reviewers_summary))
		else
			table.insert(lines, "## REVIEWERS")
		end
		if #reviewers == 0 then
			table.insert(lines, "(no reviewers)")
		else
			for _, reviewer in ipairs(reviewers) do
				local symbol, hl = M.format_review_status(reviewer.state)
				table.insert(lines, string.format("%s @%s  %s", symbol, reviewer.login, reviewer.state:lower()))
				table.insert(hl_ranges, { line = #lines - 1, hl = hl })
				table.insert(avatar_positions, { line = #lines - 1, col = #symbol + 1, login = reviewer.login })
			end
		end
	end

	-- Assignees
	local assignees = pr_info.assignees or {}
	table.insert(lines, "")
	table.insert(lines, "## ASSIGNEES")

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
	table.insert(lines, "## LABELS")

	if #labels == 0 then
		table.insert(lines, "(no labels)")
	else
		for _, label in ipairs(labels) do
			local name = label.name or label
			table.insert(lines, name)
		end
	end

	-- CI Status: the section runs to the end of the pane, so it can be
	-- rebuilt in place (from ci_start) once the checks arrive.
	local ci_start = #lines
	local ci = M.build_overview_ci_lines(pr_info.statusCheckRollup, ci_start, opts)
	vim.list_extend(lines, ci.lines)
	vim.list_extend(hl_ranges, ci.hl_ranges)

	return {
		lines = lines,
		hl_ranges = hl_ranges,
		check_urls = ci.check_urls,
		avatar_positions = avatar_positions,
		ci_start = ci_start,
		loading_row = ci.loading_row,
		reviewers_loading_row = reviewers_loading_row,
	}
end

--- Text of the CI STATUS row shown while the checks are still being fetched.
M.CHECKS_LOADING_TEXT = "Loading checks…"
--- Text of the CI STATUS row when the checks could not be fetched.
M.CHECKS_FAILED_TEXT = "(could not load checks)"

--- Build the CI STATUS section of the overview's right pane: a blank line,
--- the `## CI STATUS (summary)` heading, and a row per check. `checks` nil
--- means they are still being fetched (a spinner row: `opts.loading_mark`,
--- highlighted `opts.loading_hl`, then CHECKS_LOADING_TEXT), and
--- `opts.checks_failed` that fetching them failed. Line numbers in
--- `hl_ranges` / `check_urls` are absolute: the section starts at `start_line`
--- (0-indexed). `loading_row` is the absolute line of the spinner row, nil
--- when there is none.
--- @param checks table[]|nil statusCheckRollup, nil while loading
--- @param start_line number 0-indexed line the section starts at
--- @param opts { loading_mark: string|nil, loading_hl: string|nil, checks_failed: boolean|nil }|nil
--- @return table { lines: string[], hl_ranges: table[], check_urls: table<number, string>, loading_row: number|nil }
function M.build_overview_ci_lines(checks, start_line, opts)
	opts = opts or {}
	local lines = { "" }
	local hl_ranges = {}
	local check_urls = {}
	local loading_row
	local function add(line)
		table.insert(lines, line)
		return start_line + #lines - 1
	end

	if type(checks) ~= "table" then
		add("## CI STATUS")
		if opts.checks_failed then
			local row = add(M.CHECKS_FAILED_TEXT)
			table.insert(hl_ranges, { line = row, hl = "Comment" })
		else
			local mark = opts.loading_mark or ""
			local text = mark ~= "" and (mark .. " " .. M.CHECKS_LOADING_TEXT) or M.CHECKS_LOADING_TEXT
			loading_row = add(text)
			if mark ~= "" then
				table.insert(
					hl_ranges,
					{ line = loading_row, col_start = 0, col_end = #mark, hl = opts.loading_hl or "Comment" }
				)
			end
			table.insert(hl_ranges, { line = loading_row, col_start = mark ~= "" and #mark or 0, hl = "Comment" })
		end
		return { lines = lines, hl_ranges = hl_ranges, check_urls = check_urls, loading_row = loading_row }
	end

	local sorted = M.sort_checks(M.deduplicate_checks(checks))
	local summary = M.build_checks_summary(sorted)
	add(summary ~= "" and string.format("## CI STATUS (%s)", summary) or "## CI STATUS")
	if #sorted == 0 then
		add("(no checks)")
	else
		for _, check in ipairs(sorted) do
			local name = check.name or check.context or "unknown"
			local symbol, hl = M.format_check_status(check)
			local norm_status, norm_conclusion = M.normalize_check(check)
			local conclusion = norm_conclusion ~= "" and norm_conclusion or norm_status
			local row = add(string.format("%s %s  %s", symbol, name, conclusion:lower()))
			table.insert(hl_ranges, { line = row, hl = hl })
			local url = check.detailsUrl or check.targetUrl
			if url then
				check_urls[row] = url
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

	-- Vertical split of right side (2 row gap = upper bottom border + lower top border, no blank line)
	local right_inner = total_height - 2 -- subtract border lines between upper/lower
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
			row = top_row + upper_height + 2, -- upper bottom border + lower top border, no blank line
			col = right_col,
		},
	}
end

--- Format entries for the comment browser left pane.
--- Each entry occupies exactly 1 line for direct cursor-to-entry mapping.
--- @param entries table[] from build_comment_browser_entries
--- @param format_date_fn fun(s: string): string
--- @param outdated_opts table|nil { show: boolean, label: string, hl_group: string }
--- @param format_path_fn fun(s: string): string|nil formats repo-relative path for display (nil = identity)
--- @param resolved_opts table|nil { label: string, hl_group: string } for the trailing resolved marker
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comment_browser_list(entries, format_date_fn, outdated_opts, format_path_fn, resolved_opts)
	local lines = {}
	local hl_ranges = {}

	format_path_fn = format_path_fn or function(p)
		return p
	end

	-- Default outdated options (show by default when outdated_opts is nil)
	local outdated_show = outdated_opts == nil or outdated_opts.show ~= false
	local outdated_label = (outdated_opts and outdated_opts.label) or "[outdated]"
	local outdated_hl = (outdated_opts and outdated_opts.hl_group) or "Comment"
	local resolved_label = (resolved_opts and resolved_opts.label) or "[resolved]"
	local resolved_hl = (resolved_opts and resolved_opts.hl_group) or "DiagnosticOk"

	for i, entry in ipairs(entries) do
		local line_idx = i - 1 -- 0-indexed for highlights
		local text
		if entry.type == "draft" then
			-- Local (unsubmitted) draft with no GitHub counterpart.
			local date = format_date_fn(entry.last_ts)
			if entry.kind == "issue" then
				text = string.format("%s  [draft]  PR Comment", date)
			else
				local raw = type(entry.path) == "string" and format_path_fn(entry.path) or nil
				local display_path = (type(raw) == "string") and raw or entry.path or "(unknown)"
				local line_num = type(entry.line) == "number" and entry.line or nil
				if line_num then
					text = string.format("%s  [draft]  %s:%d", date, display_path, line_num)
				else
					text = string.format("%s  [draft]  %s", date, display_path)
				end
			end
			local draft_start = #date + 2
			table.insert(
				hl_ranges,
				{ line = line_idx, col_start = draft_start, col_end = draft_start + #"[draft]", hl = "DiagnosticWarn" }
			)
		elseif entry.type == "issue" then
			local date = format_date_fn(entry.last_ts)
			text = string.format("%s  PR Comment", date)
			-- Highlight "PR Comment" label
			local pr_start = #date + 2
			local pr_end = pr_start + #"PR Comment"
			table.insert(hl_ranges, { line = line_idx, col_start = pr_start, col_end = pr_end, hl = "DiagnosticInfo" })
		else
			local date = format_date_fn(entry.last_ts)
			local raw
			if type(entry.path) == "string" then
				raw = format_path_fn(entry.path)
			end
			local display_path = (entry.path and type(raw) == "string") and raw or entry.path
			local range = M.format_line_range(entry.start_line, entry.line)
			if entry.is_pending then
				-- pending かつ outdated なエントリでは path/line が nil になり得るためガードする
				local line_num = type(entry.line) == "number" and entry.line or nil
				if line_num and display_path then
					text = string.format("%s  [pending]  %s:%s", date, display_path, range or line_num)
				elseif display_path then
					text = string.format("%s  [pending]  %s", date, display_path)
				else
					text = string.format("%s  [pending]  (unknown)", date)
				end
				local pending_start = #date + 2
				local pending_end = pending_start + #"[pending]"
				table.insert(
					hl_ranges,
					{ line = line_idx, col_start = pending_start, col_end = pending_end, hl = "DiagnosticHint" }
				)
			elseif entry.is_outdated and outdated_show then
				-- Outdated comments may have nil/vim.NIL line or path
				local line_num = type(entry.line) == "number" and entry.line or nil
				if line_num and display_path then
					text = string.format("%s  %s  %s:%s", date, outdated_label, display_path, range or line_num)
				else
					text = string.format("%s  %s  %s", date, outdated_label, display_path or "(unknown)")
				end
				local outdated_start = #date + 2
				local outdated_end = outdated_start + #outdated_label
				table.insert(
					hl_ranges,
					{ line = line_idx, col_start = outdated_start, col_end = outdated_end, hl = outdated_hl }
				)
			elseif entry.is_outdated then
				-- outdated_show = false: show as normal entry without label
				local line_num = type(entry.line) == "number" and entry.line or nil
				if line_num and display_path then
					text = string.format("%s  @%s  %s:%s", date, entry.author or "unknown", display_path, range or line_num)
				else
					text = string.format("%s  @%s  %s", date, entry.author or "unknown", display_path or "(unknown)")
				end
				local author_start = #date + 2
				local author_end = author_start + 1 + #(entry.author or "unknown")
				table.insert(hl_ranges, { line = line_idx, col_start = author_start, col_end = author_end, hl = "Title" })
			else
				text = string.format("%s  @%s  %s:%s", date, entry.author, display_path, range or entry.line)
				local author_start = #date + 2
				local author_end = author_start + 1 + #entry.author -- "@" + name
				table.insert(hl_ranges, { line = line_idx, col_start = author_start, col_end = author_end, hl = "Title" })
			end
		end

		-- Mark resolved threads with a trailing label so it composes with the
		-- pending/outdated variants above (a thread can be outdated and resolved).
		if entry.type ~= "draft" and entry.type ~= "issue" and entry.is_resolved then
			local col = #text
			text = text .. "  " .. resolved_label
			table.insert(hl_ranges, { line = line_idx, col_start = col, col_end = #text, hl = resolved_hl })
		end

		-- Mark existing entries that also have an unsubmitted local draft.
		if entry.type ~= "draft" and entry.has_draft then
			local col = #text
			text = text .. "  ✎draft"
			table.insert(hl_ranges, { line = line_idx, col_start = col, col_end = #text, hl = "DiagnosticWarn" })
		end

		table.insert(lines, text)
	end

	return { lines = lines, hl_ranges = hl_ranges }
end

--- Format a comment thread for the comment browser right upper pane.
--- For review comments: shows the full thread (root + replies).
--- For issue comments: shows all issue comments.
--- @param entry table a single entry from build_comment_browser_entries
--- @param _all_comments table[] unused; kept for call compatibility
--- @param all_issue_comments table[] all PR-level issue comments
--- @param format_date_fn fun(s: string): string
--- @param separator_width number|nil width of the separator between comments (see build_comment_separator)
--- @return table { lines: string[], hl_ranges: table[] }
function M.format_comment_browser_thread(entry, _all_comments, all_issue_comments, format_date_fn, separator_width)
	if entry.type == "draft" then
		-- Unsubmitted local draft: show its body as a preview.
		local lines = { "Local draft (not yet submitted)", "" }
		for _, l in ipairs(vim.split(M.normalize_newlines(entry.body or ""), "\n")) do
			table.insert(lines, l)
		end
		return { lines = lines, hl_ranges = { { line = 0, col_start = 0, col_end = -1, hl = "DiagnosticWarn" } } }
	end

	if entry.type == "issue" then
		-- Show all issue comments as a thread
		return M.format_reply_comments_for_display(all_issue_comments or {}, format_date_fn, separator_width)
	end

	-- Review comment: entries contain the full selected thread.
	local first_comment = entry.comments[1]
	if not first_comment then
		return { lines = { "(no comments)" }, hl_ranges = {} }
	end

	-- Browser entries already contain exactly one complete thread, including
	-- sibling replies whose root was deleted. Do not narrow it to the first reply.
	return M.format_reply_comments_for_display(entry.comments, format_date_fn, separator_width)
end

--- Parse a single line for Markdown inline elements using tree-sitter.
--- Returns segments describing highlighted regions.
--- @param line string input line
--- @return table[] segments { { start_col, end_col, hl_type } } or nil if parser unavailable
function M.parse_markdown_line(line)
	if not line or line == "" then
		return nil
	end

	-- Try to get the markdown_inline parser
	local ok, parser = pcall(vim.treesitter.get_string_parser, line, "markdown_inline")
	if not ok or not parser then
		return nil
	end

	local segments = {}
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local root = tree:root()

	--- Recursively collect highlight segments from tree-sitter nodes
	--- @param node TSNode
	local function collect_segments(node)
		local node_type = node:type()
		local start_row, start_col, end_row, end_col = node:range()

		-- Only process single-line matches (start_row == end_row == 0 for string parser)
		if start_row ~= 0 or end_row ~= 0 then
			-- For multiline, just use end of line
			if start_row == 0 then
				end_col = #line
			else
				return
			end
		end

		-- Map tree-sitter node types to highlight types
		local hl_type = nil
		if node_type == "strong_emphasis" then
			hl_type = "bold"
		elseif node_type == "emphasis" then
			hl_type = "italic"
		elseif node_type == "code_span" then
			hl_type = "code"
		elseif node_type == "inline_link" or node_type == "shortcut_link" then
			hl_type = "link"
		elseif node_type == "link_destination" then
			hl_type = "link_url"
		end

		if hl_type then
			table.insert(segments, { start_col = start_col, end_col = end_col, hl_type = hl_type })
		end

		-- Recurse into children
		for child in node:iter_children() do
			collect_segments(child)
		end
	end

	collect_segments(root)

	-- Sort by start_col for proper ordering
	table.sort(segments, function(a, b)
		return a.start_col < b.start_col
	end)

	return #segments > 0 and segments or nil
end

--- Build virt_text chunks from line and markdown segments.
--- @param line string input line
--- @param segments table[]|nil markdown segments from parse_markdown_line
--- @param base_hl string base highlight group for non-markdown text
--- @param md_hl table markdown highlight options { bold, italic, code, link, link_url }
--- @return table[] chunks { { text, hl } } for virt_text
function M.build_highlighted_chunks(line, segments, base_hl, md_hl)
	if not segments or #segments == 0 then
		return { { line, base_hl } }
	end

	local chunks = {}
	local pos = 0

	for _, seg in ipairs(segments) do
		-- Add text before this segment with base highlight
		if seg.start_col > pos then
			local text = line:sub(pos + 1, seg.start_col)
			if text ~= "" then
				table.insert(chunks, { text, base_hl })
			end
		end

		-- Add the highlighted segment
		local seg_text = line:sub(seg.start_col + 1, seg.end_col)
		local hl = md_hl[seg.hl_type] or base_hl
		if seg_text ~= "" then
			table.insert(chunks, { seg_text, hl })
		end

		pos = seg.end_col
	end

	-- Add remaining text after last segment
	if pos < #line then
		local text = line:sub(pos + 1)
		if text ~= "" then
			table.insert(chunks, { text, base_hl })
		end
	end

	return chunks
end

--- Apply markdown highlighting to a line, handling code block state.
--- @param line string input line
--- @param in_code_block boolean whether currently inside a code block
--- @param base_hl string base highlight group
--- @param md_hl table markdown highlight options
--- @param md_enabled boolean whether markdown highlighting is enabled
--- @return table[] chunks for virt_text
--- @return boolean new in_code_block state
function M.apply_markdown_highlight_to_line(line, in_code_block, base_hl, md_hl, md_enabled)
	-- Check for code block fence
	local is_fence = line:match("^%s*```")

	if is_fence then
		-- Toggle code block state
		return { { line, base_hl } }, not in_code_block
	end

	if in_code_block or not md_enabled then
		-- Inside code block or markdown disabled: use base highlight
		return { { line, base_hl } }, in_code_block
	end

	-- Parse and build highlighted chunks
	local segments = M.parse_markdown_line(line)
	local chunks = M.build_highlighted_chunks(line, segments, base_hl, md_hl)

	return chunks, in_code_block
end

return M
