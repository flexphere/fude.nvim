local M = {}
local config = require("fude.config")

--- The loading placeholder of the show() in flight, if any, with the session
--- it was opened for: a second show() of the same session while it is open
--- would stack a second placeholder and later a second overview, so it is
--- dropped instead (the first one will show the overview). A placeholder of
--- another session (stop → start while the fetch was pending, which closes
--- nothing) is closed and replaced, since its own callback will do nothing
--- more than close it once the stale response arrives.
--- @type { handle: table, state: table }|nil
local loading_in_flight

--- The overview fetch in flight, if any, with the session it runs for and the
--- callbacks waiting for it. prefetch() and show() share it, so a show() while
--- the prefetch is still running waits for that request instead of sending a
--- second one. `stale` is set when the cache is invalidated while the fetch
--- runs: its data predates the change, so it is handed to the waiters but not
--- cached.
--- @alias fude.OverviewWaiter fun(err: string|nil, pr_info: table|nil, pr_comments: table|nil)
--- @type { state: table, waiters: fude.OverviewWaiter[], stale: boolean }|nil
local fetch_in_flight

--- Fetch the overview data (PR info, then the PR-level comments) for `state`,
--- joining the fetch in flight for the same session if there is one. On
--- success, when `state` is still the active session, the result is stored in
--- `state.overview_cache` before the waiters run. Every waiter is called once,
--- also when the session changed meanwhile: each one checks `config.state`
--- itself (show() must still close its placeholder then).
--- @param state table config.state the fetch is for
--- @param on_done fun(err: string|nil, pr_info: table|nil, pr_comments: table|nil)
local function fetch_overview(state, on_done)
	if fetch_in_flight and fetch_in_flight.state == state then
		table.insert(fetch_in_flight.waiters, on_done)
		return
	end
	local entry = { state = state, waiters = { on_done }, stale = false }
	fetch_in_flight = entry

	local function finish(err, pr_info, pr_comments)
		if fetch_in_flight == entry then
			fetch_in_flight = nil
		end
		if not err and config.state == state and not entry.stale then
			state.overview_cache = { pr_info = pr_info, pr_comments = pr_comments }
		end
		for _, waiter in ipairs(entry.waiters) do
			waiter(err, pr_info, pr_comments)
		end
	end

	require("fude.gh").get_pr_overview(function(err, pr_info)
		-- A stop (or stop + start) in between: the comments of the old PR are
		-- not worth fetching, and nothing may be cached for the new session.
		if config.state ~= state then
			finish("session changed")
			return
		end
		if err then
			finish(err)
			return
		end
		-- Issue comments plus submitted review bodies, which GitHub also shows
		-- as comments in the Conversation tab.
		require("fude.comments.sync").fetch_pr_level_comments(pr_info.number, function(pr_comments)
			finish(nil, pr_info, pr_comments)
		end)
	end, state.pr_number)
end

--- Drop the cached overview data of the current session (and keep a fetch in
--- flight from caching what it read before the change), so the next
--- :FudeReviewOverview fetches again. Called after a request that changes what
--- the overview shows (reviewers, labels).
local function invalidate_cache()
	config.state.overview_cache = nil
	if fetch_in_flight and fetch_in_flight.state == config.state then
		fetch_in_flight.stale = true
	end
end

--- Fetch the overview data of the GitHub review session in the background and
--- cache it in `state.overview_cache`, so the next :FudeReviewOverview opens
--- at once. Called by init.start() and init.reload(). Silent: a failure only
--- leaves the cache as it was, and show() then fetches (and reports errors)
--- itself. No-op outside a GitHub review session.
function M.prefetch()
	local state = config.state
	if not state.active or state.review_mode ~= "github" then
		return
	end
	fetch_overview(state, function() end)
end

--- Open the overview float with the given data.
--- @param state table config.state the data belongs to
--- @param pr_info table
--- @param pr_comments table
local function open_overview(state, pr_info, pr_comments)
	require("fude.ui").show_overview_float(pr_info, pr_comments, {
		on_menu = function()
			M.open_menu(pr_info, state)
		end,
		on_refresh = function()
			M.show({ fresh = true })
		end,
		on_re_request = function()
			M.re_request_review(pr_info, state)
		end,
	})
