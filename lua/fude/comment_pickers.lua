local M = {}
local config = require("fude.config")
local comments = require("fude.comments")
local diff = require("fude.diff")
local ui = require("fude.ui")

--- List all PR review comments in a Telescope picker.
function M.list_comments()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.comment_map or vim.tbl_isempty(state.comment_map) then
		vim.notify("fude.nvim: No comments found", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim required for comment list", vim.log.levels.WARN)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local previewers = require("telescope.previewers")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local date_col_width = #config.format_date("2000-01-01T00:00:00Z")

	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = date_col_width },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		return displayer({
			{ entry.last_date, "Comment" },
			{ entry.detail, "Normal" },
		})
	end

	local entries = {}
	for path, lines in pairs(state.comment_map) do
		for line_key, cmts in pairs(lines) do
			local line = math.floor(tonumber(line_key) or 1)
			local first = cmts[1]
			local last = cmts[#cmts]
			local author = first.user and first.user.login or "unknown"
			local last_ts = last.created_at or ""
			local last_date = config.format_date(last_ts)
			local body_preview = (first.body or ""):gsub("\r?\n", " ")
			if #body_preview > 60 then
				body_preview = body_preview:sub(1, 57) .. "..."
			end
			local detail = string.format("%s:%d  @%s  %s", path, line, author, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s:%d %s", path, line, first.body or ""),
				filename = repo_root .. "/" .. path,
				lnum = line,
				last_ts = last_ts,
				last_date = last_date,
				detail = detail,
				comments = cmts,
				display = make_display,
			})
		end
	end

	table.sort(entries, function(a, b)
		return a.last_ts > b.last_ts
	end)

	pickers
		.new({}, {
			prompt_title = string.format("PR #%d Review Comments", state.pr_number),
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Comment Thread",
				define_preview = function(self, entry)
					local preview_lines = {}
					for _, comment in ipairs(entry.comments) do
						local author = comment.user and comment.user.login or "unknown"
						local date = config.format_date(comment.created_at)
						table.insert(preview_lines, string.format("── @%s (%s) ──", author, date))
						table.insert(preview_lines, "")
						for _, body_line in ipairs(vim.split(comment.body or "", "\n", { trimempty = false })) do
							table.insert(preview_lines, body_line)
						end
						table.insert(preview_lines, "")
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
						local lnum = math.max(1, selection.lnum)
						pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
						if config.opts.auto_view_comment then
							comments.view_comments()
						end
					end
				end)
				return true
			end,
		})
		:find()
end

--- List all draft comments in a Telescope picker.
function M.list_drafts()
	local state = config.state
	if not state.active then
		vim.notify("fude.nvim: Not active", vim.log.levels.WARN)
		return
	end

	if not state.drafts or vim.tbl_isempty(state.drafts) then
		vim.notify("fude.nvim: No drafts", vim.log.levels.INFO)
		return
	end

	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim required for draft list", vim.log.levels.WARN)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local repo_root = diff.get_repo_root()
	if not repo_root then
		return
	end

	local entries = {}
	for key, draft_lines in pairs(state.drafts) do
		local parsed = comments.parse_draft_key(key)
		if not parsed then
			goto continue
		end

		local body_preview = table.concat(draft_lines, " "):gsub("%s+", " ")
		if #body_preview > 60 then
			body_preview = body_preview:sub(1, 57) .. "..."
		end

		if parsed.type == "comment" then
			local range_str = parsed.start_line == parsed.end_line and tostring(parsed.start_line)
				or string.format("%d-%d", parsed.start_line, parsed.end_line)
			local detail = string.format("%s:%s  %s", parsed.path, range_str, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s:%d %s", parsed.path, parsed.start_line, table.concat(draft_lines, " ")),
				filename = repo_root .. "/" .. parsed.path,
				lnum = parsed.start_line,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		elseif parsed.type == "reply" then
			local found = comments.find_comment_by_id(parsed.comment_id, state.comment_map or {})
			local reply_path = found and found.path
			local reply_line = found and found.line
			local loc = reply_path and string.format("%s:%d", reply_path, reply_line or 1) or "reply:" .. parsed.comment_id
			local detail = string.format("%s  (reply)  %s", loc, body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = string.format("%s %s", loc, table.concat(draft_lines, " ")),
				filename = reply_path and (repo_root .. "/" .. reply_path) or nil,
				lnum = reply_line,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		elseif parsed.type == "issue_comment" then
			local detail = string.format("PR comment  %s", body_preview)
			table.insert(entries, {
				value = detail,
				ordinal = "PR comment " .. table.concat(draft_lines, " "),
				filename = nil,
				lnum = nil,
				detail = detail,
				draft_key = key,
				draft_lines = draft_lines,
				display = detail,
			})
		end

		::continue::
	end

	table.sort(entries, function(a, b)
		return a.value < b.value
	end)

	pickers
		.new({}, {
			prompt_title = "Draft Comments",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Draft Content",
				define_preview = function(self, entry)
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, entry.draft_lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.filename then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
						local lnum = math.max(1, selection.lnum or 1)
						pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
					end
				end)
				map("n", "d", function()
					local selection = action_state.get_selected_entry()
					if selection then
						state.drafts[selection.draft_key] = nil
						vim.notify("fude.nvim: Draft deleted", vim.log.levels.INFO)
						actions.close(prompt_bufnr)
						ui.refresh_extmarks()
					end
				end)
				map({ "n", "i" }, "<C-s>", function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local multi = picker:get_multi_selection()
					local targets = #multi > 0 and multi or entries
					local to_submit = {}
					for _, entry in ipairs(targets) do
						local parsed = comments.parse_draft_key(entry.draft_key)
						if parsed then
							table.insert(to_submit, {
								draft_key = entry.draft_key,
								draft_lines = entry.draft_lines,
								parsed = parsed,
							})
						end
					end
					if #to_submit == 0 then
						return
					end
					actions.close(prompt_bufnr)
					vim.ui.select({ "Yes", "No" }, {
						prompt = string.format("Submit %d draft(s)?", #to_submit),
					}, function(choice)
						if choice ~= "Yes" then
							return
						end
						comments.submit_drafts(to_submit, function(succeeded, failed)
							local msg, level = comments.format_submit_result(succeeded, failed, #to_submit)
							vim.notify("fude.nvim: " .. msg, level)
							ui.refresh_extmarks()
							comments.fetch_comments()
						end)
					end)
				end)
				map({ "n", "i" }, "<C-r>", function()
					actions.close(prompt_bufnr)
					-- Submit drafts as a review
					ui.select_review_event(function(event)
						if not event then
							return
						end
						ui.open_comment_input(function(body)
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
				end)
				return true
			end,
		})
		:find()
end

return M
