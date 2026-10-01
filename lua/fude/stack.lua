local config = require("fude.config")

local M = {}

-- True while `gh pr checkout` runs with the review stopped: a review started
-- then would read the branch mid-switch, and the checkout callback starts one
local checking_out = false

--- Whether a PR switch is checking out its branch (review start must wait).
--- @return boolean
function M.is_switching()
	return checking_out
end

--- Refuse a review start while a PR switch is checking out its branch.
--- @return boolean refused true (after a WARN) when the caller must not start
function M.refuse_while_switching()
	if not M.is_switching() then
		return false
	end
	vim.notify("fude.nvim: A PR switch is checking out its branch; try again when it finishes", vim.log.levels.WARN)
	return true
end

--- Build picker entries for the PRs of a stack.
--- Merged/closed PRs cannot be reviewed and are left out, except the current PR
--- so the picker always shows where the review is. `[i/n]` is the position in
--- the whole stack (as GitHub shows it), so it does not shift as PRs merge.
--- @param prs table[] `gh.parse_pr_stack` result (bottom first)
--- @param current_number number|nil PR under review
--- @return table[] { number, head_ref, is_current, display_text }[]
function M.build_stack_entries(prs, current_number)
	local entries = {}
	for i, pr in ipairs(prs) do
		if pr.state == "OPEN" or pr.number == current_number then
			table.insert(entries, {
				number = pr.number,
				head_ref = pr.head_ref,
				is_current = pr.number == current_number,
				display_text = string.format(
					"[%d/%d] #%d %s (%s ← %s)",
					i,
					#prs,
					pr.number,
					pr.title,
					pr.base_ref,
					pr.head_ref
				),
			})
		end
	end
	return entries
end

--- Decide how to reach `branch` from the current worktree.
--- @param worktrees table[] `diff.parse_worktree_list` result (paths comparable with current_root)
--- @param current_root string current worktree root
--- @param branch string target head branch
--- @return table { kind = "current" } | { kind = "switch" } | { kind = "cd", path = string }
function M.resolve_switch_target(worktrees, current_root, branch)
	for _, wt in ipairs(worktrees) do
		if wt.branch == branch then
			if wt.path == current_root then
				return { kind = "current" }
			end
			return { kind = "cd", path = wt.path }
		end
	end
	return { kind = "switch" }
end

--- Whether `path` is `root` itself or inside it (`/repo-other` is not under `/repo`).
--- @param path string
--- @param root string
--- @return boolean
function M.is_path_under(path, root)
	root = root:gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- The worktree root that owns `path`: the deepest root containing it, since