end

--- Show PR overview. Requires active review session.
--- Opens at once from `state.overview_cache` (filled by prefetch() and by every
--- fetch) unless `opts.fresh` is set; otherwise shows the loading placeholder
--- while fetching. A fetch already in flight for the session (the prefetch) is
--- joined, not repeated.
--- @param opts { fresh: boolean|nil }|nil fresh: ignore the cache and fetch again (`R`, after posting a comment)
function M.show(opts)
	opts = opts or {}
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if state.review_mode == "local" then
		vim.notify("fude.nvim: PR overview is not available in local review mode", vim.log.levels.WARN)
		return
	end
	if loading_in_flight and loading_in_flight.handle.is_open() then
		if loading_in_flight.state == state then
			return
		end
		loading_in_flight.handle.close()
	end

	local cache = state.overview_cache
	if cache and not opts.fresh then
		open_overview(state, cache.pr_info, cache.pr_comments)
		return
	end

	-- Two gh calls run before anything is shown; the placeholder says so.
	-- Every terminal path below closes it.
	local loading = require("fude.ui").open_overview_loading()
	loading_in_flight = { handle = loading, state = state }

	fetch_overview(state, function(err, pr_info, pr_comments)
		-- The overview and every flow started from it act on this session's
		-- PR; a stop (or stop + start) in between must not let them through.
		if config.state ~= state then
			loading.close()
			return
		end
		if err then
			loading.close()
			vim.notify("fude.nvim: No PR found: " .. (err or ""), vim.log.levels.ERROR)
			return
		end
		-- The user closed the placeholder (`q`): they gave up waiting, so
		-- the overview must not pop up over whatever they moved on to.
		if not loading.is_open() then
			return
		end
		loading.close()
		open_overview(state, pr_info, pr_comments)
	end)
end

--- Whether the session captured before an async step is still the active one.
--- A flow started by a command rather than from the overview (`:FudeEditReviewers`,
--- `:FudeEditLabels`) captures no session: it acts on the `pr_info` it was
--- given, which no session change can make stale, so nil is always current.
--- @param captured_state table|nil config.state at the time the flow started, or nil
--- @return boolean
local function is_current(captured_state)
	if captured_state == nil then
		return true
	end
	return config.state == captured_state and config.state.active == true
end

--- Build a function that reopens the overview, guarded like re_request_review:
--- the overview float is closed before the flows below run, and a stop()
--- (or stop + start of another session) while they wait must not reopen it.
--- Used by the menu's cancel only; the reviewer / label editors and `r` do
--- not reopen it (closing their picker or select ends the flow).
--- @param captured_state table
--- @return fun()
local function make_reopen(captured_state)
	return function()
		if is_current(captured_state) then
			M.show()
		end
	end
end

--- Refuse a flow started from an overview of a session that is gone: the
--- float can stay open across :FudeReviewStop (and a new :FudeReviewStart),
--- and its pr_info belongs to the old session's PR.
--- @param captured_state table|nil see is_current
--- @return boolean current
local function ensure_current(captured_state)
	if is_current(captured_state) then
		return true
	end
	vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
	return false
end

