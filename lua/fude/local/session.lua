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
	local prefix, new, suffix = path_expr:match("^(.-){.- => (.-)}(.*)$")
	if prefix then
		return ((prefix .. new .. suffix):gsub("//", "/"))
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
--- Whether a repo-relative path is one of the plugin's own review-store
--- artifacts (`.fude/...`), which must never appear as a reviewable change
--- regardless of the repo's .gitignore.
--- @param path string repo-relative path
--- @return boolean
function M.is_store_path(path)
	return path == ".fude" or path:sub(1, 6) == ".fude/"
end

function M.build_changed_files(name_status_out, numstat_out, untracked_out)
	local counts = M.parse_numstat(numstat_out)
	local files = {}
	local seen = {}
	for _, entry in ipairs(M.parse_name_status(name_status_out)) do
		if not M.is_store_path(entry.path) then
			local c = counts[entry.path] or {}
			table.insert(files, {
				path = entry.path,
				status = entry.status,
				additions = c.additions or 0,
				deletions = c.deletions or 0,
			})
			seen[entry.path] = true
		end
	end
	if untracked_out then
		for path in untracked_out:gmatch("[^\n]+") do
			if path ~= "" and not seen[path] and not M.is_store_path(path) then
				table.insert(files, { path = path, status = "added", additions = 0, deletions = 0 })
				seen[path] = true
			end
		end
	end
	return files
end

-- === Session helpers ===

--- Scope labels understood by the local session.
M.SCOPES = { "base", "uncommitted" }

--- Resolve the diff base for a local review scope.
---   "base"        → merge-base with the base branch (the whole branch diff)
---   "uncommitted" → HEAD (only staged + unstaged working-tree changes)
--- `diff_base` is the ref passed to `git diff` (used for the changed-files
--- list and per-file patches); `content_ref` is the ref passed to `git show`
--- for the side-by-side preview's base pane.
--- @param scope string "base"|"uncommitted"
--- @param base_ref string the session's base branch
--- @return string|nil diff_base, string|nil content_ref
function M.resolve_scope_base(scope, base_ref)
	local diff_mod = require("fude.diff")
	if scope == "uncommitted" then
		-- Literal HEAD so the view always reflects the current commit, even
		-- after the user commits mid-session.
		return "HEAD", "HEAD"
	end
	local merge_base = diff_mod.get_merge_base(base_ref)
	if not merge_base then
		return nil, nil
	end
	return merge_base, base_ref
end

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
	-- A stale pointer whose JSONL was deleted cannot be resumed (the new file
	-- would lack its session header); start a fresh session instead.
	if existing and vim.fn.filereadable(store.session_file(repo_root, existing.id)) == 0 then
		existing = nil
	end

	local base_ref = base_arg
	if base_ref == nil or base_ref == "" then
		base_ref = existing and existing.base_ref or diff_mod.get_default_branch()
	end

	if existing and base_ref and existing.base_ref ~= base_ref then
		vim.notify(
			string.format(
				"fude.nvim: Resuming existing local session (base: %s). Run :FudeReviewLocalStop to start over.",
				existing.base_ref
			),
			vim.log.levels.WARN
		)
		base_ref = existing.base_ref
	end

	local head_sha = diff_mod.get_head_sha()
	local branch = diff_mod.get_current_branch()
	local now = os.time()

	-- Determine the initial scope. When no base branch can be found (a fresh,
	-- remote-less repo of agent work), fall back to reviewing the uncommitted
	-- working-tree changes instead of failing.
	local initial_scope = (existing and existing.scope) or "base"
	local no_base_fallback = false
	if not base_ref and initial_scope == "base" then
		initial_scope = "uncommitted"
		no_base_fallback = true
	end

	if initial_scope == "uncommitted" and not head_sha then
		vim.notify("fude.nvim: No commits yet — nothing to review", vim.log.levels.ERROR)
		return
	end

	local base_sha, content_ref = M.resolve_scope_base(initial_scope, base_ref)
	if not base_sha then
		vim.notify("fude.nvim: Cannot resolve base ref for " .. (base_ref or "?"), vim.log.levels.ERROR)
		return
	end

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

	-- The session's diff base is derived from the scope so
	-- :FudeReviewLocalScope can switch it later. Refresh base_sha/content_ref on
	-- resume too (a resumed session's stored base_sha may be stale).
	session.scope = initial_scope
	session.base_sha = base_sha
	session.content_ref = content_ref

	state.active = true
	state.review_mode = "local"
	state.local_session = session
	state.base_ref = base_ref
	state.head_ref = branch or "HEAD"
	state.merge_base_sha = base_sha
	state.github_user = diff_mod.get_git_user()

	if no_base_fallback then
		vim.notify(
			"fude.nvim: No base branch found — reviewing uncommitted changes. "
				.. "Pass a base (:FudeReviewLocal <ref>) or switch scope in the panel.",
			vim.log.levels.INFO
		)
	end

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

	-- Local-only autocmds: keep tracking extmarks in sync and write drifted
	-- comment positions back to the JSONL store on save.
	local tracker = require("fude.local.tracker")
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = state.augroup,
		callback = function(ev)
			tracker.on_buf_write(ev.buf)
		end,
		desc = "fude.nvim: Re-anchor local review comments after save",
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
		group = state.augroup,
		callback = function(ev)
			local bufnr = ev.buf
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
					return
				end
				local rel_path = require("fude.diff").to_repo_relative(vim.api.nvim_buf_get_name(bufnr))
				if rel_path then
					tracker.sync_buffer(bufnr, rel_path)
				end
			end)
		end,
		desc = "fude.nvim: Track local review comments in opened buffers",
	})
	tracker.sync_all()

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
	require("fude.local.tracker").teardown()
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

