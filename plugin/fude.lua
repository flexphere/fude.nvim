if vim.g.loaded_fude then
	return
end
vim.g.loaded_fude = true

vim.api.nvim_create_user_command("FudeStart", function()
	require("fude").start()
end, { desc = "Start PR review mode" })

vim.api.nvim_create_user_command("FudeStop", function()
	require("fude").stop()
end, { desc = "Stop PR review mode" })

vim.api.nvim_create_user_command("FudeToggle", function()
	require("fude").toggle()
end, { desc = "Toggle PR review mode" })

vim.api.nvim_create_user_command("FudeComment", function(opts)
	require("fude.comments").create_comment(opts.range > 0)
end, { desc = "Create PR review comment", range = true })

vim.api.nvim_create_user_command("FudeViewComment", function()
	require("fude.comments").view_comments()
end, { desc = "View PR review comments on current line" })

vim.api.nvim_create_user_command("FudeFiles", function()
	require("fude.files").show()
end, { desc = "List PR changed files" })

vim.api.nvim_create_user_command("FudeOverview", function()
	require("fude.overview").show()
end, { desc = "Show PR overview" })

vim.api.nvim_create_user_command("FudeListComments", function()
	require("fude.comments").list_comments()
end, { desc = "List PR review comments" })

vim.api.nvim_create_user_command("FudeDiff", function()
	require("fude").toggle_diff()
end, { desc = "Toggle diff preview" })

vim.api.nvim_create_user_command("FudeSuggest", function(opts)
	require("fude.comments").suggest_change(opts.range > 0)
end, { desc = "Suggest change on current line/selection", range = true })

vim.api.nvim_create_user_command("FudeListDrafts", function()
	require("fude.comments").list_drafts()
end, { desc = "List draft comments" })

vim.api.nvim_create_user_command("FudeViewed", function()
	require("fude").mark_viewed()
end, { desc = "Mark current file as viewed" })

vim.api.nvim_create_user_command("FudeUnviewed", function()
	require("fude").unmark_viewed()
end, { desc = "Unmark current file as viewed" })

vim.api.nvim_create_user_command("FudeBrowse", function()
	local state = require("fude.config").state
	if not state.active or not state.pr_url then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	vim.ui.open(state.pr_url)
end, { desc = "Open PR in browser" })

vim.api.nvim_create_user_command("FudeSubmit", function()
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
			comments.submit_as_review(event, body, function(err, excluded_count)
				if err then
					vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
					return
				end
				local msg = "Review submitted"
				if excluded_count > 0 then
					msg = msg .. string.format(" (%d drafts excluded: replies/PR comments)", excluded_count)
				end
				vim.notify("fude.nvim: " .. msg, vim.log.levels.INFO)
			end)
		end, {
			title = " Review Body (optional) ",
			footer = " <CR> submit | q skip body ",
			submit_on_enter = true,
		})
	end)
end, { desc = "Submit drafts as review" })
