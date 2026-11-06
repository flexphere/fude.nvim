--- A picker whose rows are toggled in place: `<Tab>` flips the row under the
--- cursor and the picker stays open. Used by the PR overview's reviewer and
--- label editors. Routed by `file_list_mode` like the other pickers; without
--- Telescope / snacks it falls back to vim.ui.select, where choosing a row
--- toggles it and the select reopens.
local M = {}
local config = require("fude.config")
local format = require("fude.ui.format")

--- @class fude.TogglePickerItem
--- @field text string name shown and matched
--- @field on boolean whether the item is applied / requested
--- @field detail string|fun(item: fude.TogglePickerItem): string|nil extra information shown in
---   parentheses; a function is re-evaluated on every render, so it can follow `on`
--- @field mark (fun(item: fude.TogglePickerItem): string, string, string|nil)|nil
---   returns mark, mark highlight and name highlight; re-evaluated on every render
--- @field value any caller data passed back to on_toggle

--- @class fude.TogglePickerOpts
--- @field title string
--- @field items fude.TogglePickerItem[]
--- @field on_toggle fun(item: fude.TogglePickerItem, done: fun(ok: boolean))
---   sends the request that flips `item.on`; calls done(true) on success
--- @field on_close fun()|nil called once when the picker is closed and no request is in flight
--- @field is_alive fun(): boolean|nil vim.ui.select only: reopen after a toggle while this returns true
--- @field extra_action fude.TogglePickerAction|nil a second key (Telescope / snacks only)

--- @class fude.TogglePickerAction
--- @field key string lhs, e.g. "<C-e>"; shown at the end of each row it applies to
--- @field label string what the key does, e.g. "re-request"
--- @field available fun(item: fude.TogglePickerItem): boolean whether the key applies to the row
--- @field unavailable_reason fun(item: fude.TogglePickerItem): string notified when it does not
--- @field run fun(item: fude.TogglePickerItem, done: fun(ok: boolean)) sends the request
--- @field result_on boolean `item.on` after a successful run
--- @field hint_hl (fun(item: fude.TogglePickerItem): string|nil)|nil highlight of the row-end hint
---   (default `Special`), e.g. grey where the action is rarely wanted

--- Resolve an item's detail text for the current render.
--- @param item fude.TogglePickerItem
--- @return string|nil
function M.resolve_detail(item)
	if type(item.detail) == "function" then
		return item.detail(item)
	end
	return item.detail
end

--- Frames of the mark shown in place of a row's own mark while its request is
--- in flight (`.` → `..` → `...`, looping), their highlight, and the time each
--- frame stays. The row's `on` is still the state before the request, which
--- the mark would otherwise show as if nothing were happening.
M.LOADING_FRAMES = { ".", "..", "..." }
M.LOADING_HL = "DiagnosticInfo"
M.LOADING_INTERVAL_MS = 300

