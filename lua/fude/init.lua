local M = {}
local config = require("fude.config")

--- Setup the plugin with user options.
--- @param opts table|nil user configuration
function M.setup(opts)
	config.setup(opts)
end

-- Forward declaration for start_reload_timer (defined after M.reload)
local start_reload_timer

--- Stop the auto-reload timer if running.
local function stop_reload_timer()
	local timer = config.state.reload_timer
	if timer then
		timer:stop()
		timer:close()
		config.state.reload_timer = nil
	end
end

--- Start review mode for the current branch's PR.
function M.start()
	local state = config.state
	if state.active then
		vim.notify("fude.nvim: Already active", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("fude.diff")
	local repo_root = diff_mod.get_repo_root()
	if not repo_root then
		vim.notify("fude.nvim: Not in a git repository", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("fude.gh")
	vim.notify("fude.nvim: Detecting PR...", vim.log.levels.INFO)

	gh_mod.get_pr_info(function(err, pr_info)
		if err then
			vim.notify("fude.nvim: No PR found for current branch. " .. (err or ""), vim.log.levels.ERROR)
			return
		end

		state.active = true
		state.pr_number = pr_info.number
		state.base_ref = pr_info.baseRefName
		state.head_ref = pr_info.headRefName
		state.pr_url = pr_info.url

		if pr_info.state and pr_info.state:upper() == "MERGED" then
			vim.notify("fude.nvim: This PR has already been merged", vim.log.levels.WARN)
		end

		vim.notify(
			string.format("fude.nvim: PR #%d (%s <- %s)", state.pr_number, state.base_ref, state.head_ref),
			vim.log.levels.INFO
		)

		-- Save original HEAD ref (branch name) and SHA for scope restoration
		-- Prefer restoring by branch name to avoid leaving the user in detached HEAD
		local head_sha, _ = gh_mod.get_head_sha()
		state.original_head_sha = head_sha

		local ref_result = vim.system({ "git", "symbolic-ref", "--quiet", "--short", "HEAD" }, { text = true }):wait()
		if ref_result.code == 0 and ref_result.stdout and vim.trim(ref_result.stdout) ~= "" then
			state.original_head_ref = vim.trim(ref_result.stdout)
		end

		-- Detect detached HEAD: start with commit scope automatically
		local started_detached = state.original_head_ref == nil

		-- Completion barrier: fire on_review_start after all async fetches complete
		-- 5 async fetches: files, get_pr_commits, get_pr_viewed_files, get_authenticated_user, load_comments
		local remaining = 5
		local function on_ready()
			remaining = remaining - 1
			if remaining > 0 then
				return
			end
			-- Guard: session may have been stopped or replaced while fetches were in flight
			-- NOTE: `state` is the table captured at M.start() time. If `config.reset_state()`
			-- has been called (e.g. via M.stop()), `config.state` will point to a different
			-- table, so we must ensure both "active" and "same state table" to treat this as
			-- the same session.
			if not (config.state.active and config.state == state) then
				return
			end
			-- Set commit scope if started in detached HEAD
			if started_detached and state.original_head_sha then
				state.scope = "commit"
				state.scope_commit_sha = state.original_head_sha
				state.scope_commit_index = require("fude.scope").find_commit_index(state.pr_commits, state.original_head_sha)
			end
			if config.opts.on_review_start then
				local ok, cb_err = pcall(config.opts.on_review_start, {
					pr_number = state.pr_number,
					base_ref = state.base_ref,
					head_ref = state.head_ref,
					pr_url = state.pr_url,
				})
				if not ok then
					vim.notify("fude.nvim: on_review_start error: " .. tostring(cb_err), vim.log.levels.ERROR)
				end
			end
			-- Start auto-reload timer after all initial data is loaded
			start_reload_timer()
		end

		-- Fetch changed files: commit-specific when detached, PR-wide otherwise
		if started_detached and state.original_head_sha then
			gh_mod.get_commit_files(state.original_head_sha, function(files_err, files)
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
				on_ready()
			end)
		else
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
				on_ready()
			end)
		end

		-- Fetch PR commits for scope selection
		gh_mod.get_pr_commits(state.pr_number, function(commits_err, commits)
			if not commits_err and commits then
				state.pr_commits = commits
			end
			on_ready()
		end)

		-- Fetch viewed file states
		gh_mod.get_pr_viewed_files(state.pr_number, function(viewed_err, viewed_map, pr_node_id)
			if not viewed_err and viewed_map then
				state.viewed_files = viewed_map
				state.pr_node_id = pr_node_id
			end
			on_ready()
		end)

		-- Apply diffopt settings
		if config.opts.diffopt then
			state.original_diffopt = vim.o.diffopt
			for _, opt in ipairs(config.opts.diffopt) do
				vim.opt.diffopt:append(opt)
			end
		end

		-- Switch gitsigns base: commit parent when detached, PR base branch otherwise
		local has_gitsigns, gitsigns = pcall(require, "gitsigns")
		if has_gitsigns then
			if started_detached and state.original_head_sha then
				gitsigns.change_base(state.original_head_sha .. "^", true)
			else
				gitsigns.change_base(state.base_ref, true)
			end
		end

		-- Fetch authenticated user for ownership checks
		gh_mod.get_authenticated_user(function(user_err, login)
			if not user_err and login then
				state.github_user = login
			end
			on_ready()
		end)

		local comments_mod = require("fude.comments")
		comments_mod.load_comments(on_ready)

		state.augroup = vim.api.nvim_create_augroup("Fude", { clear = true })

		vim.api.nvim_create_autocmd("BufEnter", {
			group = state.augroup,
			callback = function()
				vim.schedule(function()
					require("fude.ui").refresh_extmarks()
					M.setup_buf_keymaps()
				end)
			end,
			desc = "fude.nvim: Update extmarks and keymaps",
		})

		vim.api.nvim_create_autocmd("WinResized", {
			group = state.augroup,
			callback = function()
				vim.schedule(function()
					require("fude.ui").refresh_extmarks()
				end)
			end,
			desc = "fude.nvim: Update extmarks on window resize",
		})

		-- Set keymaps on the current buffer immediately
		M.setup_buf_keymaps()

		-- Setup hint autocmd for comment lines (shows available actions)
		require("fude.ui").setup_inline_hint_autocmd()
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
			require("fude.comments").next_comment()
		end, { buffer = buf, desc = "Review: Next comment" })
	end
	if km.prev_comment then
		vim.keymap.set("n", km.prev_comment, function()
			require("fude.comments").prev_comment()
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
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	local preview = require("fude.preview")
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
		vim.notify("fude.nvim: Not active", vim.log.levels.INFO)
		return
	end

	-- Stop auto-reload timer
	stop_reload_timer()

	if state.augroup then
		vim.api.nvim_del_augroup_by_id(state.augroup)
	end

	require("fude.preview").close_preview()
	require("fude.ui").clear_all_extmarks()
	require("fude.ui").teardown_inline_hint_autocmd()
	M.clear_buf_keymaps()

	-- Restore original HEAD if in commit scope
	if state.scope == "commit" and (state.original_head_ref or state.original_head_sha) then
		local checkout_target = state.original_head_ref or state.original_head_sha
		local result = vim.system({ "git", "checkout", checkout_target }, { text = true }):wait()
		if result.code ~= 0 then
			vim.notify(
				"fude.nvim: Failed to restore HEAD: " .. (result.stderr or "") .. " — manual checkout may be needed",
				vim.log.levels.ERROR
			)
			return
		end
	end

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

	vim.notify("fude.nvim: Stopped (PR #" .. (pr_number or "?") .. ")", vim.log.levels.INFO)
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
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if not state.pr_node_id then
		vim.notify("fude.nvim: PR node ID not available yet", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("fude.diff")
	local rel_path = diff_mod.to_repo_relative(vim.api.nvim_buf_get_name(0))
	if not rel_path then
		vim.notify("fude.nvim: Cannot determine file path", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("fude.gh")
	gh_mod.mark_file_viewed(state.pr_node_id, rel_path, function(err)
		if err then
			vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[rel_path] = "VIEWED"
		vim.notify("fude.nvim: Marked as viewed: " .. rel_path, vim.log.levels.INFO)
	end)
end

--- Unmark the current file as viewed on GitHub.
function M.unmark_viewed()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if not state.pr_node_id then
		vim.notify("fude.nvim: PR node ID not available yet", vim.log.levels.WARN)
		return
	end

	local diff_mod = require("fude.diff")
	local rel_path = diff_mod.to_repo_relative(vim.api.nvim_buf_get_name(0))
	if not rel_path then
		vim.notify("fude.nvim: Cannot determine file path", vim.log.levels.ERROR)
		return
	end

	local gh_mod = require("fude.gh")
	gh_mod.unmark_file_viewed(state.pr_node_id, rel_path, function(err)
		if err then
			vim.notify("fude.nvim: " .. err, vim.log.levels.ERROR)
			return
		end
		state.viewed_files[rel_path] = "UNVIEWED"
		vim.notify("fude.nvim: Unmarked as viewed: " .. rel_path, vim.log.levels.INFO)
	end)
end

--- Reload review data from GitHub (comments, files, viewed state, commits).
--- @param silent boolean|nil suppress completion notification when true
function M.reload(silent)
	if not config.state.active then
		if not silent then
			vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		end
		return
	end
	if config.state.reloading then
		return
	end
	config.state.reloading = true

	-- Capture state table identity to detect reset_state() across callbacks
	local captured_state = config.state
	local session_pr = captured_state.pr_number

	local gh_mod = require("fude.gh")

	-- 5 async fetches: comments, files, viewed, commits, pr_state
	local remaining = 5
	local function on_done()
		remaining = remaining - 1
		if remaining > 0 then
			return
		end
		-- State table replaced by reset_state(): do not touch new session
		if config.state ~= captured_state then
			return
		end
		-- Always clear reloading flag before any early return
		config.state.reloading = false
		-- Session boundary check: abort if session changed during reload
		if config.state.pr_number ~= session_pr then
			return
		end
		if not config.state.active then
			return
		end
		-- Recalculate scope_commit_index when in commit scope (commits list may have changed)
		if config.state.scope == "commit" and config.state.scope_commit_sha then
			config.state.scope_commit_index =
				require("fude.scope").find_commit_index(config.state.pr_commits, config.state.scope_commit_sha)
		end
		if not silent then
			vim.notify("fude.nvim: Reloaded review data", vim.log.levels.INFO)
		end
	end

	-- Check if PR has been merged
	gh_mod.run_json({
		"pr",
		"view",
		tostring(config.state.pr_number),
		"--json",
		"state",
	}, function(err, data)
		if
			not silent
			and not err
			and data
			and data.state
			and data.state:upper() == "MERGED"
			and config.state == captured_state
			and config.state.active
		then
			vim.notify("fude.nvim: This PR has already been merged", vim.log.levels.WARN)
		end
		on_done()
	end)

	-- Reload comments (includes pending review detection)
	require("fude.comments").load_comments(on_done, { silent = true })

	-- Reload changed files
	if config.state.scope == "commit" and config.state.scope_commit_sha then
		gh_mod.get_commit_files(config.state.scope_commit_sha, function(err, files)
			if not err and files and config.state == captured_state and config.state.active then
				config.state.changed_files = {}
				for _, f in ipairs(files) do
					table.insert(config.state.changed_files, {
						path = f.filename,
						status = f.status,
						additions = f.additions,
						deletions = f.deletions,
						patch = f.patch,
					})
				end
			end
			on_done()
		end)
	else
		gh_mod.get_pr_files(config.state.pr_number, function(err, files)
			if not err and files and config.state == captured_state and config.state.active then
				config.state.changed_files = {}
				for _, f in ipairs(files) do
					table.insert(config.state.changed_files, {
						path = f.filename,
						status = f.status,
						additions = f.additions,
						deletions = f.deletions,
						patch = f.patch,
					})
				end
			end
			on_done()
		end)
	end

	-- Reload viewed file states
	gh_mod.get_pr_viewed_files(config.state.pr_number, function(err, viewed_map, pr_node_id)
		if not err and viewed_map and config.state == captured_state and config.state.active then
			config.state.viewed_files = viewed_map
			config.state.pr_node_id = pr_node_id
		end
		on_done()
	end)

	-- Reload PR commits
	gh_mod.get_pr_commits(config.state.pr_number, function(err, commits)
		if not err and commits and config.state == captured_state and config.state.active then
			config.state.pr_commits = commits
		end
		on_done()
	end)
end

--- Start the auto-reload timer if configured.
start_reload_timer = function()
	local auto_reload = config.opts.auto_reload
	if not auto_reload or not auto_reload.enabled then
		return
	end
	-- Stop any existing timer to prevent double-start leaks
	stop_reload_timer()
	local interval = math.max(10, tonumber(auto_reload.interval) or 30) * 1000
	local timer = vim.uv.new_timer()
	timer:start(
		interval,
		interval,
		vim.schedule_wrap(function()
			if config.state.active then
				M.reload(not auto_reload.notify)
			end
		end)
	)
	config.state.reload_timer = timer
end

--- Check if review mode is active.
--- @return boolean
function M.is_active()
	return config.state.active
end

return M
