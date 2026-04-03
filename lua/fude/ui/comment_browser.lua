local M = {}
local config = require("fude.config")
local format = require("fude.ui.format")
local data = require("fude.comments.data")

-- Lazy requires (circular dependency prevention)
local function get_ui()
	return require("fude.ui")
end
local function get_comments()
	return require("fude.comments")
end
local function get_sync()
	return require("fude.comments.sync")
end
local function get_gh()
	return require("fude.gh")
end

--- Close the comment browser and clean up all windows.
local function close_browser()
	local state = config.state
	local browser = state.comment_browser
	if not browser or browser.closing then
		return
	end
	browser.closing = true

	pcall(vim.api.nvim_win_close, browser.left_win, true)
	pcall(vim.api.nvim_win_close, browser.upper_win, true)
	pcall(vim.api.nvim_win_close, browser.lower_win, true)

	if browser.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, browser.augroup)
	end

	state.comment_browser = nil
end

--- Get text from lower buffer.
--- @param buf number buffer handle
--- @return string
local function get_lower_text(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return vim.trim(table.concat(lines, "\n"))
end

--- Update the right panes for the given entry.
--- @param browser table comment_browser state
--- @param entry table entry from build_comment_browser_entries
--- @param all_comments table[] flat array of all review comments
--- @param all_issue_comments table[] all PR-level issue comments
local function update_right_panes(browser, entry, all_comments, all_issue_comments)
	if not browser or browser.closing then
		return
	end

	-- Format thread for upper pane
	local result = format.format_comment_browser_thread(entry, all_comments, all_issue_comments, config.format_date)

	-- Update upper buffer
	if vim.api.nvim_buf_is_valid(browser.upper_buf) then
		vim.bo[browser.upper_buf].modifiable = true
		vim.api.nvim_buf_set_lines(browser.upper_buf, 0, -1, false, result.lines)
		vim.bo[browser.upper_buf].modifiable = false

		-- Apply highlights
		local ns = config.state.ns_id or vim.api.nvim_create_namespace("fude")
		vim.api.nvim_buf_clear_namespace(browser.upper_buf, ns, 0, -1)
		for _, hl in ipairs(result.hl_ranges) do
			if hl.col_start and hl.col_end then
				pcall(vim.api.nvim_buf_add_highlight, browser.upper_buf, ns, hl.hl, hl.line, hl.col_start, hl.col_end)
			else
				pcall(vim.api.nvim_buf_add_highlight, browser.upper_buf, ns, hl.hl, hl.line, 0, -1)
			end
		end
	end

	-- Set lower pane mode and title based on entry type
	if entry.type == "issue" then
		browser.mode = "new_pr_comment"
		if vim.api.nvim_win_is_valid(browser.lower_win) then
			pcall(vim.api.nvim_win_set_config, browser.lower_win, { title = " New PR Comment ", title_pos = "center" })
		end
	else
		browser.mode = "reply"
		if vim.api.nvim_win_is_valid(browser.lower_win) then
			pcall(vim.api.nvim_win_set_config, browser.lower_win, { title = " Reply ", title_pos = "center" })
		end
	end

	-- Clear lower buffer and reset edit target (skip if user has typed content)
	local lower_has_content = false
	if vim.api.nvim_buf_is_valid(browser.lower_buf) then
		lower_has_content = get_lower_text(browser.lower_buf) ~= ""
	end
	if not browser.edit_target and not lower_has_content then
		if vim.api.nvim_buf_is_valid(browser.lower_buf) then
			vim.api.nvim_buf_set_lines(browser.lower_buf, 0, -1, false, { "" })
		end
	end
	browser.edit_target = nil
end

--- Create the 3-pane browser windows.
--- @param entries table[] from build_comment_browser_entries
--- @param issue_comments table[] PR-level issue comments
local function create_browser(entries, issue_comments)
	local state = config.state

	-- Close existing browser/reply windows
	close_browser()
	if state.reply_window and state.reply_window.upper_win then
		pcall(vim.api.nvim_win_close, state.reply_window.upper_win, true)
		pcall(vim.api.nvim_win_close, state.reply_window.lower_win, true)
		state.reply_window = nil
	end

	get_ui().setup_reply_highlights()

	-- Calculate layout
	local ov = config.opts.overview or {}
	local layout = format.calculate_comment_browser_layout(vim.o.columns, vim.o.lines, ov.width or 80, ov.height or 80)

	-- Format left pane
	local list_result =
		format.format_comment_browser_list(entries, 0, config.format_date, config.opts.outdated, config.format_path)

	-- Create left buffer (readonly list)
	local left_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, list_result.lines)
	vim.bo[left_buf].modifiable = false
	vim.bo[left_buf].buftype = "nofile"
	vim.bo[left_buf].bufhidden = "wipe"

	-- Create upper buffer (readonly thread)
	local upper_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[upper_buf].modifiable = false
	vim.bo[upper_buf].buftype = "nofile"
	vim.bo[upper_buf].bufhidden = "wipe"
	vim.bo[upper_buf].filetype = "markdown"

	-- Create lower buffer (editable input)
	local lower_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, { "" })
	vim.bo[lower_buf].buftype = "nofile"
	vim.bo[lower_buf].bufhidden = "wipe"
	vim.bo[lower_buf].filetype = "markdown"
	vim.b[lower_buf].fude_comment = true

	-- Border definitions
	local border = config.opts.float.border or "single"

	-- Open left window (focused)
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		row = layout.left.row,
		col = layout.left.col,
		width = layout.left.width,
		height = layout.left.height,
		style = "minimal",
		border = border,
		title = string.format(" Threads (%d) ", #entries),
		title_pos = "center",
		footer = " <CR> jump | R refresh | <Tab> switch | q close ",
		footer_pos = "center",
	})
	vim.wo[left_win].cursorline = true
	vim.wo[left_win].wrap = false

	-- Open upper window (thread, not focused)
	local upper_win = vim.api.nvim_open_win(upper_buf, false, {
		relative = "editor",
		row = layout.right_upper.row,
		col = layout.right_upper.col,
		width = layout.right_upper.width,
		height = layout.right_upper.height,
		style = "minimal",
		border = border,
		title = " Comments ",
		title_pos = "center",
		footer = " e edit | d delete | <Tab> switch | q close ",
		footer_pos = "center",
	})
	vim.wo[upper_win].wrap = true
	vim.wo[upper_win].cursorline = false

	-- Open lower window (input, not focused)
	local lower_win = vim.api.nvim_open_win(lower_buf, false, {
		relative = "editor",
		row = layout.right_lower.row,
		col = layout.right_lower.col,
		width = layout.right_lower.width,
		height = layout.right_lower.height,
		style = "minimal",
		border = border,
		title = " Reply ",
		title_pos = "center",
		footer = " <CR> submit | q cancel | <Tab> switch | <C-u/d> scroll ",
		footer_pos = "center",
	})

	-- Apply left pane highlights
	local ns = state.ns_id or vim.api.nvim_create_namespace("fude")
	for _, hl in ipairs(list_result.hl_ranges) do
		if hl.col_start and hl.col_end then
			pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, hl.col_start, hl.col_end)
		else
			pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, 0, -1)
		end
	end

	-- Save browser state
	local browser = {
		left_win = left_win,
		left_buf = left_buf,
		upper_win = upper_win,
		upper_buf = upper_buf,
		lower_win = lower_win,
		lower_buf = lower_buf,
		entries = entries,
		issue_comments = issue_comments,
		current_entry_idx = 0,
		closing = false,
		mode = "reply", -- "reply" | "edit" | "new_pr_comment"
		augroup = nil,
	}
	state.comment_browser = browser

	-- WinClosed autocmd
	local augroup = vim.api.nvim_create_augroup("fude_comment_browser_" .. left_win, { clear = true })
	browser.augroup = augroup
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			local closed_win = tonumber(ev.match)
			if closed_win == left_win or closed_win == upper_win or closed_win == lower_win then
				close_browser()
			end
		end,
	})

	-- Show first entry
	if #entries > 0 then
		browser.current_entry_idx = 1
		update_right_panes(browser, entries[1], state.comments or {}, issue_comments)
	end

	-- CursorMoved handler on left pane
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = augroup,
		buffer = left_buf,
		callback = function()
			if not vim.api.nvim_win_is_valid(left_win) then
				return
			end
			local cursor_line = vim.api.nvim_win_get_cursor(left_win)[1]
			if cursor_line < 1 or cursor_line > #entries then
				return
			end
			if cursor_line == browser.current_entry_idx then
				return
			end
			browser.current_entry_idx = cursor_line
			update_right_panes(browser, entries[cursor_line], state.comments or {}, issue_comments)
		end,
	})

	-- Helper to scroll upper window
	local function scroll_upper(keys)
		local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
		return function()
			if vim.api.nvim_win_is_valid(upper_win) then
				vim.api.nvim_win_call(upper_win, function()
					vim.cmd("normal! " .. termcodes)
				end)
			end
		end
	end

	-- Helper: get current entry
	local function current_entry()
		local idx = browser.current_entry_idx
		if idx >= 1 and idx <= #entries then
			return entries[idx]
		end
		return nil
	end

	-- Refresh the browser (re-fetch and rebuild)
	local function refresh()
		get_gh().get_issue_comments(state.pr_number, function(err, new_issue_comments)
			if err then
				new_issue_comments = {}
			end
			local diff = require("fude.diff")
			local repo_root = diff.get_repo_root()
			if not repo_root then
				return
			end
			local new_entries = data.build_comment_browser_entries(
				state.comment_map,
				new_issue_comments,
				repo_root,
				config.format_date,
				state.pending_review_id,
				state.github_user,
				state.comments
			)
			if #new_entries == 0 then
				close_browser()
				vim.notify("fude.nvim: No comments found", vim.log.levels.INFO)
				return
			end

			-- Rebuild left pane
			browser.entries = new_entries
			browser.issue_comments = new_issue_comments
			entries = new_entries
			issue_comments = new_issue_comments

			local new_list =
				format.format_comment_browser_list(new_entries, 0, config.format_date, config.opts.outdated, config.format_path)
			if vim.api.nvim_buf_is_valid(left_buf) then
				vim.bo[left_buf].modifiable = true
				vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, new_list.lines)
				vim.bo[left_buf].modifiable = false

				vim.api.nvim_buf_clear_namespace(left_buf, ns, 0, -1)
				for _, hl in ipairs(new_list.hl_ranges) do
					if hl.col_start and hl.col_end then
						pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, hl.col_start, hl.col_end)
					else
						pcall(vim.api.nvim_buf_add_highlight, left_buf, ns, hl.hl, hl.line, 0, -1)
					end
				end
			end

			-- Update title
			if vim.api.nvim_win_is_valid(left_win) then
				pcall(vim.api.nvim_win_set_config, left_win, {
					title = string.format(" Threads (%d) ", #new_entries),
					title_pos = "center",
				})
			end

			-- Clamp cursor
			local new_idx = math.min(browser.current_entry_idx, #new_entries)
			if new_idx < 1 then
				new_idx = 1
			end
			browser.current_entry_idx = new_idx
			if vim.api.nvim_win_is_valid(left_win) then
				pcall(vim.api.nvim_win_set_cursor, left_win, { new_idx, 0 })
			end
			update_right_panes(browser, new_entries[new_idx], state.comments or {}, new_issue_comments)
		end)
	end

	-- Restore lower pane to default state after successful submit
	local function restore_lower_after_submit()
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(lower_buf) then
				vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, { "" })
			end
			browser.edit_target = nil
			local entry = current_entry()
			if entry and entry.type == "issue" then
				browser.mode = "new_pr_comment"
				if vim.api.nvim_win_is_valid(lower_win) then
					pcall(vim.api.nvim_win_set_config, lower_win, { title = " New PR Comment ", title_pos = "center" })
				end
			else
				browser.mode = "reply"
				if vim.api.nvim_win_is_valid(lower_win) then
					pcall(vim.api.nvim_win_set_config, lower_win, { title = " Reply ", title_pos = "center" })
				end
			end
			if vim.api.nvim_win_is_valid(left_win) then
				vim.api.nvim_set_current_win(left_win)
			end
		end)
	end

	-- Restore text to lower buffer on error
	local function restore_lower_text(saved_lines)
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(lower_buf) then
				vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, saved_lines)
			end
		end)
	end

	-- Submit handler for lower pane
	local function submit()
		local body = get_lower_text(lower_buf)
		if body == "" then
			return
		end

		local entry = current_entry()
		if not entry then
			return
		end

		-- Save text for error recovery
		local saved_lines = vim.api.nvim_buf_get_lines(lower_buf, 0, -1, false)

		if browser.mode == "reply" then
			if entry.type == "review" then
				local reply_target_id = data.get_reply_target_id(entry.comments[1].id, state.comment_map or {})
				get_sync().reply_to_comment(reply_target_id, body, function(err)
					if err then
						vim.notify("fude.nvim: Reply failed: " .. err, vim.log.levels.ERROR)
						restore_lower_text(saved_lines)
						return
					end
					vim.notify("fude.nvim: Reply posted", vim.log.levels.INFO)
					restore_lower_after_submit()
					refresh()
				end)
			end
		elseif browser.mode == "edit" then
			local target_comment = browser.edit_target
			if not target_comment then
				return
			end
			if entry.type == "review" then
				local comments_mod = get_comments()
				if comments_mod.is_pending_comment(target_comment) then
					local pending_key = comments_mod.find_pending_key(target_comment.id)
					if pending_key and state.pending_comments[pending_key] then
						state.pending_comments[pending_key].body = body
						get_sync().sync_pending_review(function(err)
							vim.schedule(function()
								if err then
									vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
									restore_lower_text(saved_lines)
								else
									vim.notify("fude.nvim: Pending comment updated", vim.log.levels.INFO)
									restore_lower_after_submit()
								end
								get_ui().refresh_extmarks()
								refresh()
							end)
						end)
					else
						get_sync().edit_comment(target_comment.id, body, function(err)
							if err then
								vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
								restore_lower_text(saved_lines)
								return
							end
							vim.notify("fude.nvim: Comment updated", vim.log.levels.INFO)
							restore_lower_after_submit()
							refresh()
						end)
					end
				else
					get_sync().edit_comment(target_comment.id, body, function(err)
						if err then
							vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
							restore_lower_text(saved_lines)
							return
						end
						vim.notify("fude.nvim: Comment updated", vim.log.levels.INFO)
						restore_lower_after_submit()
						refresh()
					end)
				end
			elseif entry.type == "issue" then
				get_gh().update_issue_comment(target_comment.id, body, function(err, _)
					if err then
						vim.notify("fude.nvim: Edit failed: " .. err, vim.log.levels.ERROR)
						restore_lower_text(saved_lines)
						return
					end
					vim.notify("fude.nvim: Comment updated", vim.log.levels.INFO)
					restore_lower_after_submit()
					refresh()
				end)
			end
		elseif browser.mode == "new_pr_comment" then
			get_gh().create_issue_comment(state.pr_number, body, function(err, _)
				if err then
					vim.notify("fude.nvim: Failed to post comment: " .. err, vim.log.levels.ERROR)
					restore_lower_text(saved_lines)
					return
				end
				vim.notify("fude.nvim: Comment posted", vim.log.levels.INFO)
				restore_lower_after_submit()
				refresh()
			end)
		end

		-- Show submitting state
		if vim.api.nvim_buf_is_valid(lower_buf) then
			vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, { "Submitting..." })
		end
		if vim.api.nvim_win_is_valid(left_win) then
			vim.api.nvim_set_current_win(left_win)
		end
	end

	-- Cancel: clear lower buf, restore default mode, and return to left pane
	local function cancel_lower()
		if vim.api.nvim_buf_is_valid(lower_buf) then
			vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, { "" })
		end
		browser.edit_target = nil
		-- Restore default mode based on current entry
		local entry = current_entry()
		if entry and entry.type == "issue" then
			browser.mode = "new_pr_comment"
			if vim.api.nvim_win_is_valid(lower_win) then
				pcall(vim.api.nvim_win_set_config, lower_win, { title = " New PR Comment ", title_pos = "center" })
			end
		else
			browser.mode = "reply"
			if vim.api.nvim_win_is_valid(lower_win) then
				pcall(vim.api.nvim_win_set_config, lower_win, { title = " Reply ", title_pos = "center" })
			end
		end
		if vim.api.nvim_win_is_valid(left_win) then
			vim.api.nvim_set_current_win(left_win)
		end
	end

	-- === LEFT PANE KEYMAPS ===

	vim.keymap.set("n", "q", close_browser, { buffer = left_buf, desc = "Close comment browser" })

	vim.keymap.set("n", "<CR>", function()
		local entry = current_entry()
		if entry and entry.type == "review" and entry.filename then
			close_browser()
			vim.cmd("edit " .. vim.fn.fnameescape(entry.filename))
			local lnum = math.max(1, entry.lnum or 1)
			pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
			if config.opts.auto_view_comment then
				get_comments().view_comments()
			else
				get_ui().flash_line(lnum)
			end
		end
	end, { buffer = left_buf, desc = "Jump to file" })

	vim.keymap.set("n", "R", function()
		refresh()
	end, { buffer = left_buf, desc = "Refresh" })

	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(upper_win) then
			vim.api.nvim_set_current_win(upper_win)
		end
	end, { buffer = left_buf, desc = "Go to thread pane" })

	-- === UPPER PANE KEYMAPS ===

	vim.keymap.set("n", "q", close_browser, { buffer = upper_buf, desc = "Close" })

	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(lower_win) then
			vim.api.nvim_set_current_win(lower_win)
		end
	end, { buffer = upper_buf, desc = "Go to input pane" })

	vim.keymap.set("n", "<S-Tab>", function()
		if vim.api.nvim_win_is_valid(left_win) then
			vim.api.nvim_set_current_win(left_win)
		end
	end, { buffer = upper_buf, desc = "Go to list pane" })

	vim.keymap.set("n", "e", function()
		local entry = current_entry()
		if not entry then
			return
		end

		-- Find the target comment (last own comment in the thread)
		local target_comment
		for i = #entry.comments, 1, -1 do
			local c = entry.comments[i]
			if c.user and c.user.login == state.github_user then
				target_comment = c
				break
			end
		end
		if not target_comment then
			vim.notify("fude.nvim: No editable comment found", vim.log.levels.WARN)
			return
		end

		-- For review comments, block edit of submitted if pending review exists
		if entry.type == "review" then
			local comments_mod = get_comments()
			if not comments_mod.is_pending_comment(target_comment) and state.pending_review_id then
				vim.notify(
					"fude.nvim: Cannot edit submitted comment while pending review exists. Run :FudeReviewSubmit first.",
					vim.log.levels.WARN
				)
				return
			end
		end

		browser.mode = "edit"
		browser.edit_target = target_comment
		local body_lines = vim.split(format.normalize_newlines(target_comment.body), "\n")
		if vim.api.nvim_buf_is_valid(lower_buf) then
			vim.api.nvim_buf_set_lines(lower_buf, 0, -1, false, body_lines)
		end
		if vim.api.nvim_win_is_valid(lower_win) then
			pcall(vim.api.nvim_win_set_config, lower_win, { title = " Edit Comment ", title_pos = "center" })
			vim.api.nvim_set_current_win(lower_win)
		end
	end, { buffer = upper_buf, desc = "Edit comment" })

	vim.keymap.set("n", "d", function()
		local entry = current_entry()
		if not entry then
			return
		end
		-- Find the target comment (last own comment in the thread)
		local target_comment
		for i = #entry.comments, 1, -1 do
			local c = entry.comments[i]
			if c.user and c.user.login == state.github_user then
				target_comment = c
				break
			end
		end
		if not target_comment then
			vim.notify("fude.nvim: No deletable comment found", vim.log.levels.WARN)
			return
		end

		-- Block delete of submitted review comment if pending review exists
		if entry.type == "review" then
			local comments_mod = get_comments()
			if not comments_mod.is_pending_comment(target_comment) and state.pending_review_id then
				vim.notify(
					"fude.nvim: Cannot delete submitted comment while pending review exists. Run :FudeReviewSubmit first.",
					vim.log.levels.WARN
				)
				return
			end
		end

		vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
			if choice ~= "Yes" then
				return
			end

			if entry.type == "issue" then
				get_gh().delete_issue_comment(target_comment.id, function(err)
					if err then
						vim.notify("fude.nvim: Delete failed: " .. err, vim.log.levels.ERROR)
						return
					end
					vim.notify("fude.nvim: Comment deleted", vim.log.levels.INFO)
					refresh()
				end)
			else
				local comments_mod = get_comments()
				if comments_mod.is_pending_comment(target_comment) then
					local pending_key = comments_mod.find_pending_key(target_comment.id)
					if pending_key then
						state.pending_comments[pending_key] = nil
					end
					get_sync().sync_pending_review(function(err)
						vim.schedule(function()
							if err then
								vim.notify("fude.nvim: Delete failed: " .. err, vim.log.levels.ERROR)
							else
								vim.notify("fude.nvim: Pending comment deleted", vim.log.levels.INFO)
							end
							get_ui().refresh_extmarks()
							refresh()
						end)
					end)
				else
					get_sync().delete_comment(target_comment.id, function(err)
						if err then
							vim.notify("fude.nvim: Delete failed: " .. err, vim.log.levels.ERROR)
							return
						end
						vim.notify("fude.nvim: Comment deleted", vim.log.levels.INFO)
						refresh()
					end)
				end
			end
		end)
	end, { buffer = upper_buf, desc = "Delete comment" })

	-- === LOWER PANE KEYMAPS ===

	vim.keymap.set("n", "<CR>", submit, { buffer = lower_buf, desc = "Submit" })

	vim.keymap.set("n", "q", function()
		cancel_lower()
	end, { buffer = lower_buf, desc = "Cancel" })

	vim.keymap.set("n", "<Esc>", function()
		cancel_lower()
	end, { buffer = lower_buf, desc = "Cancel" })

	vim.keymap.set("n", "<Tab>", function()
		if vim.api.nvim_win_is_valid(left_win) then
			vim.api.nvim_set_current_win(left_win)
		end
	end, { buffer = lower_buf, desc = "Go to list pane" })

	vim.keymap.set(
		{ "n", "i" },
		"<C-u>",
		scroll_upper("<C-u>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread up" }
	)
	vim.keymap.set(
		{ "n", "i" },
		"<C-d>",
		scroll_upper("<C-d>"),
		{ buffer = lower_buf, nowait = true, desc = "Scroll thread down" }
	)
end

--- Open the 3-pane comment browser.
function M.open()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if (not state.comment_map or vim.tbl_isempty(state.comment_map)) and not state.pr_number then
		vim.notify("fude.nvim: No comments found", vim.log.levels.INFO)
		return
	end

	local diff = require("fude.diff")
	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	-- Fetch issue comments, then build entries
	get_gh().get_issue_comments(state.pr_number, function(err, issue_comments)
		if err then
			issue_comments = {}
		end

		local entries = data.build_comment_browser_entries(
			state.comment_map,
			issue_comments,
			repo_root,
			config.format_date,
			state.pending_review_id,
			state.github_user,
			state.comments
		)

		if #entries == 0 then
			vim.notify("fude.nvim: No comments found", vim.log.levels.INFO)
			return
		end

		create_browser(entries, issue_comments)
	end)
end

return M
