if vim.g.loaded_reviewit then
	return
end
vim.g.loaded_reviewit = true

vim.api.nvim_create_user_command("ReviewStart", function()
	require("reviewit").start()
end, { desc = "Start PR review mode" })

vim.api.nvim_create_user_command("ReviewStop", function()
	require("reviewit").stop()
end, { desc = "Stop PR review mode" })

vim.api.nvim_create_user_command("ReviewToggle", function()
	require("reviewit").toggle()
end, { desc = "Toggle PR review mode" })

vim.api.nvim_create_user_command("ReviewComment", function(opts)
	require("reviewit.comments").create_comment(opts.range > 0)
end, { desc = "Create PR review comment", range = true })

vim.api.nvim_create_user_command("ReviewViewComment", function()
	require("reviewit.comments").view_comments()
end, { desc = "View PR review comments on current line" })

vim.api.nvim_create_user_command("ReviewFiles", function()
	require("reviewit.files").show()
end, { desc = "List PR changed files" })

vim.api.nvim_create_user_command("ReviewOverview", function()
	require("reviewit.overview").show()
end, { desc = "Show PR overview" })

vim.api.nvim_create_user_command("ReviewListComments", function()
	require("reviewit.comments").list_comments()
end, { desc = "List PR review comments" })

vim.api.nvim_create_user_command("ReviewDiff", function()
	require("reviewit").toggle_diff()
end, { desc = "Toggle diff preview" })

vim.api.nvim_create_user_command("ReviewSuggest", function(opts)
	require("reviewit.comments").suggest_change(opts.range > 0)
end, { desc = "Suggest change on current line/selection", range = true })

vim.api.nvim_create_user_command("ReviewListDrafts", function()
	require("reviewit.comments").list_drafts()
end, { desc = "List draft comments" })

vim.api.nvim_create_user_command("ReviewBrowse", function()
	local state = require("reviewit.config").state
	if not state.active or not state.pr_url then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end
	vim.ui.open(state.pr_url)
end, { desc = "Open PR in browser" })

vim.api.nvim_create_user_command("ReviewSubmit", function()
	local state = require("reviewit.config").state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end

	local ui = require("reviewit.ui")
	local comments = require("reviewit.comments")

	-- Step 1: Select review event type
	ui.select_review_event(function(event)
		if not event then
			return
		end

		-- Step 2: Input review body (optional)
		ui.open_comment_input(function(body)
			-- Step 3: Submit review
			comments.submit_as_review(event, body, function(err, excluded_count)
				if err then
					vim.notify("reviewit.nvim: " .. err, vim.log.levels.ERROR)
					return
				end
				local msg = "Review submitted"
				if excluded_count > 0 then
					msg = msg .. string.format(" (%d drafts excluded: replies/PR comments)", excluded_count)
				end
				vim.notify("reviewit.nvim: " .. msg, vim.log.levels.INFO)
			end)
		end, {
			title = " Review Body (optional) ",
			footer = " <CR> submit | q skip body ",
			submit_on_enter = true,
		})
	end)
end, { desc = "Submit drafts as review" })
