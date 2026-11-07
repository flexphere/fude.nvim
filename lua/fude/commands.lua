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
---   repeatable boolean|nil      `false` keeps the command out of `:FudeCommandRepeat`
local config = require("fude.config")

local M = {}

--- The last registry command run (`{ name, fargs, bang }`), repeated by
--- `:FudeCommandRepeat`. Module-local rather than `config.state`, so it
--- survives a review stop / start.
local last_command = nil

--- The last command `:FudeCommandRepeat` would run, or nil.
--- @return table|nil { name, fargs, bang }
function M.get_last()
	return last_command
end

--- Forget the last command (tests).
function M._reset_last()
	last_command = nil
end

--- Record a run of `cmd` with the user-command `opts`, unless the entry is
--- `repeatable = false`. The range is not recorded: a repeat acts on the
--- cursor line, or on the range `:FudeCommandRepeat` itself was given.
--- @param cmd table registry entry
--- @param opts table|nil nvim_create_user_command callback opts
function M.record(cmd, opts)
	if cmd.repeatable == false then
		return
	end
	opts = opts or {}
	local fargs = {}
	for _, arg in ipairs(opts.fargs or {}) do
		table.insert(fargs, arg)
	end
	last_command = { name = cmd.name, fargs = fargs, bang = opts.bang == true }
end

--- Build the `vim.cmd` table that repeats `last`: the same command and
--- arguments, plus `range` (`{ line1, line2 }`) only when the command takes
--- one (`takes_range`). Pure.
--- @param last table|nil { name, fargs, bang }
--- @param range number[]|nil
--- @param takes_range boolean|nil
--- @return table|nil
function M.build_repeat_cmd(last, range, takes_range)
	if type(last) ~= "table" or type(last.name) ~= "string" then
		return nil
	end
	local cmd = { cmd = last.name }
	if type(last.fargs) == "table" and #last.fargs > 0 then
		cmd.args = {}
		for _, arg in ipairs(last.fargs) do
			table.insert(cmd.args, arg)
		end
	end
	if last.bang then
		cmd.bang = true
	end
	if takes_range and range then
		cmd.range = { range[1], range[2] }
	end
	return cmd
end

--- Find a registry entry by command name.
--- @param name string
--- @return table|nil
function M.find(name)
	for _, cmd in ipairs(M.list) do
		if cmd.name == name then
			return cmd
		end
	end
	return nil
end

--- Run the last recorded command again (`:FudeCommandRepeat`). A range given
--- to the repeat is forwarded to a range command (`:'<,'>FudeCommandRepeat`).
--- @param opts table|nil user-command opts
function M.repeat_last(opts)
	opts = opts or {}
	local last = last_command
	if not last then
		vim.notify("fude.nvim: No command to repeat yet", vim.log.levels.INFO)
		return
	end
	local entry = M.find(last.name)
	local range = (opts.range or 0) > 0 and { opts.line1, opts.line2 } or nil
	local cmd = M.build_repeat_cmd(last, range, entry ~= nil and entry.range == true)
	local ok, err = pcall(vim.cmd, cmd)
	if not ok then
		vim.notify("fude.nvim: " .. tostring(err), vim.log.levels.ERROR)
	end
end

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
	local drafts = require("fude.drafts")

	-- Step 1: Select review event type
	ui.select_review_event(function(event)
		if not event then
			return
		end

		local draft_key = drafts.current_key("review")
		local draft_body = drafts.get(draft_key)

		-- Step 2: Input review body (optional)
		ui.open_comment_input(function(body, action)
			if action == "draft" then
				-- Saving a draft pauses the submit; the review is not sent.
				drafts.set(draft_key, body)
				vim.notify("fude.nvim: Draft saved (review not submitted)", vim.log.levels.INFO)
				return
			elseif action == "discard" then
				drafts.remove(draft_key)
			elseif action == "cancel" and draft_body then
				-- Closing an unedited restored draft is not dirty, so no prompt was
				-- shown; submitting here would send the review without the saved
				-- body and then delete it. Keep the draft and stop instead.
				vim.notify("fude.nvim: Review not submitted (draft kept)", vim.log.levels.INFO)
				return
			end
			-- Step 3: Submit review. "cancel"/"discard" skip the body as before.
			-- The input is already closed, so :FudeReviewSubmit can be reopened
			-- and a new draft saved while the request is in flight; keep that one.
			local draft_snapshot = drafts.revision(draft_key)
			comments.submit_as_review(event, body, function(err)
				if err then
					vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
					return
				end
				drafts.remove_if_unchanged(draft_key, draft_snapshot)
				vim.notify("fude.nvim: Review submitted", vim.log.levels.INFO)
			end)
		end, {
			title = " Review Body (optional) ",
			footer = " <CR> submit | q skip body ",
			initial_lines = draft_body and vim.split(require("fude.ui.format").normalize_newlines(draft_body), "\n") or nil,
			allow_draft = draft_key ~= nil and drafts.enabled(),
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
		name = "FudeCommandRepeat",
		desc = "Repeat the last fude command",
		category = "Session",
		available = always,
		range = true,
		repeatable = false,
		run = function(opts)
			M.repeat_last(opts)
		end,
	},
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
		desc = "Select review scope (entire PR / commit, or the local scope picker)",
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
	{
		name = "FudeReviewLocalBase",
		desc = "Change the base branch of the local review",
		category = "Scope",
		available = when_local,
		nargs = "?",
		complete = function()
			-- The reviewed worktree, not Neovim's cwd, which a `:cd` may have moved.
			local session = require("fude.config").state.local_session
			return require("fude.diff").get_remote_branches(session and session.worktree_root)
		end,
		run = function(opts)
			local session = require("fude.local.session")
			if opts.args ~= "" then
				session.set_base(opts.args)
			else
				session.select_base()
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
	{
		name = "FudeEditReviewers",
		desc = "Request or remove reviewers of the PR",
		category = "PR",
		available = always,
		run = function()
			require("fude.overview").edit_current_reviewers()
		end,
	},
	{
		name = "FudeEditLabels",
		desc = "Add or remove labels of the PR",
		category = "PR",
		available = always,
		run = function()
			require("fude.overview").edit_current_labels()
		end,
	},
	{
		name = "FudeChangePRState",
		desc = "Change PR state (ready for review / draft / close / reopen)",
		category = "PR",
		available = always,
		run = function()
			require("fude.pr").change_state()
		end,
	},
}

--- Register every registry entry as a user command.
--- Kept here (not in plugin/fude.lua) so tests can re-run it and so the
--- attribute mapping (`range`/`nargs`/`complete`) lives next to the data.
function M.register_all()
	for _, cmd in ipairs(M.list) do
		vim.api.nvim_create_user_command(cmd.name, function(opts)
			M.record(cmd, opts)
			cmd.run(opts)
		end, {
			desc = cmd.desc,
			range = cmd.range,
			nargs = cmd.nargs,
			complete = cmd.complete,
		})
	end
end

return M
