local M = {}
local config = require("fude.config")

--- Show PR overview. Requires active review session.
function M.show()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if state.review_mode == "local" then
		vim.notify("fude.nvim: PR overview is not available in local review mode", vim.log.levels.WARN)
		return
	end

	local gh = require("fude.gh")
	local ui = require("fude.ui")

	-- Two gh calls run before anything is shown; the placeholder says so.
	-- Every terminal path below closes it.
	local loading = ui.open_overview_loading()

	gh.get_pr_overview(function(err, pr_info)
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

		-- Issue comments plus submitted review bodies, which GitHub also shows
		-- as comments in the Conversation tab.
		require("fude.comments.sync").fetch_pr_level_comments(pr_info.number, function(pr_comments)
			if config.state ~= state then
				loading.close()
				return
			end
			-- The user closed the placeholder (`q`): they gave up waiting, so
			-- the overview must not pop up over whatever they moved on to.
			if not loading.is_open() then
				return
			end
			loading.close()
			ui.show_overview_float(pr_info, pr_comments, {
				on_menu = function()
					M.open_menu(pr_info, state)
				end,
				on_refresh = function()
					M.show()
				end,
				on_re_request = function()
					M.re_request_review(pr_info, state)
				end,
			})
		end)
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
				text = "@" .. entry.login,
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

		require("fude.ui.toggle_picker").open({
			title = "Reviewers",
			items = items,
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
					end, "Re-requested review from @" .. login, "Failed to re-request review from @" .. login, done)
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
				local login = item.value
				if item.on then
					run_toggle(captured_state, function(cb)
						gh.remove_review_request(pr_info.number, { login }, cb, repo)
					end, "Removed review request from @" .. login, "Failed to remove review request from @" .. login, done)
				else
					-- The same endpoint requests a first review or re-requests
					-- one from a user who already reviewed; say which it was.
					local verb = item.review_state and "re-request" or "request"
					local done_verb = item.review_state and "Re-requested" or "Requested"
					run_toggle(captured_state, function(cb)
						gh.re_request_review(pr_info.number, { login }, cb, repo)
					end, done_verb .. " review from @" .. login, "Failed to " .. verb .. " review from @" .. login, done)
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
			return "@" .. candidate.login .. "  (" .. candidate.state:lower() .. ")"
		end,
	}, function(choice)
		if not choice then
			return
		end

		if not ensure_current(captured_state) then
			return
		end
		gh.re_request_review(pr_info.number, { choice.login }, function(err, _)
			if err then
				vim.notify("fude.nvim: Failed to re-request review: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("fude.nvim: Re-requested review from @" .. choice.login, vim.log.levels.INFO)
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
			M.show()
		end)
	end, {
		footer = " <CR> submit | q cancel ",
		initial_lines = draft_body and vim.split(draft_body, "\n") or nil,
		allow_draft = drafts.enabled(),
	})
end

return M