--- Repository of the PR (`owner/repo` from its URL), passed to every API call
--- of the editors so a `:cd` into another repository cannot retarget them.
--- nil (gh resolves the cwd's repository) when the URL is missing.
--- @param pr_info table
--- @return string|nil
local function pr_repo(pr_info)
	return require("fude.drafts").repo_slug(type(pr_info.url) == "string" and pr_info.url or nil)
end

--- Actions of the overview's `C` menu, in display order.
M.MENU_ITEMS = {
	{ key = "comment", label = "Comment: write a new comment on the PR" },
	{ key = "reviewer", label = "Reviewer: request a review or remove a review request" },
	{ key = "label", label = "Label: add or remove labels on the PR" },
}

--- Open the overview's `C` menu: new PR comment, reviewers, or labels.
--- @param pr_info table PR data from gh pr view
--- @param captured_state table|nil config.state the overview was opened in; nil ties the flow to no session
function M.open_menu(pr_info, captured_state)
	if not ensure_current(captured_state) then
		return
	end
	local reopen = make_reopen(captured_state)
	vim.ui.select(M.MENU_ITEMS, {
		prompt = "Edit PR:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			reopen()
		elseif not ensure_current(captured_state) then
			return
		elseif choice.key == "comment" then
			M.create_comment(pr_info.number)
		elseif choice.key == "reviewer" then
			M.edit_reviewers(pr_info, captured_state)
		elseif choice.key == "label" then
			M.edit_labels(pr_info, captured_state)
		end
	end)
end

--- Run one toggle request from a toggle picker, refusing when the session it
--- was opened in is gone (the picker can outlive a :FudeReviewStop).
--- @param captured_state table|nil see is_current
--- @param request fun(cb: fun(err: string|nil)) sends the request
--- @param success_msg string
--- @param failure_msg string
--- @param done fun(ok: boolean)
local function run_toggle(captured_state, request, success_msg, failure_msg, done)
	if not is_current(captured_state) then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		done(false)
		return
	end
	request(function(err)
		if err then
			vim.notify("fude.nvim: " .. failure_msg .. ": " .. err, vim.log.levels.ERROR)
			done(false)
			return
		end
		invalidate_cache()
		vim.notify("fude.nvim: " .. success_msg, vim.log.levels.INFO)
		done(true)
	end)
end

--- Edit the PR's requested reviewers in a toggle picker: `<Tab>` requests a
--- review from the user under the cursor, or removes their pending request.
--- Closing the picker ends the flow; the overview is not reopened.
--- @param pr_info table PR data from gh pr view (number, url, author, reviewRequests, latestReviews)
--- @param captured_state table|nil config.state the overview was opened in; nil ties the flow to no session
function M.edit_reviewers(pr_info, captured_state)
	local gh = require("fude.gh")
	local format = require("fude.ui.format")
	if not ensure_current(captured_state) then
		return
	end
	local repo = pr_repo(pr_info)
	-- author can be JSON null, which decodes to truthy vim.NIL
	local author = type(pr_info.author) == "table" and pr_info.author.login or nil

	gh.get_collaborators(function(err, collaborators)
		if not is_current(captured_state) then
			return
		end
		if err or type(collaborators) ~= "table" then
			-- Listing collaborators needs push access; the users already
			-- involved in the PR can still be edited.
			vim.notify(
				"fude.nvim: Could not list collaborators; showing requested and reviewed users only: " .. (err or ""),
				vim.log.levels.WARN
			)
			collaborators = {}
		end

		local entries =
			format.build_reviewer_entries(collaborators, pr_info.reviewRequests or {}, pr_info.latestReviews or {}, author)
		if #entries == 0 then
			vim.notify("fude.nvim: No reviewers to choose from", vim.log.levels.INFO)
			return
		end

		local items = {}
		for _, entry in ipairs(entries) do
			table.insert(items, {
				-- Copilot's API login is shown as @copilot
				text = "@" .. format.reviewer_display_name(entry.login),
				on = entry.requested,
				-- Both rendered from item.on, so they follow a toggle in place
				mark = function(item)
					return format.format_reviewer_mark(item.on, entry.review_state)
				end,
				detail = function(item)
					return format.format_reviewer_detail(item.on, entry.review_state)
				end,
				value = entry.login,
				review_state = entry.review_state,
			})
		end

		-- The avatars of the overview, before each row (snacks.nvim image
		-- support only; cached files, one download per login)
		local avatars = require("fude.ui.avatars")
		require("fude.ui.toggle_picker").open({
			title = "Reviewers",
			items = items,
			images = avatars.is_enabled() and function(item, cb)
				avatars.fetch(item.value, cb)
			end or nil,
			-- A dedicated key, shown at the end of each row it applies to, so
			-- re-requesting does not depend on knowing that <Tab> on a
			-- reviewed user also re-requests.
			extra_action = {
				key = "<C-e>",
				label = "re-request",
				available = function(item)
					return not item.on and item.review_state ~= nil
				end,
				unavailable_reason = function(item)
					if item.on then
						return item.text .. " already has a pending review request"
					end
					return item.text .. " has not reviewed yet; <Tab> requests a review"
				end,
				run = function(item, done)
					local login = item.value
					run_toggle(captured_state, function(cb)
						gh.re_request_review(pr_info.number, { login }, cb, repo)
					end, "Re-requested review from " .. item.text, "Failed to re-request review from " .. item.text, done)
				end,
				result_on = true,
				-- An approver is rarely asked again, so their hint stays quiet
				hint_hl = function(item)
					return item.review_state == "APPROVED" and "Comment" or nil
				end,
			},
			is_alive = function()
				return is_current(captured_state)
			end,
			on_toggle = function(item, done)
				local login, name = item.value, item.text
				if item.on then
					run_toggle(captured_state, function(cb)
						gh.remove_review_request(pr_info.number, { login }, cb, repo)
					end, "Removed review request from " .. name, "Failed to remove review request from " .. name, done)
				else
					-- The same endpoint requests a first review or re-requests
					-- one from a user who already reviewed; say which it was.
					local verb = item.review_state and "re-request" or "request"
					local done_verb = item.review_state and "Re-requested" or "Requested"
					run_toggle(captured_state, function(cb)
						gh.re_request_review(pr_info.number, { login }, cb, repo)
					end, done_verb .. " review from " .. name, "Failed to " .. verb .. " review from " .. name, done)
				end
			end,
		})
	end, nil, repo)
end

--- Edit the PR's labels in a toggle picker: `<Tab>` adds the label under the
--- cursor, or removes it when the PR already has it. Closing the picker ends
--- the flow; the overview is not reopened.
--- @param pr_info table PR data from gh pr view (number, url, labels)
--- @param captured_state table|nil config.state the overview was opened in; nil ties the flow to no session
function M.edit_labels(pr_info, captured_state)
	local gh = require("fude.gh")
	local format = require("fude.ui.format")
	if not ensure_current(captured_state) then
		return
	end
	local repo = pr_repo(pr_info)

	gh.get_repo_labels(function(err, repo_labels)
		if not is_current(captured_state) then
			return
		end
		if err or type(repo_labels) ~= "table" then
			-- The labels already on the PR can still be removed.
			vim.notify(
				"fude.nvim: Could not list repository labels; showing the PR's labels only: " .. (err or ""),
				vim.log.levels.WARN
			)
			repo_labels = {}
		end

		local entries = format.build_label_entries(repo_labels, pr_info.labels or {})
		if #entries == 0 then
			vim.notify("fude.nvim: No labels to choose from", vim.log.levels.INFO)
			return
		end

		local items = {}
		for _, entry in ipairs(entries) do
			table.insert(items, { text = entry.name, on = entry.applied, detail = entry.description, value = entry.name })
		end

		require("fude.ui.toggle_picker").open({
			title = "Labels",
			items = items,
			is_alive = function()
				return is_current(captured_state)
			end,
			on_toggle = function(item, done)
				local name = item.value
				if item.on then
					run_toggle(captured_state, function(cb)
						gh.remove_label(pr_info.number, name, cb, repo)
					end, "Removed label " .. name, "Failed to remove label " .. name, done)
				else
					run_toggle(captured_state, function(cb)
						gh.add_labels(pr_info.number, { name }, cb, repo)
					end, "Added label " .. name, "Failed to add label " .. name, done)
				end
			end,
		})
	end, repo)
end

--- Re-request a review from a reviewer who has already reviewed.
--- @param pr_info table PR data from gh pr view (number, url, author, reviewRequests, latestReviews)
--- @param captured_state table|nil config.state the overview was opened in; nil ties the flow to no session
function M.re_request_review(pr_info, captured_state)
	local ui = require("fude.ui")
	local gh = require("fude.gh")
	local format = require("fude.ui.format")

	if not ensure_current(captured_state) then
		return
	end
	-- The overview float is closed before this function runs and is not
	-- reopened: like the reviewer / label editors, the flow ends here, and
	-- :FudeReviewOverview shows the result.

	local candidates = ui.build_re_request_candidates(
		pr_info.reviewRequests or {},
		pr_info.latestReviews or {},
		-- author can be JSON null, which decodes to truthy vim.NIL
		type(pr_info.author) == "table" and pr_info.author.login or nil
	)
	if #candidates == 0 then
		vim.notify("fude.nvim: No reviewers to re-request", vim.log.levels.INFO)
		return
	end

	vim.ui.select(candidates, {
		prompt = "Re-request review from:",
		format_item = function(candidate)
			return "@" .. format.reviewer_display_name(candidate.login) .. "  (" .. candidate.state:lower() .. ")"
		end,
	}, function(choice)
		if not choice then
			return
		end

		if not ensure_current(captured_state) then
			return
		end
		local name = "@" .. format.reviewer_display_name(choice.login)
		gh.re_request_review(pr_info.number, { choice.login }, function(err, _)
			if err then
				vim.notify("fude.nvim: Failed to re-request review from " .. name .. ": " .. err, vim.log.levels.ERROR)
				return
			end
			invalidate_cache()
			vim.notify("fude.nvim: Re-requested review from " .. name, vim.log.levels.INFO)
		end, pr_repo(pr_info))
	end)
end

--- Open a reviewer / label editor on the current PR from a command, without
--- the overview: the GitHub review session's PR (by URL) when one is active,
--- else the current branch's (on a detached HEAD, the commit's), like
--- pr.change_state.
--- The editor is tied to no session (captured_state nil): the PR it edits is
--- fixed by the fetched pr_info, so a later :FudeReviewStop / Start cannot
--- make it stale.
--- @param what string "reviewers" | "labels", for the messages
--- @param open fun(pr_info: table, captured_state: nil) M.edit_reviewers / M.edit_labels
local function edit_current_pr(what, open)
	-- The local commit scope detaches HEAD onto a past commit, so the
	-- commit-based lookup could find another PR that contains it rather than
	-- the session branch's PR.
	if require("fude.local.session").in_commit_scope() then
		vim.notify(
			"fude.nvim: Cannot edit the PR " .. what .. " in the commit scope — switch scope first",
			vim.log.levels.WARN
		)
		return
	end
	local gh = require("fude.gh")
	-- The session's PR by URL, not number: gh resolves a bare number against
	-- the cwd's repository, so after a `:cd` into another repository the same
	-- number would name that repository's PR.
	local state = config.state
	local pr = state.active and (state.pr_url or state.pr_number) or nil

	gh.get_pr_edit_info(pr, function(err, pr_info)
		if gh.is_no_pr_error(err) then
			vim.notify("fude.nvim: " .. vim.trim(err), vim.log.levels.WARN)
			return
		end
		if err then
			vim.notify("fude.nvim: " .. vim.trim(err), vim.log.levels.ERROR)
			return
		end
		if not pr_info.number then
			vim.notify("fude.nvim: No PR found for current branch", vim.log.levels.WARN)
			return
		end
		open(pr_info, nil)
	end)
end

--- `:FudeEditReviewers`: request or remove reviewers of the current PR.
function M.edit_current_reviewers()
	edit_current_pr("reviewers", M.edit_reviewers)
end

--- `:FudeEditLabels`: add or remove labels of the current PR.
function M.edit_current_labels()
	edit_current_pr("labels", M.edit_labels)
end

--- Create a new issue-level comment on the PR.
--- @param pr_number number
function M.create_comment(pr_number)
	local ui = require("fude.ui")
	local gh = require("fude.gh")
	local drafts = require("fude.drafts")

	local draft_key = drafts.current_key("issue")
	local draft_body = drafts.get(draft_key)

	ui.open_comment_input(function(body, action)
		if action == "draft" then
			drafts.set(draft_key, body)
			vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
			return
		elseif action == "discard" then
			drafts.remove(draft_key)
			return
		end
		if not body then
			return
		end

		gh.create_issue_comment(pr_number, body, function(err, _)
			if err then
				vim.notify("fude.nvim: Failed to post comment: " .. err, vim.log.levels.ERROR)
				return
			end
			-- Drop the local draft only after the comment is posted.
			drafts.remove(draft_key)
			vim.notify("fude.nvim: Comment posted", vim.log.levels.INFO)
			M.show({ fresh = true })
		end)
	end, {
		footer = " <CR> submit | q cancel ",
		initial_lines = draft_body and vim.split(draft_body, "\n") or nil,
		allow_draft = drafts.enabled(),
	})
end

return M
