local M = {}
local config = require("fude.config")

local ref_ns = vim.api.nvim_create_namespace("fude_refs")

--- Get repository base URL (e.g. "https://github.com/owner/repo").
--- @param pr_url string|nil PR URL to extract from
--- @return string|nil
local function get_repo_base_url(pr_url)
	local url = pr_url or config.state.pr_url
	if url then
		return url:match("(https://github%.com/[^/]+/[^/]+)")
	end
	return nil
end

--- Highlight GitHub references (#123) and URLs in a buffer, and set up gx keymap.
--- @param buf number buffer handle
--- @param repo_url string|nil repository base URL
--- @param line_urls table|nil optional mapping of 0-indexed line number to URL
local function setup_github_refs(buf, repo_url, line_urls)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	for i, line in ipairs(lines) do
		-- Highlight #\d+ references
		local start = 1
		while true do
			local s, e = line:find("#%d+", start)
			if not s then
				break
			end
			pcall(vim.api.nvim_buf_add_highlight, buf, ref_ns, "Underlined", i - 1, s - 1, e)
			start = e + 1
		end
		-- Highlight URLs
		start = 1
		while true do
			local s, e = line:find("https?://[%w%.%-/%%_%?&=#~:@!%$%(%)%*%+,;]+", start)
			if not s then
				break
			end
			pcall(vim.api.nvim_buf_add_highlight, buf, ref_ns, "Underlined", i - 1, s - 1, e)
			start = e + 1
		end
	end

	vim.keymap.set("n", "gx", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local row, col = cursor[1], cursor[2]
		local current_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

		-- Check line-level URL mapping (e.g. CI check detailsUrl)
		if line_urls and line_urls[row - 1] then
			vim.ui.open(line_urls[row - 1])
			return
		end

		-- Check #\d+ reference under cursor
		if repo_url then
			for s, num, e in current_line:gmatch("()#(%d+)()") do
				if col >= s - 1 and col < e - 1 then
					vim.ui.open(repo_url .. "/issues/" .. num)
					return
				end
			end
		end

		-- Check URL under cursor
		for url in current_line:gmatch("https?://[%w%.%-/%%_%?&=#~:@!%$%(%)%*%+,;]+") do
			local s, e = current_line:find(url, 1, true)
			if s and col >= s - 1 and col < e then
				vim.ui.open(url)
				return
			end
		end
	end, { buffer = buf, desc = "Open GitHub reference" })
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
	for i, comment in ipairs(comments) do
		local author = comment.user and comment.user.login or "unknown"
		local created = format_date_fn(comment.created_at)
		local header = string.format("@%s  %s", author, created)
		table.insert(lines, header)
		table.insert(hl_ranges, { line = #lines - 1, hl = "Title" })
		for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
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

	local body = pr_info.body or ""
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
			for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
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

--- Refresh extmarks (virtual text) for the current buffer.
function M.refresh_extmarks()
	local state = config.state
	if not state.active then
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(buf)
	local diff = require("fude.diff")
	local rel_path = diff.to_repo_relative(filepath)
	if not rel_path then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, state.ns_id, 0, -1)

	local comments_mod = require("fude.comments")
	local comment_lines = comments_mod.get_comment_lines(rel_path)

	for _, line in ipairs(comment_lines) do
		local comments = comments_mod.get_comments_at(rel_path, line)
		local count = #comments

		pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, line - 1, 0, {
			virt_text = {
				{ string.format(" %s%d", config.opts.signs.comment, count), config.opts.signs.comment_hl },
			},
			virt_text_pos = "eol",
			priority = 50,
		})
	end

	-- Pending comment indicators (GitHub pending review)
	for key, _ in pairs(state.pending_comments) do
		local parsed = comments_mod.parse_draft_key(key)
		if parsed and parsed.type == "comment" and parsed.path == rel_path then
			pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, parsed.start_line - 1, 0, {
				virt_text = {
					{ " " .. config.opts.signs.pending, config.opts.signs.pending_hl },
				},
				virt_text_pos = "eol",
				priority = 45,
			})
		end
	end

	-- Draft indicators (local drafts, lower priority than pending)
	local comments_parse = comments_mod.parse_draft_key
	local comments_find = comments_mod.find_comment_by_id
	for key, _ in pairs(state.drafts) do
		-- Skip if this key is already in pending_comments
		if state.pending_comments[key] then
			goto draft_continue
		end

		local parsed = comments_parse(key)
		if not parsed then
			goto draft_continue
		end

		local draft_path, draft_line
		if parsed.type == "comment" then
			draft_path = parsed.path
			draft_line = parsed.start_line
		elseif parsed.type == "reply" then
			local found = comments_find(parsed.comment_id, state.comment_map or {})
			if found then
				draft_path = found.path
				draft_line = found.line
			end
		end

		if draft_path == rel_path and draft_line then
			pcall(vim.api.nvim_buf_set_extmark, buf, state.ns_id, draft_line - 1, 0, {
				virt_text = {
					{ " " .. config.opts.signs.draft, config.opts.signs.draft_hl },
				},
				virt_text_pos = "eol",
				priority = 40,
			})
		end

		::draft_continue::
	end