--- The loading mark of a frame, padded to the widest frame so the name after
--- it does not move from frame to frame.
--- @param frame number 1-based frame index (wrapped into the frame list)
--- @return string
function M.format_loading_mark(frame)
	local frames = M.LOADING_FRAMES
	local text = frames[(frame - 1) % #frames + 1]
	local width = 0
	for _, f in ipairs(frames) do
		width = math.max(width, #f)
	end
	return text .. string.rep(" ", width - #text)
end

--- Resolve an item's mark for the current render: `item.mark(item)` when
--- given, else the plain applied / not-applied mark from `item.on`. While the
--- item's request is in flight (`session.pending[item]`) the loading mark of
--- the session's current frame replaces it; the name highlight stays the
--- item's own.
--- @param item fude.TogglePickerItem
--- @param session table|nil from new_session; nil never shows the loading mark
--- @return string mark, string mark_hl, string|nil text_hl
function M.resolve_mark(item, session)
	local mark, mark_hl, text_hl
	if type(item.mark) == "function" then
		mark, mark_hl, text_hl = item.mark(item)
	else
		mark, mark_hl = format.format_toggle_mark(item.on)
	end
	if session and session.pending[item] then
		return M.format_loading_mark(session.frame), M.LOADING_HL, text_hl
	end
	return mark, mark_hl, text_hl
end

--- Per-picker state shared by every close path: the items whose request is
--- in flight, whether the picker was asked to close, and the loading spinner.
--- on_close runs once, and only after every in-flight request settled, so
--- the overview it reopens is fetched after GitHub applied the last toggle.
---
--- The spinner is a timer advancing `session.frame` every LOADING_INTERVAL_MS
--- and calling `session.rerender` (set by the Telescope / snacks adapters;
--- nil in vim.ui.select mode, whose select is closed while a request runs). It
--- runs while any request is in flight and stops with the last one, or when
--- the picker closes.
--- @param opts fude.TogglePickerOpts
--- @return table session { pending, frame, rerender, close(), finish(), start_spinner(), stop_spinner(), tick() }
function M.new_session(opts)
	local session = { pending = {}, closing = false, closed = false, frame = 1, rerender = nil, timer = nil }
	function session.finish()
		if session.closing and not session.closed and next(session.pending) == nil then
			session.closed = true
			if opts.on_close then
				opts.on_close()
			end
		end
	end
	--- Advance to the next frame and re-render; the timer callback.
	function session.tick()
		session.frame = session.frame % #M.LOADING_FRAMES + 1
		if session.rerender then
			session.rerender()
		end
	end
	function session.start_spinner()
		if session.timer or not session.rerender then
			return
		end
		local timer = vim.uv.new_timer()
		if not timer then
			return
		end
		session.timer = timer
		timer:start(M.LOADING_INTERVAL_MS, M.LOADING_INTERVAL_MS, vim.schedule_wrap(session.tick))
	end
	function session.stop_spinner()
		local timer = session.timer
		if not timer then
			return
		end
		session.timer = nil
		timer:stop()
		timer:close()
	end
	function session.close()
		session.closing = true
		-- Nothing is shown any more; in-flight requests still settle
		session.stop_spinner()
		session.finish()
	end
	return session
end

--- Run one request for an item. `apply` changes the item only after the
--- request reports success, so a failed request never leaves the row showing
--- a state GitHub does not have. A request for an item whose previous request
--- is still in flight is ignored, so a repeated key cannot send the opposite
--- request before the first one lands. While it is in flight
--- `session.pending[item]` is set, which `resolve_mark` renders as the loading
--- mark, so the picker re-renders on start and again once settled, whatever
--- the result; the spinner runs from the first in-flight request to the last.
--- @param item fude.TogglePickerItem|nil
--- @param session table from new_session
--- @param request fun(done: fun(ok: boolean))
--- @param apply fun()
--- @param on_done fun(ok: boolean)|nil called after the item settled
--- @return boolean started
local function run_item(item, session, request, apply, on_done)
	if not item or session.pending[item] then
		return false
	end
	session.pending[item] = true
	session.start_spinner()
	local settled = false
	request(function(ok)
		if settled then
			return
		end
		settled = true
		session.pending[item] = nil
		if next(session.pending) == nil then
			session.stop_spinner()
		end
		if ok then
			apply()
		end
		if on_done then
			on_done(ok)
		end
		-- A close requested while this request was in flight completes now
		session.finish()
	end)
	return true
end

--- Toggle an item (`<Tab>`): on success `item.on` flips.
--- @param item fude.TogglePickerItem|nil
--- @param opts fude.TogglePickerOpts
--- @param session table from new_session
--- @param on_done fun(ok: boolean)|nil called after the item settled
--- @return boolean started
function M.toggle_item(item, opts, session, on_done)
	return run_item(item, session, function(done)
		opts.on_toggle(item, done)
	end, function()
		item.on = not item.on
	end, on_done)
end

--- Run the extra action (e.g. `<C-e>` re-request) on an item. A row it does
--- not apply to is refused with an INFO naming the reason, sending nothing.
--- @param item fude.TogglePickerItem|nil
--- @param opts fude.TogglePickerOpts
--- @param session table from new_session
--- @param on_done fun(ok: boolean)|nil called after the item settled
--- @return boolean started
function M.run_extra_action(item, opts, session, on_done)
	local action = opts.extra_action
	if not item or not action then
		return false
	end
	if not action.available(item) then
		vim.notify("fude.nvim: " .. action.unavailable_reason(item), vim.log.levels.INFO)
		return false
	end
	return run_item(item, session, function(done)
		action.run(item, done)
	end, function()
		item.on = action.result_on
	end, on_done)
end

--- Text shown at the end of a row the extra action applies to.
--- @param item fude.TogglePickerItem
--- @param opts fude.TogglePickerOpts
--- @return string|nil hint `<C-e>: re-request`
--- @return string|nil hl highlight group of the hint
function M.resolve_action_hint(item, opts)
	local action = opts.extra_action
	if action and action.available(item) then
		local hl = action.hint_hl and action.hint_hl(item) or "Special"
		return action.key .. ": " .. action.label, hl
	end
	return nil, nil
end

--- Show the picker with vim.ui.select. Choosing a row toggles it and reopens
--- the select once the request settled; cancelling closes.
--- @param opts fude.TogglePickerOpts
--- @param session table|nil from new_session (internal, for the reopen)
function M.show_vim_select(opts, session)
	session = session or M.new_session(opts)
	vim.ui.select(opts.items, {
		prompt = opts.title .. " (select to toggle):",
		format_item = function(item)
			-- The select is closed while a request is in flight and reopens
			-- once it settled, so no row is ever rendered as loading here.
			return format.format_toggle_entry(item.text, (M.resolve_mark(item, session)), M.resolve_detail(item))
		end,
	}, function(choice)
		if not choice then
			session.close()
			return
		end
		M.toggle_item(choice, opts, session, function()
			-- Reopening a select whose toggles can no longer work (the
			-- session it edits is gone) would only repeat the refusal.
			if opts.is_alive and not opts.is_alive() then
				session.close()
			else
				M.show_vim_select(opts, session)
			end
		end)
	end)
end

--- Show the picker with Telescope.
--- @param opts fude.TogglePickerOpts
function M.show_telescope(opts)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(opts)
		return
	end
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local themes = require("telescope.themes")

	local session = M.new_session(opts)
	-- Row to restore after a refresh, with the prompt it was read under:
	-- Telescope's refresh moves the selection back to the first row.
	local restore

	local picker = pickers.new(themes.get_dropdown({}), {
		prompt_title = opts.title .. " (<Tab> toggle)",
		finder = finders.new_table({
			results = opts.items,
			entry_maker = function(item)
				return {
					value = item,
					ordinal = item.text,
					-- A function, so a refresh re-reads item.on
					display = function(entry)
						local value = entry.value
						local mark, mark_hl, text_hl = M.resolve_mark(value, session)
						local line = format.format_toggle_entry(value.text, mark, M.resolve_detail(value))
						local name_start = #mark + 1
						local name_end = name_start + #value.text
						local hls = { { { 0, #mark }, mark_hl } }
						if text_hl then
							table.insert(hls, { { name_start, name_end }, text_hl })
						end
						-- The detail in parentheses is grey, as in snacks
						if #line > name_end then
							table.insert(hls, { { name_end, #line }, "Comment" })
						end
						local hint, hint_hl = M.resolve_action_hint(value, opts)
						if hint then
							local hint_start = #line + 2
							line = line .. "  " .. hint
							table.insert(hls, { { hint_start, #line }, hint_hl })
						end
						return line, hls
					end,
				}
			end,
		}),
		sorter = conf.generic_sorter({}),
		attach_mappings = function(prompt_bufnr, map)
			-- The prompt buffer is wiped however the picker closes.
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = prompt_bufnr,
				once = true,
				callback = function()
					vim.schedule(session.close)
				end,
			})
			actions.select_default:replace(function()
				actions.close(prompt_bufnr)
			end)
			-- Re-render the rows (loading mark, flipped mark) keeping the
			-- selection where it is.
			local function rerender(current)
				if not vim.api.nvim_buf_is_valid(prompt_bufnr) or not current then
					return
				end
				-- The row the cursor is on now, not when the key was pressed:
				-- the user may have moved on while the request was in flight,
				-- and the refresh must leave them there.
				restore = { row = current:get_selection_row(), prompt = current:_get_prompt() }
				current:refresh(nil, { reset_prompt = false })
			end
			-- The spinner re-renders through the picker that is current then
			session.rerender = function()
				if vim.api.nvim_buf_is_valid(prompt_bufnr) then
					rerender(action_state.get_current_picker(prompt_bufnr))
				end
			end
			-- Run `fn(item, opts, session, on_done)` on the selected row,
			-- re-rendering when the request starts (loading mark) and once it
			-- settled (the new mark, or the old one back after a failure).
			local function on_selected(fn)
				return function()
					local selection = action_state.get_selected_entry()
					local current = action_state.get_current_picker(prompt_bufnr)
					local started = fn(selection and selection.value, opts, session, function()
						rerender(current)
					end)
					if started then
						rerender(current)
					end
				end
			end
			map("i", "<Tab>", on_selected(M.toggle_item))
			map("n", "<Tab>", on_selected(M.toggle_item))
			if opts.extra_action then
				map("i", opts.extra_action.key, on_selected(M.run_extra_action))
				map("n", opts.extra_action.key, on_selected(M.run_extra_action))
			end
			return true
		end,
	})
	picker:register_completion_callback(function(self)
		if restore then
			local saved = restore
			restore = nil
			-- A row index names the same item only under the same filter;
			-- the prompt may have changed between refresh() and now.
			if self:_get_prompt() == saved.prompt then
				pcall(self.set_selection, self, saved.row)
			end
		end
	end)
	picker:find()
end

--- Show the picker with snacks.picker.
--- @param opts fude.TogglePickerOpts
function M.show_snacks(opts)
	local has_snacks, snacks_picker = pcall(require, "snacks.picker")
	if not has_snacks then
		vim.notify("fude.nvim: snacks.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(opts)
		return
	end

	local session = M.new_session(opts)

	-- Re-render the rows (loading mark, then the new mark or the old one back
	-- after a failure); the cursor stays put.
	local function rerender(picker)
		if not picker.closed and picker.list then
			pcall(picker.list.update, picker.list, { force = true })
		end
	end
	-- Run `fn(item, opts, session, on_done)` on `item`, re-rendering when the
	-- request starts and once it settled; the spinner re-renders the same way.
	local function run(fn, picker, item)
		session.rerender = function()
			rerender(picker)
		end
		local started = fn(item, opts, session, function()
			rerender(picker)
		end)
		if started then
			rerender(picker)
		end
	end
	local input_keys = { ["<Tab>"] = { "fude_toggle", mode = { "i", "n" } } }
	local list_keys = { ["<Tab>"] = "fude_toggle" }
	if opts.extra_action then
		input_keys[opts.extra_action.key] = { "fude_extra", mode = { "i", "n" } }
		list_keys[opts.extra_action.key] = "fude_extra"
	end

	-- snacks matches on item.text, which the items already carry
	snacks_picker.pick({
		source = "fude_toggle",
		title = opts.title .. " (<Tab> toggle)",
		items = opts.items,
		layout = { preset = "select" },
		format = function(item, _)
			local mark, mark_hl, text_hl = M.resolve_mark(item, session)
			local chunks = { { mark .. " ", mark_hl }, { item.text, text_hl } }
			local detail = M.resolve_detail(item)
			if detail and detail ~= "" then
				table.insert(chunks, { "  (" .. detail .. ")", "Comment" })
			end
			local hint, hint_hl = M.resolve_action_hint(item, opts)
			if hint then
				table.insert(chunks, { "  " .. hint, hint_hl })
			end
			return chunks
		end,
		confirm = function(picker)
			picker:close()
		end,
		on_close = function()
			vim.schedule(session.close)
		end,
		actions = {
			fude_toggle = function(picker, item)
				run(M.toggle_item, picker, item)
			end,
			fude_extra = function(picker, item)
				run(M.run_extra_action, picker, item)
			end,
		},
		win = { input = { keys = input_keys }, list = { keys = list_keys } },
	})
end

--- Open the toggle picker.
--- @param opts fude.TogglePickerOpts
function M.open(opts)
	local mode = config.opts.file_list_mode
	if mode == "telescope" then
		M.show_telescope(opts)
	elseif mode == "snacks" then
		M.show_snacks(opts)
	else
		M.show_vim_select(opts)
	end
end

return M
