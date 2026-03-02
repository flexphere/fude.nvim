local M = {}
local config = require("fude.config")

--- Show PR overview. Requires active review session.
function M.show()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
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
			})
		end)
	end)
end

--- Create a new issue-level comment on the PR.
--- @param pr_number number
function M.create_comment(pr_number)
	local ui = require("fude.ui")
	local gh = require("fude.gh")
	local state = config.state

	local draft_key = "issue_comment"
	local draft = state.drafts[draft_key]

	ui.open_comment_input(function(body)
		if not body then
			return
		end

		state.drafts[draft_key] = nil

		gh.create_issue_comment(pr_number, body, function(err, _)
			if err then
				vim.notify("fude.nvim: Failed to post comment: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("fude.nvim: Comment posted", vim.log.levels.INFO)
			M.show()
		end)
	end, {
		initial_lines = draft or nil,
		submit_on_enter = true,
		on_save = function(lines)
			state.drafts[draft_key] = lines
			vim.notify("fude.nvim: Draft saved", vim.log.levels.INFO)
		end,
	})
end

return M
