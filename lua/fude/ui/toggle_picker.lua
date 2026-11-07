--- A picker whose rows are toggled in place: `<Tab>` flips the row under the
--- cursor and the picker stays open; closing it ends the flow. Used by the PR
--- overview's reviewer and label editors. Routed by `file_list_mode` like the other pickers; without
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
--- @field on_confirm fun(item: fude.TogglePickerItem)|nil Telescope / snacks only: `<CR>` closes the
---   picker and runs this with the row under the cursor (otherwise `<CR>` only closes)
--- @field confirm_label string|nil what `<CR>` does, shown in the title next to `<Tab> toggle`
--- @field images (fun(item: fude.TogglePickerItem, cb: fun(path: string|nil)))|nil Telescope / snacks
---   only: asked once per item for the file of an image drawn inline before its row (IMAGE_HEIGHT
---   by IMAGE_WIDTH cells, through snacks.nvim's image module); `cb(nil)` for none. The rows are
---   drawn again after every re-render of the list, and once more when a file arrives.

--- @class fude.TogglePickerAction
--- @field key string lhs, e.g. "<C-e>"; shown at the end of each row it applies to
--- @field label string what the key does, e.g. "re-request"
--- @field available fun(item: fude.TogglePickerItem): boolean whether the key applies to the row
--- @field unavailable_reason fun(item: fude.TogglePickerItem): string notified when it does not
--- @field run fun(item: fude.TogglePickerItem, done: fun(ok: boolean)) sends the request
--- @field result_on boolean `item.on` after a successful run
--- @field hint_hl (fun(item: fude.TogglePickerItem): string|nil)|nil highlight of the row-end hint
---   (default `Special`), e.g. grey where the action is rarely wanted

--- The picker title with its key hints: `Reactions (<Tab> toggle)`, plus
--- `, <CR> <confirm_label>` when `<CR>` does something. Pure.
--- @param opts table { title, on_confirm?, confirm_label? }
--- @return string
function M.build_title(opts)
	local hints = "<Tab> toggle"
	if opts.on_confirm and opts.confirm_label then
		hints = hints .. ", <CR> " .. opts.confirm_label
	end
	return string.format("%s (%s)", opts.title, hints)
end

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
--- in flight — the braille spinner of the gh CLI, every frame one cell wide —
--- their highlight, and the time each frame stays (gh's 120 ms). The row's
--- `on` is still the state before the request, which the mark would otherwise
--- show as if nothing were happening.
M.LOADING_FRAMES = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
M.LOADING_HL = "DiagnosticInfo"
M.LOADING_INTERVAL_MS = 120

--- Size in cells of the image drawn before a row (`opts.images`): one row,
--- and the two columns that make a square at the usual cell aspect ratio.
M.IMAGE_HEIGHT = 1
M.IMAGE_WIDTH = 2
--- Cells the image takes in the row: snacks.nvim draws an image with text
--- around it IMAGE_WIDTH + 2 cells wide (a blank cell each side). The row
--- holds that many spaces before the name for it (`image_slot`).
M.IMAGE_CELLS = M.IMAGE_WIDTH + 2
--- Image loading order (`opts.images`): the first IMAGE_FIRST rows — about
--- what the picker shows — are asked for at once, and the rest in parallel
--- with them but at most IMAGE_CONCURRENCY at a time, so a large list does
--- not start a download per row together and delay the visible ones.
M.IMAGE_FIRST = 10
M.IMAGE_CONCURRENCY = 4

--- The loading mark of a frame, padded with spaces to `width` display cells
--- — the width of the mark it stands in for — so the name after it stays
--- where it is, whatever the mark's width.
--- @param frame number 1-based frame index (wrapped into the frame list)
--- @param width number|nil display width to fill (default: the frame's own)
--- @return string
function M.format_loading_mark(frame, width)
	local frames = M.LOADING_FRAMES
	local text = frames[(frame - 1) % #frames + 1]
	local pad = (width or 0) - vim.fn.strdisplaywidth(text)
	return text .. string.rep(" ", math.max(0, pad))
end

--- Resolve an item's mark for the current render: `item.mark(item)` when
--- given, else the plain applied / not-applied mark from `item.on`. While the
--- item's request is in flight (`session.pending[item]`) the loading mark of
--- the session's current frame replaces it, padded to the mark's width; the
--- name highlight stays the item's own.
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
		return M.format_loading_mark(session.frame, vim.fn.strdisplaywidth(mark)), M.LOADING_HL, text_hl
	end
	return mark, mark_hl, text_hl
end

--- Per-picker state shared by every close path: the items whose request is
--- in flight, whether the picker was asked to close, and the loading spinner.
--- on_close runs once, and only after every in-flight request settled, so
--- whatever it does sees GitHub after the last toggle was applied.
---
--- The spinner is a timer advancing `session.frame` every LOADING_INTERVAL_MS
--- and calling `session.rerender` (set by the Telescope / snacks adapters;
--- nil in vim.ui.select mode, whose select is closed while a request runs). It
--- runs while any request is in flight and stops with the last one, or when
--- the picker closes.
---
--- `session.images[item]` is the file of the item's row image once known
--- (false for none); `load_images()` asks `opts.images` for every item and
--- re-renders, once per batch, as the files arrive.
--- @param opts fude.TogglePickerOpts
--- @return table session { pending, frame, rerender, images, close(), finish(), start_spinner(),
---   stop_spinner(), tick(), request_rerender(), load_images() }
function M.new_session(opts)
	local session = {
		pending = {},
		closing = false,
		closed = false,
		frame = 1,
		rerender = nil,
		timer = nil,
		images = {},
	}
	--- Re-render once on the next tick, however often it is asked before.
	local rerender_queued = false
	function session.request_rerender()
		if rerender_queued then
			return
		end
		rerender_queued = true
		vim.schedule(function()
			rerender_queued = false
			if session.rerender and not session.closed then
				session.rerender()
			end
		end)
	end
	--- Ask `opts.images` for every item's file, in display order: the first
	--- IMAGE_FIRST at once, the rest IMAGE_CONCURRENCY at a time alongside
	--- them, and no new ones once the picker closes. Each answer is kept and
	--- shown by the next re-render.
	function session.load_images()
		if not opts.images then
			return
		end
		local items = opts.items or {}
		local function ask(item, on_answer)
			local answered = false
			opts.images(item, function(path)
				if answered then
					return
				end
				answered = true
				session.images[item] = path or false
				session.request_rerender()
				if on_answer then
					on_answer()
				end
			end)
		end
		local first = math.min(M.IMAGE_FIRST, #items)
		for i = 1, first do
			ask(items[i])
		end
		local next_index = first + 1
		local function pump()
			if next_index > #items or session.closing then
				return
			end
			local item = items[next_index]
			next_index = next_index + 1
			-- On the next tick: a cached image answers at once, and a long
			-- list must not recurse through every row
			ask(item, function()
				vim.schedule(pump)
			end)
		end
		for _ = 1, M.IMAGE_CONCURRENCY do
			pump()
		end
	end
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

--- The snacks.nvim image module, or nil without it.
local function snacks_image()
	local ok, snacks = pcall(require, "snacks")
	if ok and type(snacks) == "table" and type(snacks.image) == "table" and snacks.image.placement then
		return snacks.image
	end
	return nil
end

--- The spaces held before a row's name for its image (`opts.images`), so the
--- name sits in the same column whether the image is drawn, still loading,
--- or missing; "" without images.
--- @param opts fude.TogglePickerOpts
--- @return string
function M.image_slot(opts)
	return opts.images and string.rep(" ", M.IMAGE_CELLS) or ""
end

--- 0-based byte range of a row's image slot — the IMAGE_CELLS spaces right
--- before the name — in the row's text as the picker wrote it (with whatever
--- prefix it added).
--- @param line string
--- @param text string the row's name
--- @return number|nil start, number|nil finish (exclusive)
function M.find_image_slot(line, text)
	local slot = string.rep(" ", M.IMAGE_CELLS)
	local s = line:find(slot .. text, 1, true)
	if not s then
		return nil, nil
	end
	return s - 1, s - 1 + M.IMAGE_CELLS
end

--- End of the text a placement conceals: as many slot cells as the image
--- takes, so a narrower image leaves the rest of the slot as spaces.
local function conceal_end(col, width)
	return col + math.min(M.IMAGE_CELLS, width or M.IMAGE_CELLS)
end

--- Whether the placement's extmark is still shown at `row`/`col` (0-based col).
local function extmark_at(image, placement, row, col)
	local eid = type(placement.eids) == "table" and placement.eids[1] or nil
	if not eid then
		return false
	end
	local ns = image.placement.ns or vim.api.nvim_create_namespace("snacks.image")
	local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, placement.buf, ns, eid, { details = true })
	return ok
		and type(mark) == "table"
		and mark[1] == row - 1
		and mark[2] == col
		and not (type(mark[3]) == "table" and mark[3].invalid)
end

local function close_placement(held)
	pcall(function()
		held.placement:close()
	end)
end

--- Draw the image of `item` on `row` (1-based) of `buf`, right after the
--- picker wrote that row: into the row's image slot, concealing it. The
--- item's placement is kept across re-renders — rewriting a row hides it,
--- so it is drawn again at once, in the same tick, before the screen is
--- redrawn, and moved when the item moved — instead of being made anew,
--- which would leave the row blank until snacks' deferred update. Nothing is
--- drawn while the file is unknown or the row has no slot (another item's
--- placement is left to `prune_row_images`). Placements are tracked per
--- buffer and item in `session.placed`. Needs snacks.nvim's image module;
--- a no-op without.
--- @param buf number
--- @param row number 1-based
--- @param item fude.TogglePickerItem
--- @param session table from new_session
function M.place_row_image(buf, row, item, session)
	local image = snacks_image()
	if not image or type(item) ~= "table" or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	session.placed = session.placed or {}
	local placed = session.placed[buf] or {}
	session.placed[buf] = placed
	local path = session.images[item]
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
	local col, finish
	if path and line and type(item.text) == "string" then
		col, finish = M.find_image_slot(line, item.text)
	end
	local held = placed[item]
	if held and (not col or held.path ~= path) then
		close_placement(held)
		placed[item] = nil
		held = nil
	end
	if not col then
		return
	end
	if not held then
		local ok, placement = pcall(image.placement.new, buf, path, {
			pos = { row, col },
			range = { row, col, row, finish },
			conceal = true,
			inline = true,
			height = M.IMAGE_HEIGHT,
			width = M.IMAGE_WIDTH,
			-- Conceal only the cells the image takes (its width is known
			-- once snacks measured it)
			on_update_pre = function(self)
				local got, state = pcall(self.state, self)
				if got and type(state) == "table" and self.opts.range then
					self.opts.range[4] = conceal_end(self.opts.range[2], state.loc.width)
				end
			end,
		})
		if ok and placement then
			placed[item] = { placement = placement, path = path }
		end
		return
	end
	local placement = held.placement
	local loc = type(placement._state) == "table" and placement._state.loc or nil
	local pos = placement.opts.pos
	local moved = pos[1] ~= row or pos[2] ~= col
	placement.opts.pos = { row, col }
	placement.opts.range = { row, col, row, conceal_end(col, loc and loc.width) }
	-- Not drawn yet: its first update draws it where it now is
	if not loc then
		return
	end
	if not moved and extmark_at(image, placement, row, col) then
		return
	end
	loc[1], loc[2] = row, col
	pcall(placement.render_grid, placement, loc)
end

--- Close the placements in `buf` of every item but `keep` (a set of items):
--- after a full render, for the items no longer shown.
--- @param buf number
--- @param keep table<fude.TogglePickerItem, boolean>
--- @param session table from new_session
function M.prune_row_images(buf, keep, session)
	local placed = session.placed and session.placed[buf]
	if not placed then
		return
	end
	for item, held in pairs(placed) do
		if not keep[item] then
			close_placement(held)
			placed[item] = nil
		end
	end
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
	local slot = M.image_slot(opts)

	local picker = pickers.new(themes.get_dropdown({}), {
		prompt_title = M.build_title(opts),
		-- A refresh (on request start, every spinner frame, on settle) keeps
		-- the selected entry selected: new_table builds the entries once, so
		-- Telescope finds the same entry after the refresh. The default
		-- "reset" would move the cursor back to the first row, and restoring
		-- a remembered row from a completion callback breaks when refreshes
		-- overlap, which the spinner makes common.
		selection_strategy = "follow",
		-- Keep the caller's order among rows of the same score (every row with
		-- an empty prompt), so the applied labels / requested reviewers stay on
		-- top and toggling never reorders the rows. Telescope's default breaks
		-- ties by the ordinal's length, which shuffles the list by name length.
		tiebreak = function()
			return false
		end,
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
						-- mark, image slot, name, detail
						local line = format.format_toggle_entry(slot .. value.text, mark, M.resolve_detail(value))
						local name_start = #mark + 1 + #slot
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
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if opts.on_confirm and selection and selection.value then
					vim.schedule(function()
						opts.on_confirm(selection.value)
					end)
				end
			end)
			-- Re-render the rows (loading mark, flipped mark); the "follow"
			-- strategy keeps the selection on the entry selected when the
			-- refresh completes.
			local function rerender(current)
				if not vim.api.nvim_buf_is_valid(prompt_bufnr) or not current then
					return
				end
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
	if opts.images then
		-- Telescope writes the results one row at a time; draw the row's
		-- image right after, in the same tick, so it is never missing from
		-- a redraw.
		local entry_adder = picker.entry_adder
		picker.entry_adder = function(self, index, entry, ...)
			local ret = entry_adder(self, index, entry, ...)
			if type(entry) == "table" and entry.value and self.results_bufnr then
				local ok, row = pcall(self.get_row, self, index)
				if ok and type(row) == "number" and row >= 0 then
					M.place_row_image(self.results_bufnr, row + 1, entry.value, session)
				end
			end
			return ret
		end
		-- The item each 0-based results row shows (all rows when `which` is nil)
		local function result_rows(current, which)
			local bufnr = current.results_bufnr
			if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
				return nil, {}
			end
			if not which then
				which = {}
				for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
					table.insert(which, row)
				end
			end
			local rows = {}
			for _, row in ipairs(which) do
				local ok, index = pcall(current.get_index, current, row)
				local entry = ok and index and current.manager and current.manager:get_entry(index) or nil
				if type(entry) == "table" and entry.value then
					table.insert(rows, { row = row + 1, item = entry.value })
				end
			end
			return bufnr, rows
		end
		-- Once a refresh is done: every shown row has its image (a row
		-- Telescope moved without rewriting it), and the items no longer
		-- shown lose theirs.
		picker:register_completion_callback(function(self)
			local bufnr, rows = result_rows(self)
			if not bufnr then
				return
			end
			local keep = {}
			for _, entry in ipairs(rows) do
				keep[entry.item] = true
				M.place_row_image(bufnr, entry.row, entry.item, session)
			end
			M.prune_row_images(bufnr, keep, session)
		end)
		-- Moving the selection rewrites the caret of the old and the new row,
		-- which can shift their slot when the caret and the entry prefix
		-- differ in length.
		local set_selection = picker.set_selection
		picker.set_selection = function(self, row)
			local ok_old, old = pcall(self.get_selection_row, self)
			local ret = set_selection(self, row)
			local which = {}
			if ok_old and type(old) == "number" then
				table.insert(which, old)
			end
			if type(row) == "number" and row ~= old then
				table.insert(which, row)
			end
			local bufnr, rows = result_rows(self, which)
			for _, entry in ipairs(rows) do
				M.place_row_image(bufnr, entry.row, entry.item, session)
			end
			return ret
		end
	end
	-- Typing or deleting in the prompt starts again from the first row; the
	-- "follow" strategy above only applies to this picker's own refreshes.
	require("fude.util").reset_selection_on_prompt_change(picker)
	picker:find()
	if opts.images then
		-- The image conceals its slot (the snacks list sets this itself)
		local win = picker.results_win
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_option_value("conceallevel", 2, { win = win, scope = "local" })
			vim.api.nvim_set_option_value("concealcursor", "nvic", { win = win, scope = "local" })
		end
		-- Images after the picker is on screen
		vim.schedule(session.load_images)
	end
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
	local slot = M.image_slot(opts)

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
	local picker = snacks_picker.pick({
		source = "fude_toggle",
		title = M.build_title(opts),
		items = opts.items,
		layout = { preset = "select" },
		-- Same as Telescope's tiebreak above: snacks breaks ties by text
		-- length before the item order by default
		sort = { fields = { "score:desc", "idx" } },
		format = function(item, _)
			local mark, mark_hl, text_hl = M.resolve_mark(item, session)
			-- mark, image slot, name, detail
			local chunks = { { mark .. " ", mark_hl } }
			if slot ~= "" then
				table.insert(chunks, { slot })
			end
			table.insert(chunks, { item.text, text_hl })
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
		confirm = function(picker, item)
			picker:close()
			if opts.on_confirm and item then
				vim.schedule(function()
					opts.on_confirm(item)
				end)
			end
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
	if opts.images and type(picker) == "table" and type(picker.list) == "table" then
		-- Images arriving later re-render through the picker
		session.rerender = function()
			rerender(picker)
		end
		-- A dirty render blanks the list buffer and writes it one row at a
		-- time before redrawing the screen; draw each row's image right
		-- after its row, so it is never missing from that redraw.
		local list = picker.list
		local write_row = list._render
		list._render = function(self, item, row, ...)
			local ret = write_row(self, item, row, ...)
			M.place_row_image(self.win.buf, row, item, session)
			return ret
		end
		-- Afterwards the items no longer shown lose their images
		local render = list.render
		list.render = function(self, ...)
			local dirty = self.dirty
			local ret = render(self, ...)
			if dirty and self.win and self.win.buf then
				local keep = {}
				for _, item in pairs(self.visible or {}) do
					keep[item] = true
				end
				M.prune_row_images(self.win.buf, keep, session)
			end
			return ret
		end
		-- Images after the picker is on screen
		vim.schedule(session.load_images)
	end
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
