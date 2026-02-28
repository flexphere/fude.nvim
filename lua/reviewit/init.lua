local M = {}
local config = require("reviewit.config")

--- Setup the plugin with user options.
--- @param opts table|nil user configuration
function M.setup(opts)
	config.setup(opts)
end

--- Start review mode for the current branch's PR.
function M.start()
	local state = config.state
	if state.active then
		vim.notify("reviewit.nvim: Already active", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("reviewit.diff")
	local repo_root = diff_mod.get_repo_root()
	if not repo_root then
		vim.notify("reviewit.nvim: Not in a git repository", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("reviewit.gh")
	vim.notify("reviewit.nvim: Detecting PR...", vim.log.levels.INFO)

	gh_mod.get_pr_info(function(err, pr_info)
		if err then
			vim.notify("reviewit.nvim: No PR found for current branch. " .. (err or ""), vim.log.levels.ERROR)
			return
		end

		state.active = true
		state.pr_number = pr_info.number
		state.base_ref = pr_info.baseRefName
		state.head_ref = pr_info.headRefName
		state.pr_url = pr_info.url

		vim.notify(
			string.format("reviewit.nvim: PR #%d (%s <- %s)", state.pr_number, state.base_ref, state.head_ref),
			vim.log.levels.INFO
		)

		gh_mod.get_pr_files(state.pr_number, function(files_err, files)
			if not files_err and files then
				state.changed_files = {}
				for _, f in ipairs(files) do
					table.insert(state.changed_files, {
						path = f.filename,
						status = f.status,
						additions = f.additions,
						deletions = f.deletions,
						patch = f.patch,
					})
				end
			end
		end)

		-- Apply diffopt settings
		if config.opts.diffopt then
			state.original_diffopt = vim.o.diffopt
			for _, opt in ipairs(config.opts.diffopt) do
				vim.opt.diffopt:append(opt)
			end
		end

		-- Switch gitsigns base to PR base branch
		local has_gitsigns, gitsigns = pcall(require, "gitsigns")
		if has_gitsigns then
			gitsigns.change_base(state.base_ref, true)
		end

		require("reviewit.comments").fetch_comments()

		state.augroup = vim.api.nvim_create_augroup("Reviewit", { clear = true })

		vim.api.nvim_create_autocmd("BufEnter", {
			group = state.augroup,
			callback = function()
				vim.schedule(function()
					require("reviewit.ui").refresh_extmarks()
				end)
			end,
			desc = "reviewit.nvim: Update extmarks",
		})
	end)
end

--- Toggle diff preview window.
function M.toggle_diff()
	if not config.state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end
	local preview = require("reviewit.preview")
	if config.state.preview_win and vim.api.nvim_win_is_valid(config.state.preview_win) then
		preview.close_preview()
	else
		preview.open_preview(vim.api.nvim_get_current_win())
	end
end

--- Stop review mode and clean up.
function M.stop()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.INFO)
		return
	end

	if state.augroup then
		vim.api.nvim_del_augroup_by_id(state.augroup)
	end

	require("reviewit.preview").close_preview()
	require("reviewit.ui").clear_all_extmarks()

	-- Reset gitsigns back to default (HEAD)
	local has_gitsigns, gitsigns = pcall(require, "gitsigns")
	if has_gitsigns then
		gitsigns.reset_base(true)
	end

	-- Restore original diffopt
	if state.original_diffopt then
		vim.o.diffopt = state.original_diffopt
	end

	local pr_number = state.pr_number
	config.reset_state()

	vim.notify("reviewit.nvim: Stopped (PR #" .. (pr_number or "?") .. ")", vim.log.levels.INFO)
end

--- Toggle review mode.
function M.toggle()
	if config.state.active then
		M.stop()
	else
		M.start()
	end
end

--- Check if review mode is active.
--- @return boolean
function M.is_active()
	return config.state.active
end

return M
