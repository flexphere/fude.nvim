local M = {}
local config = require("fude.config")
local diff = require("fude.diff")
local data = require("fude.comments.data")
local sync = require("fude.comments.sync")

-- Lazy requires (circular dependency prevention)
local function get_ui()
	return require("fude.ui")
end
local function get_comments()
	return require("fude.comments")
end

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

	local entries = data.build_comment_entries(state.comment_map, repo_root, config.format_date)
	for _, entry in ipairs(entries) do
		entry.display = make_display
	end

	local ui = get_ui()

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
							get_comments().view_comments()
						else
							ui.flash_line(lnum)
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

	local entries = data.build_draft_entries(state.drafts, state.comment_map or {}, repo_root)

	local ui = get_ui()

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
						local parsed = data.parse_draft_key(entry.draft_key)
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
						sync.submit_drafts(to_submit, function(succeeded, failed)
							local msg, level = data.format_submit_result(succeeded, failed, #to_submit)
							vim.notify("fude.nvim: " .. msg, level)
							ui.refresh_extmarks()
							sync.fetch_comments()
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
						ui.open_comment_input(function(review_body)
							sync.submit_as_review(event, review_body, function(err, excluded_count)
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
