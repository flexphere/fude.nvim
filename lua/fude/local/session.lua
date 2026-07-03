--- Local (pre-PR) review session lifecycle.
---
--- Runs the existing review UI against a local git diff instead of a GitHub
--- PR: changed files come from `git diff <merge-base>` (plus untracked files),
--- comments live in an append-only JSONL store under `.fude/` (see
--- `fude.local.store`). No GitHub interaction happens in this mode.
---
--- Parallel to `fude.init` M.start/M.stop/M.reload (deliberately similar in
--- shape); shared pieces (autocmds, gitsigns base, keymaps) are reused via
--- exported `fude.init` helpers.
local M = {}
local config = require("fude.config")
local store = require("fude.local.store")

-- === Pure functions ===

--- Map a git status letter (from --name-status) to the GitHub-style word
--- used across the plugin ("added" | "modified" | "removed" | "renamed" | "copied").
--- @param letter string e.g. "A", "M", "D", "R100"
--- @return string
function M.status_word(letter)
	local head = letter:sub(1, 1)
	local words = { A = "added", M = "modified", D = "removed", R = "renamed", C = "copied" }
	return words[head] or "modified"
end

--- Resolve a numstat/rename path expression to the new path.
--- Handles "old => new" and brace forms like "lua/{old => new}/mod.lua".
--- @param path_expr string
--- @return string new path
function M.resolve_rename_path(path_expr)
	local prefix, old, new, suffix = path_expr:match("^(.-){(.-) => (.-)}(.*)$")
	if prefix then
		local _ = old
		return (prefix .. new .. suffix):gsub("//", "/")
	end
	local plain_new = path_expr:match("^.* => (.+)$")
	if plain_new then
		return plain_new
	end
	return path_expr
end

--- Parse `git diff --name-status -M` output.
--- @param output string|nil
--- @return table[] entries { path, status }
function M.parse_name_status(output)
	local entries = {}
	if not output or output == "" then
		return entries
	end
	for line in output:gmatch("[^\n]+") do
		local letter, rest = line:match("^(%S+)\t(.+)$")
		if letter and rest then
			local path = rest
			if letter:sub(1, 1) == "R" or letter:sub(1, 1) == "C" then
				-- "R100\told\tnew" — the review target is the new path
				local _, new = rest:match("^(.-)\t(.+)$")
				if new then
					path = new
				end
			end
			table.insert(entries, { path = path, status = M.status_word(letter) })
		end
	end
	return entries
end

--- Parse `git diff --numstat -M` output into a path -> counts map.
--- Binary files ("-\t-\tpath") get zero counts.
--- @param output string|nil
--- @return table<string, { additions: number, deletions: number }>
function M.parse_numstat(output)
	local counts = {}
	if not output or output == "" then
		return counts
	end
	for line in output:gmatch("[^\n]+") do
		local add, del, path_expr = line:match("^(%S+)\t(%S+)\t(.+)$")
		if path_expr then
			local path = M.resolve_rename_path(path_expr)
			counts[path] = {
				additions = tonumber(add) or 0,
				deletions = tonumber(del) or 0,
			}
		end
	end
	return counts
end

--- Build the changed_files array (same shape as the GitHub flow) from local
--- git output. Untracked files are appended as "added" with zero counts.
--- @param name_status_out string|nil `git diff --name-status -M` output
--- @param numstat_out string|nil `git diff --numstat -M` output
--- @param untracked_out string|nil `git ls-files --others --exclude-standard` output
--- @return table[] changed files { path, status, additions, deletions }
function M.build_changed_files(name_status_out, numstat_out, untracked_out)
	local counts = M.parse_numstat(numstat_out)
	local files = {}
	local seen = {}
	for _, entry in ipairs(M.parse_name_status(name_status_out)) do
		local c = counts[entry.path] or {}
		table.insert(files, {
			path = entry.path,
			status = entry.status,
			additions = c.additions or 0,
			deletions = c.deletions or 0,
		})
		seen[entry.path] = true
	end
	if untracked_out then
		for path in untracked_out:gmatch("[^\n]+") do
			if path ~= "" and not seen[path] then
				table.insert(files, { path = path, status = "added", additions = 0, deletions = 0 })
				seen[path] = true
			end
		end
	end
	return files
end

-- === Session helpers ===

--- Refresh state.changed_files from local git.
--- @param state table config.state
local function load_changed_files_into_state(state)
	local diff_mod = require("fude.diff")
	local base_sha = state.local_session and state.local_session.base_sha
	if not base_sha then
		return
	end
	state.changed_files =
		M.build_changed_files(diff_mod.get_name_status(base_sha), diff_mod.get_numstat(base_sha), diff_mod.get_untracked())
end

--- Stop the auto-reload timer if running.
local function stop_reload_timer()
	local timer = config.state.reload_timer
	if timer then
		timer:stop()
		timer:close()
		config.state.reload_timer = nil
	end
end

--- Start the auto-reload timer if configured (mirrors fude.init).
local function start_reload_timer()
	local auto_reload = config.opts.auto_reload
	if not auto_reload or not auto_reload.enabled then
		return
	end
	stop_reload_timer()
	local interval = math.max(10, tonumber(auto_reload.interval) or 30) * 1000
	local timer = vim.uv.new_timer()
	timer:start(
		interval,
		interval,
		vim.schedule_wrap(function()
			if config.state.active and config.state.review_mode == "local" then
				M.reload(not auto_reload.notify)
			end
		end)
	)
	config.state.reload_timer = timer