--- worktrees can be nested (e.g. `.claude/worktrees/x` inside the main worktree).
--- @param path string
--- @param roots string[]
--- @return string|nil
function M.find_owning_root(path, roots)
	local owner
	for _, root in ipairs(roots) do
		if M.is_path_under(path, root) and (not owner or #root > #owner) then
			owner = root
		end
	end
	return owner
end

--- File buffers owned by the worktree at `root` (not by a worktree nested in it).
--- @param root string resolved worktree root
--- @param roots string[] resolved roots of all worktrees, including `root`
--- @return integer[]
local function buffers_of(root, roots)
	local bufs = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if vim.bo[buf].buftype == "" and name ~= "" and M.find_owning_root(vim.fn.resolve(name), roots) == root then
			table.insert(bufs, buf)
		end
	end
	return bufs
end

--- Point every window showing one of `old_buffers` at the same file under
--- `new_root` (an empty buffer when it does not exist there), so wiping the old
--- buffers keeps the window layout.
--- @param old_buffers integer[]
--- @param old_root string
--- @param new_root string
local function retarget_windows(old_buffers, old_root, new_root)
	local old = {}
	for _, buf in ipairs(old_buffers) do
		old[buf] = true
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if old[buf] then
			local rel = vim.fn.resolve(vim.api.nvim_buf_get_name(buf)):sub(#old_root + 2)
			local counterpart = new_root .. "/" .. rel
			vim.api.nvim_win_call(win, function()
				if rel ~= "" and vim.fn.filereadable(counterpart) == 1 then
					pcall(vim.cmd, "edit " .. vim.fn.fnameescape(counterpart))
				else
					pcall(vim.cmd, "enew")
				end
			end)
		end
	end
end

--- Switch the review to another PR of the stack.
--- Case 1 (branch is HEAD here): nothing to do. Case 2 (branch checked out
--- nowhere): `gh pr checkout` in this worktree. Case 3 (branch checked out in
--- another worktree): `:cd` there and wipe this worktree's buffers, keeping
--- their windows on the same file in the new worktree. Cases 2/3
--- restart the review; every refusal happens before the review is stopped.
--- @param entry table `build_stack_entries` entry
function M.switch_to(entry)
	if entry.is_current then
		return
	end
	local diff = require("fude.diff")
	local root = diff.get_repo_root()
	local worktrees, wt_err = diff.get_worktrees()
	if not root or not worktrees then
		vim.notify("fude.nvim: Failed to list worktrees: " .. vim.trim(wt_err or ""), vim.log.levels.ERROR)
		return
	end
	root = vim.fn.resolve(root)
	-- The current worktree is missing from `worktrees` while detached (commit scope)
	local roots = { root }
	for _, wt in ipairs(worktrees) do
		wt.path = vim.fn.resolve(wt.path)
		table.insert(roots, wt.path)
	end

	local target = M.resolve_switch_target(worktrees, root, entry.head_ref)
	if target.kind == "current" then
		vim.notify("fude.nvim: " .. entry.head_ref .. " is already checked out here", vim.log.levels.INFO)
		return
	end

	local old_buffers = buffers_of(root, roots)
	for _, buf in ipairs(old_buffers) do
		if vim.bo[buf].modified then
			vim.notify(
				"fude.nvim: Unsaved buffers in " .. root .. ". Save or discard them before switching PR.",
				vim.log.levels.WARN
			)
			return
		end
	end

	if target.kind == "switch" then
		-- Untracked files are left to git: checkout refuses to overwrite them.
		local status = vim.system({ "git", "status", "--porcelain", "--untracked-files=no" }, { text = true }):wait()
		if status.code ~= 0 then
			vim.notify("fude.nvim: Failed to check git status: " .. (status.stderr or ""), vim.log.levels.ERROR)
			return
		end
		if status.stdout ~= "" then
			vim.notify(
				"fude.nvim: Uncommitted changes detected. Please commit or stash before switching PR.",
				vim.log.levels.WARN
			)
			return
		end
	elseif vim.fn.isdirectory(target.path) == 0 then
		vim.notify(
			"fude.nvim: Worktree not found: " .. target.path .. " (run `git worktree prune` if it was deleted)",
			vim.log.levels.WARN
		)
		return
	end

	-- Captured before stop() resets the state; the checkout failure path returns here
	local restore_ref = config.state.original_head_ref or config.state.original_head_sha
	local init = require("fude")
	init.stop()
	-- stop() reports and keeps the session when it cannot restore HEAD
	if config.state.active then
		return
	end

	if target.kind == "cd" then
		local ok, cd_err = pcall(vim.cmd, "cd " .. vim.fn.fnameescape(target.path))
		if not ok then
			vim.notify(
				"fude.nvim: Failed to cd to " .. target.path .. ": " .. tostring(cd_err) .. ". Resuming the review here.",
				vim.log.levels.ERROR
			)
		else
			retarget_windows(old_buffers, root, target.path)
			for _, buf in ipairs(old_buffers) do
				pcall(vim.api.nvim_buf_delete, buf, {})
			end
		end
		init.start()
		return
	end

	vim.notify("fude.nvim: Checking out PR #" .. entry.number .. "...", vim.log.levels.INFO)
	checking_out = true
	require("fude.gh").checkout_pr(entry.number, function(err)
		checking_out = false
		if err then
			vim.notify("fude.nvim: Failed to check out PR #" .. entry.number .. ": " .. vim.trim(err), vim.log.levels.ERROR)
		end
		-- gh may have switched to an existing local branch before failing
		-- (e.g. `merge --ff-only` after a stack rebase), so go back explicitly
		local restored = true
		if err and restore_ref then
			local result = vim.system({ "git", "checkout", restore_ref }, { text = true }):wait()
			if result.code ~= 0 then
				restored = false
				vim.notify(
					"fude.nvim: Failed to restore "
						.. restore_ref
						.. ": "
						.. vim.trim(result.stderr or "")
						.. ". The review stays stopped; check out "
						.. restore_ref
						.. " manually.",
					vim.log.levels.ERROR
				)
			end
		end
		-- Reload buffers whose files changed on disk with the branch
		pcall(vim.cmd, "checktime")
		-- After a failed restore HEAD may still be on the target branch, so a
		-- start would review a PR other than the one the user is told about
		if restored then
			init.start()
		end
	end)
end

--- @param entries table[]
--- @param on_select fun(entry: table)
function M.show_vim_select(entries, on_select)
	vim.ui.select(entries, {
		prompt = "PR Stack:",
		format_item = function(entry)
			return (entry.is_current and "▶" or " ") .. " " .. entry.display_text
		end,
	}, function(choice)
		if choice then
			on_select(choice)
		end
	end)
end

--- @param entries table[]
--- @param on_select fun(entry: table)
function M.show_telescope(entries, on_select)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(entries, on_select)
		return
	end
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new(
			require("telescope.themes").get_dropdown({
				previewer = false,
				layout_config = { height = require("fude.pr").calculate_compact_picker_height(#entries) },
			}),
			{
				prompt_title = "PR Stack",
				finder = finders.new_table({
					results = entries,
					entry_maker = function(entry)
						return {
							value = entry,
							display = (entry.is_current and "▶" or " ") .. " " .. entry.display_text,
							ordinal = entry.display_text,
						}
					end,
				}),
				sorter = conf.generic_sorter({}),
				attach_mappings = function(prompt_bufnr)
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						if selection then
							on_select(selection.value)
						end
					end)
					return true
				end,
			}
		)
		:find()
end

--- @param entries table[]
--- @param on_select fun(entry: table)
function M.show_snacks(entries, on_select)
	local has_snacks, snacks_picker = pcall(require, "snacks.picker")
	if not has_snacks then
		vim.notify("fude.nvim: snacks.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(entries, on_select)
		return
	end
	for _, entry in ipairs(entries) do
		entry.text = entry.display_text
	end
	snacks_picker.pick({
		source = "fude_pr_stack",
		title = "PR Stack",
		items = entries,
		layout = { preset = "select" },
		format = function(item, _)
			return {
				{ (item.is_current and "▶" or " ") .. " ", item.is_current and "DiagnosticInfo" or "Comment" },
				{ item.display_text },
			}
		end,
		confirm = function(picker, item)
			picker:close()
			if item then
				on_select(item)
			end
		end,
	})
end

--- Show the PRs of the current PR's stack and switch the review to the selected one.
function M.select_stack()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end
	if state.review_mode == "local" then
		vim.notify("fude.nvim: PR stack is not available in local review mode", vim.log.levels.WARN)
		return
	end

	require("fude.gh").get_pr_stack(state.pr_number, function(err, prs)
		if config.state ~= state then
			return
		end
		if err then
			vim.notify("fude.nvim: Failed to fetch PR stack: " .. vim.trim(err), vim.log.levels.ERROR)
			return
		end
		local entries = M.build_stack_entries(prs or {}, state.pr_number)
		if #entries == 0 then
			vim.notify("fude.nvim: PR #" .. state.pr_number .. " is not in a stack", vim.log.levels.INFO)
			return
		end

		local function on_select(entry)
			-- The review may have been stopped or restarted while the picker was open
			if config.state ~= state or not state.active then
				return
			end
			M.switch_to(entry)
		end
		if config.opts.file_list_mode == "telescope" then
			M.show_telescope(entries, on_select)
		elseif config.opts.file_list_mode == "snacks" then
			M.show_snacks(entries, on_select)
		else
			M.show_vim_select(entries, on_select)
		end
	end)
end

return M