end

--- Clear all extmarks for a specific buffer.
--- @param buf number|nil buffer handle (defaults to current)
function M.clear_extmarks(buf)
	local state = config.state
	if state.ns_id then
		pcall(vim.api.nvim_buf_clear_namespace, buf or 0, state.ns_id, 0, -1)
	end
end

--- Clear extmarks across all buffers.
function M.clear_all_extmarks()
	local state = config.state
	if not state.ns_id then
		return
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_clear_namespace, buf, state.ns_id, 0, -1)
		end
	end
end

--- Select review event type using vim.ui.select.
--- @param callback fun(event: string|nil) called with "COMMENT", "APPROVE", "REQUEST_CHANGES", or nil if cancelled
function M.select_review_event(callback)
	local items = {
		{ label = "Comment", value = "COMMENT" },
		{ label = "Approve", value = "APPROVE" },
		{ label = "Request Changes", value = "REQUEST_CHANGES" },
	}
	vim.ui.select(items, {
		prompt = "Review type:",
		format_item = function(item)
			return item.label
		end,
	}, function(item)
		if item then
			callback(item.value)
		else
			callback(nil)
		end
	end)
end

--- Open a floating window to compose a comment.
--- @param callback fun(body: string|nil) called with comment body or nil if cancelled
--- @param opts table|nil optional settings: initial_lines, title, footer, cursor_pos, submit_on_enter, on_save
function M.open_comment_input(callback, opts)
	opts = opts or {}
	local submit_on_enter = opts.submit_on_enter or false
	local initial_lines = opts.initial_lines or { "" }
	local title = opts.title or " Review Comment "
	local default_footer = submit_on_enter and " <CR> submit | q save draft " or " <CR> save draft | q cancel "
	local footer = opts.footer or default_footer

	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].fude_comment = true

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

	local dim = M.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = dim.height,
		style = "minimal",
		border = config.opts.float.border,
		title = title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})

	vim.cmd("startinsert")

	if opts.cursor_pos then
		vim.cmd("stopinsert")
		vim.api.nvim_win_set_cursor(win, opts.cursor_pos)
	end

	vim.keymap.set("n", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if not submit_on_enter then
			-- Draft mode: save draft via on_save callback
			if opts.on_save and body ~= "" then
				opts.on_save(lines)
			end
		end
		if callback then
			callback(body ~= "" and body or nil)
		end
	end, { buffer = buf, desc = submit_on_enter and "Submit" or "Save draft" })

	vim.keymap.set("n", "q", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = vim.trim(table.concat(lines, "\n"))
		vim.api.nvim_win_close(win, true)
		if submit_on_enter then
			-- Submit mode: save draft on cancel
			if opts.on_save and body ~= "" then
				opts.on_save(lines)
			end
		end
		-- In draft mode (default), q cancels without saving
		if callback then
			callback(nil)
		end
	end, { buffer = buf, desc = submit_on_enter and "Save draft" or "Cancel" })