end

-- === Lifecycle ===

--- Start a local review session against a base ref.
--- Resumes the session recorded in `.fude/current.json` when one exists for
--- this worktree; otherwise creates a new session file.
--- @param base_arg string|nil base ref (default: repository default branch)
function M.start(base_arg)
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

	local existing = store.read_current(repo_root)
	if existing and existing.worktree_root ~= repo_root then
		existing = nil
	end

	local base_ref = base_arg
	if base_ref == nil or base_ref == "" then
		base_ref = existing and existing.base_ref or diff_mod.get_default_branch()
	end
	if not base_ref then
		vim.notify("fude.nvim: Cannot determine base ref (pass one: :FudeReviewLocal <base>)", vim.log.levels.ERROR)
		return
	end

	if existing and existing.base_ref ~= base_ref then
		vim.notify(
			string.format(
				"fude.nvim: Resuming existing local session (base: %s). Run :FudeReviewLocalStop to start over.",
				existing.base_ref
			),
			vim.log.levels.WARN
		)
		base_ref = existing.base_ref
	end

	local base_sha = diff_mod.get_merge_base(base_ref)
	if not base_sha then
		vim.notify("fude.nvim: Cannot resolve merge-base for " .. base_ref, vim.log.levels.ERROR)
		return
	end

	local head_sha = diff_mod.get_head_sha()
	local branch = diff_mod.get_current_branch()
	local now = os.time()

	local session
	if existing then
		session = existing
		session.file = store.session_file(repo_root, session.id)
	else
		local id = store.make_session_id(now)
		session = {
			id = id,
			file = store.session_file(repo_root, id),
			base_ref = base_ref,
			base_sha = base_sha,
			head_sha = head_sha,
			branch = branch,
			worktree_root = repo_root,
		}
		local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
		local ok, err = store.append_event(
			session.file,
			store.build_session_event({
				id = id,
				base_ref = base_ref,
				base_sha = base_sha,
				head_sha = head_sha,
				branch = branch,
				worktree_root = repo_root,
				created_at = created_at,
			})
		)
		if not ok then
			vim.notify("fude.nvim: Failed to create session file: " .. (err or "?"), vim.log.levels.ERROR)
			return
		end
		store.write_current(repo_root, {
			id = id,
			base_ref = base_ref,
			base_sha = base_sha,
			head_sha = head_sha,
			branch = branch,
			worktree_root = repo_root,
			created_at = created_at,
		})
	end

	state.active = true
	state.review_mode = "local"
	state.local_session = session
	state.base_ref = base_ref
	state.head_ref = branch or "HEAD"
	state.merge_base_sha = base_sha
	state.github_user = diff_mod.get_git_user()

	load_changed_files_into_state(state)
	require("fude.comments.local_sync").load_comments(nil, { silent = true })

	-- Apply diffopt settings (same as the GitHub flow)
	if config.opts.diffopt then
		state.original_diffopt = vim.o.diffopt
		for _, opt in ipairs(config.opts.diffopt) do
			vim.opt.diffopt:append(opt)
		end
	end

	local init = require("fude")
	init.setup_review_autocmds(state)
	require("fude.ui").refresh_extmarks()
	start_reload_timer()

	vim.notify(
		string.format(
			"fude.nvim: Local review %s (%s <- %s, %d files, %d comments)",
			existing and "resumed" or "started",
			base_ref,
			state.head_ref,
			#state.changed_files,
			#state.comments
		),
		vim.log.levels.INFO
	)
end

--- Stop the local review session and clear the current-session pointer.
function M.stop()
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		vim.notify("fude.nvim: No local review session", vim.log.levels.INFO)
		return
	end

	stop_reload_timer()

	if state.augroup then
		vim.api.nvim_del_augroup_by_id(state.augroup)
	end

	require("fude.ui.sidepanel").close()
	require("fude.preview").close_preview()
	require("fude.ui").clear_all_extmarks()
	require("fude.ui").teardown_inline_hint_autocmd()
	require("fude").clear_buf_keymaps()

	local has_gitsigns, gitsigns = pcall(require, "gitsigns")
	if has_gitsigns then
		gitsigns.reset_base(true)
	end

	if state.original_diffopt then
		vim.o.diffopt = state.original_diffopt
	end

	local session = state.local_session
	if session and session.worktree_root then
		store.clear_current(session.worktree_root)
	end

	config.reset_state()
	vim.notify("fude.nvim: Local review stopped", vim.log.levels.INFO)
end

--- Re-read the session JSONL and local git state (synchronous).
--- Picks up events appended by external writers (AI agents).
--- @param silent boolean|nil suppress completion notification when true
function M.reload(silent)
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		if not silent then
			vim.notify("fude.nvim: No local review session", vim.log.levels.WARN)
		end
		return
	end
	if state.reloading then
		return
	end
	state.reloading = true

	local ok, err = pcall(function()
		load_changed_files_into_state(state)
		require("fude.comments.local_sync").load_comments(nil, { silent = true })
		require("fude.ui.sidepanel").refresh()
	end)
	state.reloading = false
	if not ok then
		vim.notify("fude.nvim: Local reload failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	if not silent then
		vim.notify("fude.nvim: Reloaded local review data", vim.log.levels.INFO)
	end
end

return M
