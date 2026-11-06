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

	gh.get_pr_overview(function(err, pr_info)
		if err then
			vim.notify("fude.nvim: No PR found: " .. (err or ""), vim.log.levels.ERROR)
			return
		end

		-- Issue comments plus submitted review bodies, which GitHub also shows
		-- as comments in the Conversation tab.
		require("fude.comments.sync").fetch_pr_level_comments(pr_info.number, function(pr_comments)
			ui.show_overview_float(pr_info, pr_comments, {
				on_menu = function()
					M.open_menu(pr_info)
				end,
				on_refresh = function()
					M.show()
				end,
				on_re_request = function()
					M.re_request_review(pr_info)
				end,
			})
		end)
	end)
end

--- Whether the session captured before an async step is still the active one.
--- @param captured_state table config.state at the time the flow started
--- @return boolean
local function is_current(captured_state)
	return config.state == captured_state and config.state.active == true
end

--- Build a function that reopens the overview, guarded like re_request_review:
--- the overview float is closed before the flows below run, and a stop()
--- (or stop + start of another session) while they wait must not reopen it.
--- @param captured_state table
--- @return fun()
local function make_reopen(captured_state)
	return function()
		if is_current(captured_state) then
			M.show()
		end
	end
end

--- Actions of the overview's `C` menu, in display order.
M.MENU_ITEMS = {
	{ key = "comment", label = "Comment: write a new comment on the PR" },
	{ key = "reviewer", label = "Reviewer: request a review or remove a review request" },
	{ key = "label", label = "Label: add or remove labels on the PR" },
}

--- Open the overview's `C` menu: new PR comment, reviewers, or labels.
--- @param pr_info table PR data from gh pr view
function M.open_menu(pr_info)
	local reopen = make_reopen(config.state)
	vim.ui.select(M.MENU_ITEMS, {
		prompt = "Edit PR:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			reopen()
		elseif choice.key == "comment" then
			M.create_comment(pr_info.number)
		elseif choice.key == "reviewer" then
			M.edit_reviewers(pr_info)
		elseif choice.key == "label" then
			M.edit_labels(pr_info)
		end
	end)
end

--- Run one toggle request from a toggle picker, refusing when the session it
--- was opened in is gone (the picker can outlive a :FudeReviewStop).
--- @param captured_state table
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
--- @param pr_info table PR data from gh pr view (number, author, reviewRequests, latestReviews)
function M.edit_reviewers(pr_info)
	local gh = require("fude.gh")
	local format = require("fude.ui.format")
	local captured_state = config.state
	local reopen = make_reopen(captured_state)
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
			reopen()
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
			})
		end

		require("fude.ui.toggle_picker").open({
			title = "Reviewers",
			items = items,
			on_close = reopen,
			is_alive = function()
				return is_current(captured_state)
			end,
			on_toggle = function(item, done)
				local login = item.value
				if item.on then
					run_toggle(captured_state, function(cb)
						gh.remove_review_request(pr_info.number, { login }, cb)
					end, "Removed review request from @" .. login, "Failed to remove review request from @" .. login, done)
				else
					run_toggle(captured_state, function(cb)
						gh.re_request_review(pr_info.number, { login }, cb)
					end, "Requested review from @" .. login, "Failed to request review from @" .. login, done)
				end
			end,
		})
	end)
end

--- Edit the PR's labels in a toggle picker: `<Tab>` adds the label under the
--- cursor, or removes it when the PR already has it.
--- @param pr_info table PR data from gh pr view (number, labels)
function M.edit_labels(pr_info)
	local gh = require("fude.gh")
	local format = require("fude.ui.format")
	local captured_state = config.state
	local reopen = make_reopen(captured_state)

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
			reopen()
			return
		end

		local items = {}
		for _, entry in ipairs(entries) do
			table.insert(items, { text = entry.name, on = entry.applied, detail = entry.description, value = entry.name })
		end

		require("fude.ui.toggle_picker").open({
			title = "Labels",
			items = items,
			on_close = reopen,
			is_alive = function()
				return is_current(captured_state)
			end,
			on_toggle = function(item, done)
				local name = item.value
				if item.on then
					run_toggle(captured_state, function(cb)
						gh.remove_label(pr_info.number, name, cb)
					end, "Removed label " .. name, "Failed to remove label " .. name, done)
				else
					run_toggle(captured_state, function(cb)
						gh.add_labels(pr_info.number, { name }, cb)
					end, "Added label " .. name, "Failed to add label " .. name, done)
				end
			end,
		})
	end)
end

--- Re-request a review from a reviewer who has already reviewed.
--- @param pr_info table PR data from gh pr view (number, author, reviewRequests, latestReviews)
function M.re_request_review(pr_info)
	local ui = require("fude.ui")
	local gh = require("fude.gh")

	-- The overview float is closed before this function runs, so every
	-- terminal path reopens it (see make_reopen for the guard).
	local reopen = make_reopen(config.state)

	local candidates = ui.build_re_request_candidates(
		pr_info.reviewRequests or {},
		pr_info.latestReviews or {},
		-- author can be JSON null, which decodes to truthy vim.NIL
		type(pr_info.author) == "table" and pr_info.author.login or nil
	)
	if #candidates == 0 then
		vim.notify("fude.nvim: No reviewers to re-request", vim.log.levels.INFO)
		reopen()
		return
	end

	vim.ui.select(candidates, {
		prompt = "Re-request review from:",
		format_item = function(candidate)
			return "@" .. candidate.login .. "  (" .. candidate.state:lower() .. ")"
		end,
	}, function(choice)
		if not choice then
			reopen()
			return
		end

		gh.re_request_review(pr_info.number, { choice.login }, function(err, _)
			if err then
				vim.notify("fude.nvim: Failed to re-request review: " .. err, vim.log.levels.ERROR)
				reopen()
				return
			end
			vim.notify("fude.nvim: Re-requested review from @" .. choice.login, vim.log.levels.INFO)
			reopen()
		end)
	end)
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
