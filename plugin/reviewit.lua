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

vim.api.nvim_create_user_command("ReviewApprove", function()
	local ui = require("reviewit.ui")
	ui.open_approve_input(function(body)
		require("reviewit.gh").approve_pr(body, function(err)
			if err then
				vim.notify("reviewit.nvim: " .. err, vim.log.levels.ERROR)
			else
				vim.notify("reviewit.nvim: PR approved", vim.log.levels.INFO)
			end
		end)
	end)
end, { desc = "Approve PR" })

vim.api.nvim_create_user_command("ReviewListComments", function()
	require("reviewit.comments").list_comments()
end, { desc = "List PR review comments" })

vim.api.nvim_create_user_command("ReviewDiff", function()
	require("reviewit").toggle_diff()
end, { desc = "Toggle diff preview" })

vim.api.nvim_create_user_command("ReviewBrowse", function()
	local state = require("reviewit.config").state
	if not state.active or not state.pr_url then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end
	vim.ui.open(state.pr_url)
end, { desc = "Open PR in browser" })
