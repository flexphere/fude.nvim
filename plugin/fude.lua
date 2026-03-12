if vim.g.loaded_fude then
	return
end
vim.g.loaded_fude = true

vim.api.nvim_create_user_command("FudeReviewStart", function()
	require("fude").start()
end, { desc = "Start PR review mode" })

vim.api.nvim_create_user_command("FudeReviewStop", function()
	require("fude").stop()
end, { desc = "Stop PR review mode" })

vim.api.nvim_create_user_command("FudeReviewToggle", function()
	require("fude").toggle()
end, { desc = "Toggle PR review mode" })

vim.api.nvim_create_user_command("FudeReviewComment", function(opts)
	require("fude.comments").create_comment(opts.range > 0)
end, { desc = "Create PR review comment", range = true })

vim.api.nvim_create_user_command("FudeReviewViewComment", function()
	require("fude.comments").view_comments()
end, { desc = "View PR review comments on current line" })

vim.api.nvim_create_user_command("FudeReviewFiles", function()
	require("fude.files").show()
end, { desc = "List PR changed files" })

vim.api.nvim_create_user_command("FudeReviewOverview", function()
	require("fude.overview").show()
end, { desc = "Show PR overview" })

vim.api.nvim_create_user_command("FudeReviewScope", function()
	require("fude.scope").select_scope()
end, { desc = "Select review scope (full PR or specific commit)" })

vim.api.nvim_create_user_command("FudeReviewScopeNext", function()
	require("fude.scope").next_scope()
end, { desc = "Move to next review scope" })

vim.api.nvim_create_user_command("FudeReviewScopePrev", function()
	require("fude.scope").prev_scope()
end, { desc = "Move to previous review scope" })

vim.api.nvim_create_user_command("FudeReviewListComments", function()
	require("fude.comments").list_comments()
end, { desc = "List PR review comments" })

vim.api.nvim_create_user_command("FudeReviewDiff", function()
	require("fude").toggle_diff()
end, { desc = "Toggle diff preview" })

vim.api.nvim_create_user_command("FudeReviewSuggest", function(opts)
	require("fude.comments").suggest_change(opts.range > 0)
end, { desc = "Suggest change on current line/selection", range = true })

vim.api.nvim_create_user_command("FudeReviewViewed", function()
	require("fude").mark_viewed()
end, { desc = "Mark current file as viewed" })

vim.api.nvim_create_user_command("FudeReviewUnviewed", function()
	require("fude").unmark_viewed()
end, { desc = "Unmark current file as viewed" })

vim.api.nvim_create_user_command("FudeReviewBrowse", function()
	local state = require("fude.config").state
	if not state.active or not state.pr_url then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	vim.ui.open(state.pr_url)
end, { desc = "Open PR in browser" })

vim.api.nvim_create_user_command("FudeReviewSubmit", function()
	local state = require("fude.config").state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local ui = require("fude.ui")
	local comments = require("fude.comments")

	-- Step 1: Select review event type
	ui.select_review_event(function(event)
		if not event then
			return
		end

		-- Step 2: Input review body (optional)
		ui.open_comment_input(function(body)
			-- Step 3: Submit review
			comments.submit_as_review(event, body, function(err)
				if err then
					vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("fude.nvim: Review submitted", vim.log.levels.INFO)
			end)
		end, {
			title = " Review Body (optional) ",
			footer = " <CR> submit | q skip body ",
		})
	end)
end, { desc = "Submit review" })

vim.api.nvim_create_user_command("FudeCreatePR", function()
	require("fude.pr").create()
end, { desc = "Create draft PR from template" })

vim.api.nvim_create_user_command("FudeReviewReload", function()
	require("fude").reload()
end, { desc = "Reload review data from GitHub" })

vim.api.nvim_create_user_command("FudeReviewToggleCommentStyle", function()
	local config = require("fude.config")
	if not config.state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	local new_style = config.toggle_comment_style()
	vim.notify("fude.nvim: Comment style: " .. new_style, vim.log.levels.INFO)
	require("fude.ui").refresh_extmarks()
end, { desc = "Toggle comment display style (virtualText/inline)" })
