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

		-- Fetch viewed file states
		gh_mod.get_pr_viewed_files(state.pr_number, function(viewed_err, viewed_map, pr_node_id)
			if not viewed_err and viewed_map then
				state.viewed_files = viewed_map
				state.pr_node_id = pr_node_id
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

		local comments_mod = require("reviewit.comments")
		comments_mod.fetch_comments()
		comments_mod.fetch_pending_review()

		state.augroup = vim.api.nvim_create_augroup("Reviewit", { clear = true })

		vim.api.nvim_create_autocmd("BufEnter", {
			group = state.augroup,
			callback = function()
				vim.schedule(function()
					require("reviewit.ui").refresh_extmarks()
					M.setup_buf_keymaps()
				end)
			end,
			desc = "reviewit.nvim: Update extmarks and keymaps",
		})

		-- Set keymaps on the current buffer immediately
		M.setup_buf_keymaps()
	end)
end

--- Set buffer-local keymaps for the current buffer during review mode.
function M.setup_buf_keymaps()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype ~= "" then
		return
	end
	local km = config.opts.keymaps
	if km.next_comment then
		vim.keymap.set("n", km.next_comment, function()
			require("reviewit.comments").next_comment()
		end, { buffer = buf, desc = "Review: Next comment" })
	end
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			require("reviewit.comments").prev_comment()
		end, { buffer = buf, desc = "Review: Prev comment" })
	end
end

--- Remove buffer-local review keymaps from all loaded buffers.
function M.clear_buf_keymaps()
	local km = config.opts.keymaps
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			if km.next_comment then
				pcall(vim.keymap.del, "n", km.next_comment, { buffer = buf })
			end
			if km.prev_comment then
				pcall(vim.keymap.del, "n", km.prev_comment, { buffer = buf })
			end
		end
	end
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
	M.clear_buf_keymaps()

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

--- Mark the current file as viewed on GitHub.
function M.mark_viewed()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if not state.pr_node_id then
		vim.notify("reviewit.nvim: PR node ID not available yet", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("reviewit.diff")
	local rel_path = diff_mod.to_repo_relative(vim.api.nvim_buf_get_name(0))
	if not rel_path then
		vim.notify("reviewit.nvim: Cannot determine file path", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("reviewit.gh")
	gh_mod.mark_file_viewed(state.pr_node_id, rel_path, function(err)
		if err then
			vim.notify("reviewit.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[rel_path] = "VIEWED"
		vim.notify("reviewit.nvim: Marked as viewed: " .. rel_path, vim.log.levels.INFO)
	end)
end

--- Unmark the current file as viewed on GitHub.
function M.unmark_viewed()
	local state = config.state
	if not state.active then
		vim.notify("reviewit.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if not state.pr_node_id then
		vim.notify("reviewit.nvim: PR node ID not available yet", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("reviewit.diff")
	local rel_path = diff_mod.to_repo_relative(vim.api.nvim_buf_get_name(0))
	if not rel_path then
		vim.notify("reviewit.nvim: Cannot determine file path", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("reviewit.gh")
	gh_mod.unmark_file_viewed(state.pr_node_id, rel_path, function(err)
		if err then
			vim.notify("reviewit.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[rel_path] = "UNVIEWED"
		vim.notify("reviewit.nvim: Unmarked as viewed: " .. rel_path, vim.log.levels.INFO)
	end)
end

--- Check if review mode is active.
--- @return boolean
function M.is_active()
	return config.state.active
end

return M
