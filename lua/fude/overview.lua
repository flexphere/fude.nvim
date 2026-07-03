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

		gh.get_issue_comments(pr_info.number, function(comments_err, issue_comments)
			if comments_err then
				issue_comments = {}
			end

			ui.show_overview_float(pr_info, issue_comments, {
				on_new_comment = function()
					M.create_comment(pr_info.number)
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

--- Re-request a review from a reviewer who has already reviewed.
--- @param pr_info table PR data from gh pr view (number, author, reviewRequests, latestReviews)
function M.re_request_review(pr_info)
	local ui = require("fude.ui")
	local gh = require("fude.gh")

	-- The overview float is closed before this function runs, so every
	-- terminal path reopens it. M.show() itself guards on state.active with
	-- a WARN notify; guard here silently so a stop() racing the async flow
	-- does not produce noise.
	local function reopen()
		if config.state.active then
			M.show()
		end
	end

	local candidates = ui.build_re_request_candidates(
		pr_info.reviewRequests or {},
		pr_info.latestReviews or {},
		pr_info.author and pr_info.author.login
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
