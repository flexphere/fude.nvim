--- Command registry: the single source of truth for every `:FudeXxx` user
--- command. `plugin/fude.lua` registers each entry with
--- `nvim_create_user_command`, and `palette.lua` renders the same entries in
--- the `:FudeCommandPalette` command palette, so adding a command here is enough to expose
--- it in both places.
---
--- Entry shape:
---   name      string            user command name (`FudeXxx`)
---   desc      string            one-line description (command `desc` and palette text)
---   category  string            one of `M.CATEGORIES` (palette grouping)
---   available fun(state): bool  whether the palette lists the command for this `config.state`
---   run       fun(opts)         user command callback (receives the `nvim_create_user_command` opts)
---   range     boolean|nil       `range = true` for line/selection commands
---   nargs     string|nil        `nargs` for commands taking arguments
---   complete  function|nil      `complete` callback for `nargs` commands
---   palette   boolean|nil       `false` hides the entry from the palette (still registered)
local config = require("fude.config")

local M = {}

--- Palette category order (first to last).
M.CATEGORIES = { "Session", "Comments", "Files", "Scope", "Review", "View", "PR" }

----------------------------------------------------------------
-- Availability predicates
----------------------------------------------------------------

local function always()
	return true
end

local function when_inactive(state)
	return not state.active
end

local function when_active(state)
	return state.active == true
end

local function when_github(state)
	return state.active == true and state.review_mode == "github"
end

local function when_local(state)
	return state.active == true and state.review_mode == "local"
end

----------------------------------------------------------------
-- Command bodies too large for an inline `run`
----------------------------------------------------------------

--- Get PR URL, using cached state if available or fetching via gh CLI.
--- @param callback fun(url: string)
local function get_pr_url(callback)
	if config.state.pr_url then
		callback(config.state.pr_url)
		return
	end
	require("fude.gh").get_pr_info(function(err, data)
		if err then
			vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		if not data or not data.url then
			vim.notify("fude.nvim: No PR found for current branch", vim.log.levels.WARN)
			return
		end
		callback(data.url)
	end)
end

--- Submit the pending review: select an event, enter an optional body, submit.
local function submit_review()
	if not config.state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if config.state.review_mode == "local" then
		vim.notify("fude.nvim: Local review has no submit step (comments are saved immediately)", vim.log.levels.WARN)
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
end

local function toggle_comment_style()
	if not config.state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	local new_style = config.toggle_comment_style()
	vim.notify("fude.nvim: Comment style: " .. new_style, vim.log.levels.INFO)
	require("fude.ui").refresh_extmarks()
end

local function toggle_resolved()
	if not config.state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if config.opts.resolved and config.opts.resolved.show == false then
		vim.notify("fude.nvim: Resolved display is disabled (resolved.show = false)", vim.log.levels.WARN)
		return
	end
	local visible = require("fude.comments").toggle_resolved_visibility()
	vim.notify("fude.nvim: Resolved comments: " .. (visible and "shown" or "hidden"), vim.log.levels.INFO)
end

----------------------------------------------------------------
-- Registry
----------------------------------------------------------------