--- Switch the local review scope and refresh everything derived from the diff
--- base (changed files, per-file patches, gitsigns base, side-by-side preview).
--- Comments are unaffected — they anchor to the working tree, which does not
--- change with the scope.
--- @param scope string "base"|"uncommitted"
function M.set_scope(scope)
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		vim.notify("fude.nvim: No local review session", vim.log.levels.WARN)
		return
	end
	if not vim.tbl_contains(M.SCOPES, scope) then
		vim.notify("fude.nvim: Unknown local scope: " .. tostring(scope), vim.log.levels.WARN)
		return
	end
	local session = state.local_session
	if session.scope == scope then
		return
	end

	local diff_base, content_ref = M.resolve_scope_base(scope, session.base_ref)
	if not diff_base then
		vim.notify("fude.nvim: Failed to resolve base for scope: " .. scope, vim.log.levels.ERROR)
		return
	end

	session.scope = scope
	session.base_sha = diff_base
	session.content_ref = content_ref
	state.merge_base_sha = diff_base

	load_changed_files_into_state(state)
	require("fude.comments.local_sync").load_comments(nil, { silent = true })
	require("fude.ui.sidepanel").refresh()

	-- Re-apply gitsigns base (local mode uses the full_pr code path with
	-- merge_base_sha) and refresh an open side-by-side preview.
	require("fude").restore_gitsigns_base()
	local src = state.source_win
	if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
		require("fude.preview").close_preview()
		if src and vim.api.nvim_win_is_valid(src) then
			require("fude.preview").open_preview(src)
		end
	end

	vim.notify("fude.nvim: Local scope → " .. scope, vim.log.levels.INFO)
end

--- Pick a local review scope via vim.ui.select.
function M.select_scope()
	local state = config.state
	if not state.active or state.review_mode ~= "local" then
		vim.notify("fude.nvim: No local review session", vim.log.levels.WARN)
		return
	end
	local current = state.local_session.scope
	local labels = {
		base = "Base branch (whole branch diff)",
		uncommitted = "Uncommitted only (staged + unstaged)",
	}
	local items = {}
	for _, scope in ipairs(M.SCOPES) do
		table.insert(items, scope)
	end
	vim.ui.select(items, {
		prompt = "Local review scope:",
		format_item = function(scope)
			local marker = scope == current and "▶ " or "  "
			return marker .. (labels[scope] or scope)
		end,
	}, function(choice)
		if choice then
			M.set_scope(choice)
		end
	end)
end

return M