end

--- Show comments in a floating window.
--- @param comments table[] list of comment objects from GitHub API
function M.show_comments_float(comments)
	local result = M.format_comments_for_display(comments, config.format_date)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"

	local dim = M.calculate_float_dimensions(
		vim.o.columns,
		vim.o.lines,
		config.opts.float.width or 50,
		config.opts.float.height or 50
	)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = dim.row,
		col = dim.col,
		width = dim.width,
		height = dim.height,
		style = "minimal",
		border = config.opts.float.border,
		title = string.format(" Comments (%d) ", #comments),
		title_pos = "center",
		footer = " r reply | q close ",
		footer_pos = "center",
	})

	local ns = config.state.ns_id
	for _, hl in ipairs(result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
	end

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "r", function()
		local last_comment = comments[#comments]
		if last_comment then
			vim.api.nvim_win_close(win, true)
			require("fude.comments").reply_to_comment(last_comment.id)
		end
	end, { buffer = buf })

	local km = config.opts.keymaps
	if km.next_comment then
		vim.keymap.set("n", km.next_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comments").next_comment()
		end, { buffer = buf })
	end
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			vim.api.nvim_win_close(win, true)
			require("fude.comments").prev_comment()
		end, { buffer = buf })
	end

	setup_github_refs(buf, get_repo_base_url())
end