M.list = {
	-- Session --------------------------------------------------------------
	{
		name = "FudeReviewStart",
		desc = "Start PR review mode",
		category = "Session",
		available = when_inactive,
		run = function()
			require("fude").start()
		end,
	},
	{
		name = "FudeReviewStop",
		desc = "Stop review mode",
		category = "Session",
		available = when_active,
		run = function()
			require("fude").stop()
		end,
	},
	{
		name = "FudeReviewToggle",
		desc = "Toggle PR review mode",
		category = "Session",
		available = always,
		palette = false, -- Start/Stop already cover both states
		run = function()
			require("fude").toggle()
		end,
	},
	{
		name = "FudeReviewLocal",
		desc = "Start local (pre-PR) review mode against a base ref",
		category = "Session",
		available = when_inactive,
		nargs = "?",
		run = function(opts)
			require("fude.local.session").start(opts.args ~= "" and opts.args or nil)
		end,
	},
	{
		name = "FudeReviewLocalToggle",
		desc = "Toggle local (pre-PR) review mode against a base ref",
		category = "Session",
		available = always,
		palette = false, -- Local/Stop already cover both states
		nargs = "?",
		run = function(opts)
			require("fude.local.session").toggle(opts.args ~= "" and opts.args or nil)
		end,
	},
	{
		name = "FudeReviewReload",
		desc = "Reload review data",
		category = "Session",
		available = when_active,
		run = function()
			require("fude").reload()
		end,
	},

	-- Comments -------------------------------------------------------------
	{
		name = "FudeReviewComment",
		desc = "Create review comment",
		category = "Comments",
		available = when_active,
		range = true,
		run = function(opts)
			require("fude.comments").create_comment(opts.range > 0)
		end,
	},
	{
		name = "FudeReviewSuggest",
		desc = "Suggest change on current line/selection",
		category = "Comments",
		available = when_active,
		range = true,
		run = function(opts)
			require("fude.comments").suggest_change(opts.range > 0)
		end,
	},
	{
		name = "FudeReviewViewComment",
		desc = "View review comments on current line",
		category = "Comments",
		available = when_active,
		run = function()
			require("fude.comments").view_comments()
		end,
	},
	{
		name = "FudeReviewListComments",
		desc = "List review comments",
		category = "Comments",
		available = when_active,
		run = function()
			require("fude.comments").list_comments()
		end,
	},
	{
		name = "FudeReviewResolve",
		desc = "Toggle resolved status of the comment thread on the current line",
		category = "Comments",
		available = when_active,
		run = function()
			require("fude.comments").toggle_resolve()
		end,
	},

	-- Files ----------------------------------------------------------------
	{
		name = "FudeReviewFiles",
		desc = "List changed files",
		category = "Files",
		available = when_active,
		run = function()
			require("fude.files").show()
		end,
	},
	{
		name = "FudeReviewNextFile",
		desc = "Move to next changed file",
		category = "Files",
		available = when_active,
		run = function()
			require("fude.files").next_file()
		end,
	},
	{
		name = "FudeReviewPrevFile",
		desc = "Move to previous changed file",
		category = "Files",
		available = when_active,
		run = function()
			require("fude.files").prev_file()
		end,
	},
	{
		name = "FudeReviewNextUnviewedFile",
		desc = "Move to next unviewed changed file",
		category = "Files",
		available = when_active,
		run = function()
			require("fude.files").next_unviewed_file()
		end,
	},
	{
		name = "FudeReviewPrevUnviewedFile",
		desc = "Move to previous unviewed changed file",
		category = "Files",
		available = when_active,
		run = function()
			require("fude.files").prev_unviewed_file()
		end,
	},
	{
		name = "FudeReviewViewed",
		desc = "Mark current file as viewed",
		category = "Files",
		available = when_active,
		run = function()
			require("fude").mark_viewed()
		end,
	},
	{
		name = "FudeReviewUnviewed",
		desc = "Unmark current file as viewed",
		category = "Files",
		available = when_active,
		run = function()
			require("fude").unmark_viewed()
		end,
	},

	-- Scope ----------------------------------------------------------------
	{
		name = "FudeReviewScope",
		desc = "Select review scope (full PR / commit, or the local scope picker)",
		category = "Scope",
		available = when_active,
		run = function()
			require("fude.scope").select_scope()
		end,
	},
	{
		name = "FudeReviewScopeNext",
		desc = "Move to next review scope",
		category = "Scope",
		available = when_active,
		run = function()
			require("fude.scope").next_scope()
		end,
	},
	{
		name = "FudeReviewScopePrev",
		desc = "Move to previous review scope",
		category = "Scope",
		available = when_active,
		run = function()
			require("fude.scope").prev_scope()
		end,
	},
	{
		name = "FudeReviewStackSwitch",
		desc = "Switch the review to another PR of the stack",
		category = "Scope",
		available = when_github,
		run = function()
			require("fude.stack").select_stack()
		end,
	},
	{
		name = "FudeReviewLocalScope",
		desc = "Select local review scope (base / unpushed / uncommitted / commit)",
		category = "Scope",
		available = when_local,
		nargs = "?",
		complete = function()
			return require("fude.local.session").SCOPES
		end,
		run = function(opts)
			local session = require("fude.local.session")
			-- "commit" needs a target SHA, which only the picker can supply.
			if opts.args ~= "" and opts.args ~= "commit" then
				session.set_scope(opts.args)
			else
				session.select_scope()
			end
		end,
	},

	-- Review ---------------------------------------------------------------
	{
		name = "FudeReviewSubmit",
		desc = "Submit review",
		category = "Review",
		available = when_github,
		run = submit_review,
	},

	-- View -----------------------------------------------------------------
	{
		name = "FudeReviewDiff",
		desc = "Toggle diff preview",
		category = "View",
		available = when_active,
		run = function()
			require("fude").toggle_diff()
		end,
	},
	{
		name = "FudeReviewPanel",
		desc = "Toggle review side panel (focus it when open, close it when focused)",
		category = "View",
		available = when_active,
		run = function()
			require("fude.ui.sidepanel").toggle()
		end,
	},
	{
		name = "FudeReviewToggleFileTree",
		desc = "Toggle review side panel file list between flat and tree",
		category = "View",
		available = when_active,
		run = function()
			require("fude.ui.sidepanel").toggle_file_tree_mode()
		end,
	},
	{
		name = "FudeReviewToggleCommentStyle",
		desc = "Toggle comment display style (virtualText/inline)",
		category = "View",
		available = when_active,
		run = toggle_comment_style,
	},
	{
		name = "FudeReviewToggleResolved",
		desc = "Toggle visibility of resolved comments in the editor",
		category = "View",
		available = when_active,
		run = toggle_resolved,
	},
	{
		name = "FudeReviewToggleGitsigns",
		desc = "Toggle gitsigns between review base and HEAD",
		category = "View",
		available = when_active,
		run = function()
			require("fude").toggle_gitsigns()
		end,
	},

	-- PR -------------------------------------------------------------------
	{
		name = "FudeReviewOverview",
		desc = "Show PR overview",
		category = "PR",
		available = when_github,
		run = function()
			require("fude.overview").show()
		end,
	},
	{
		name = "FudeOpenPRURL",
		desc = "Open PR in browser",
		category = "PR",
		available = always,
		run = function()
			get_pr_url(function(url)
				vim.ui.open(url)
			end)
		end,
	},
	{
		name = "FudeCopyPRURL",
		desc = "Copy PR URL to clipboard",
		category = "PR",
		available = always,
		run = function()
			get_pr_url(function(url)
				vim.fn.setreg("+", url)
				vim.notify("fude.nvim: Copied " .. url, vim.log.levels.INFO)
			end)
		end,
	},
	{
		name = "FudeCreatePR",
		desc = "Create draft PR from template",
		category = "PR",
		available = always,
		run = function()
			require("fude.pr").create()
		end,
	},
	{
		name = "FudeEditPR",
		desc = "Edit PR title and body",
		category = "PR",
		available = always,
		run = function()
			require("fude.pr").edit()
		end,
	},
}

--- Register every registry entry as a user command.
--- Kept here (not in plugin/fude.lua) so tests can re-run it and so the
--- attribute mapping (`range`/`nargs`/`complete`) lives next to the data.
function M.register_all()
	for _, cmd in ipairs(M.list) do
		vim.api.nvim_create_user_command(cmd.name, cmd.run, {
			desc = cmd.desc,
			range = cmd.range,
			nargs = cmd.nargs,
			complete = cmd.complete,
		})
	end
end

return M