--- Show PR overview in a split-pane floating window.
--- @param pr_info table PR data from gh pr view
--- @param issue_comments table[] issue-level comments
--- @param opts table { on_new_comment: fun(), on_refresh: fun() }
function M.show_overview_float(pr_info, issue_comments, opts)
	local left_result = M.build_overview_left_lines(pr_info, issue_comments, config.format_date)
	local right_result = M.build_overview_right_lines(pr_info)

	-- Create left buffer
	local left_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_result.lines)
	vim.bo[left_buf].modifiable = false
	vim.bo[left_buf].buftype = "nofile"
	vim.bo[left_buf].bufhidden = "wipe"
	vim.bo[left_buf].filetype = "markdown"

	-- Create right buffer
	local right_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_result.lines)
	vim.bo[right_buf].modifiable = false
	vim.bo[right_buf].buftype = "nofile"
	vim.bo[right_buf].bufhidden = "wipe"
	vim.bo[right_buf].filetype = "markdown"

	-- Calculate split-pane layout
	local ov = config.opts.overview or {}
	local layout =
		M.calculate_overview_layout(vim.o.columns, vim.o.lines, ov.width or 80, ov.height or 80, ov.right_width or 30)

	-- Use the taller content, capped at max layout height
	local content_height = math.min(math.max(#left_result.lines, #right_result.lines) + 2, layout.left.height)
	local row = math.floor((vim.o.lines - content_height) / 2)

	-- Open left window (focused)
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		row = row,
		col = layout.left.col,
		width = layout.left.width,
		height = content_height,
		style = "minimal",
		border = config.opts.float.border,
		title = " PR Overview ",
		title_pos = "center",
	})
	vim.wo[left_win].wrap = true

	-- Open right window (not focused)
	local right_win = vim.api.nvim_open_win(right_buf, false, {
		relative = "editor",
		row = row,
		col = layout.right.col,
		width = layout.right.width,
		height = content_height,
		style = "minimal",
		border = config.opts.float.border,
	})
	vim.wo[right_win].wrap = true

	-- Apply highlights
	local ns = config.state.ns_id or vim.api.nvim_create_namespace("fude")
	for _, hl in ipairs(left_result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, 0, -1)
	end
	for _, hl in ipairs(right_result.hl_ranges) do
		pcall(vim.api.nvim_buf_add_highlight, right_buf, ns, hl.hl, hl.line, 0, -1)
	end

	-- Set section marks (left pane only)
	local marks = ov.marks or { description = "d", comments = "c" }
	for section, mark in pairs(marks) do
		local line = left_result.sections[section]
		if line and mark then
			vim.api.nvim_buf_set_mark(left_buf, mark, line, 0, {})
		end
	end

	-- Close both windows helper
	local closing = false
	local function close_both()
		if closing then
			return
		end
		closing = true
		pcall(vim.api.nvim_win_close, left_win, true)
		pcall(vim.api.nvim_win_close, right_win, true)
	end

	-- WinClosed autocmd to close partner window (unique per instance)
	local augroup = vim.api.nvim_create_augroup("fude_overview_" .. left_win, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == left_win or closed_win == right_win then
				close_both()
				vim.api.nvim_del_augroup_by_id(augroup)
			end
		end,
	})

	-- Keymaps for left buffer
	vim.keymap.set("n", "q", close_both, { buffer = left_buf })

	vim.keymap.set("n", "C", function()
		close_both()
		if opts.on_new_comment then
			opts.on_new_comment()
		end
	end, { buffer = left_buf, desc = "New PR comment" })

	vim.keymap.set("n", "R", function()
		close_both()
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = left_buf, desc = "Refresh PR overview" })

	-- Tab to switch between panes
	vim.keymap.set("n", "<Tab>", function()
		vim.api.nvim_set_current_win(right_win)
	end, { buffer = left_buf, desc = "Switch to right pane" })

	vim.keymap.set("n", "<Tab>", function()
		vim.api.nvim_set_current_win(left_win)
	end, { buffer = right_buf, desc = "Switch to left pane" })

	-- Section jump keymaps (left pane)
	local section_lines = {}
	for _, line in pairs(left_result.sections) do
		table.insert(section_lines, line)
	end
	table.sort(section_lines)

	vim.keymap.set("n", "]s", function()
		local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
		for _, line in ipairs(section_lines) do
			if line > cur_line then
				vim.api.nvim_win_set_cursor(left_win, { line, 0 })
				return
			end
		end
	end, { buffer = left_buf, desc = "Next section" })

	vim.keymap.set("n", "[s", function()
		local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
		for i = #section_lines, 1, -1 do
			if section_lines[i] < cur_line then
				vim.api.nvim_win_set_cursor(left_win, { section_lines[i], 0 })
				return
			end
		end
	end, { buffer = left_buf, desc = "Previous section" })

	-- Comment navigation keymaps (left pane only — navigate between issue comments)
	local comment_lines = left_result.comment_positions
	local km = config.opts.keymaps
	if km.next_comment and #comment_lines > 0 then
		vim.keymap.set("n", km.next_comment, function()
			local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
			for _, line in ipairs(comment_lines) do
				if line > cur_line then
					vim.api.nvim_win_set_cursor(left_win, { line, 0 })
					return
				end
			end
			-- Wrap around to first comment
			vim.api.nvim_win_set_cursor(left_win, { comment_lines[1], 0 })
		end, { buffer = left_buf, desc = "Next comment" })
	end
	if km.prev_comment and #comment_lines > 0 then
		vim.keymap.set("n", km.prev_comment, function()
			local cur_line = vim.api.nvim_win_get_cursor(left_win)[1]
			for i = #comment_lines, 1, -1 do
				if comment_lines[i] < cur_line then
					vim.api.nvim_win_set_cursor(left_win, { comment_lines[i], 0 })
					return
				end
			end
			-- Wrap around to last comment
			vim.api.nvim_win_set_cursor(left_win, { comment_lines[#comment_lines], 0 })
		end, { buffer = left_buf, desc = "Previous comment" })
	end

	-- Keymaps for right buffer
	vim.keymap.set("n", "q", close_both, { buffer = right_buf })

	vim.keymap.set("n", "R", function()
		close_both()
		if opts.on_refresh then
			opts.on_refresh()
		end
	end, { buffer = right_buf, desc = "Refresh PR overview" })

	-- GitHub refs for both panes
	setup_github_refs(left_buf, get_repo_base_url(pr_info.url))
	setup_github_refs(right_buf, get_repo_base_url(pr_info.url), right_result.check_urls)
end

return M
