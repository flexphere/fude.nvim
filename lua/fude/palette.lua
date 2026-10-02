--- `:FudeCommandPalette` command palette.
---
--- Lists the commands from `commands.lua` that are usable in the current
--- session state, searchable by description and command name, with the
--- user's own key mapping shown when one invokes the command. The picker
--- follows `file_list_mode` (telescope / snacks / vim.ui.select).
local config = require("fude.config")
local commands = require("fude.commands")

local M = {}

----------------------------------------------------------------
-- Pure helpers
----------------------------------------------------------------

--- Whether a mapping's rhs invokes the given user command.
--- Accepts `<cmd>Name<cr>`, `:Name<cr>`, `:<C-u>Name<cr>` and
--- `:'<,'>Name<cr>` (case-insensitive). The name must not be a prefix of
--- a longer identifier, so `FudeReviewScope` does not match
--- `<cmd>FudeReviewScopeNext<cr>`.
--- @param rhs string mapping rhs
--- @param name string command name
--- @return boolean
function M.rhs_invokes_command(rhs, name)
	local lower = rhs:lower()
	local target = name:lower()
	local pos = 1
	while true do
		local s, e = lower:find(target, pos, true)
		if not s then
			return false
		end
		local before = lower:sub(1, s - 1)
		local after = lower:sub(e + 1, e + 1)
		-- `:`, `<cmd>`, `<c-u>` and `'<,'>` all end with `:` or `>`
		local prefix_ok = before:match("[:>]%s*$") ~= nil
		local suffix_ok = not after:match("[%w_]")
		if prefix_ok and suffix_ok then
			return true
		end
		pos = e + 1
	end
end

--- Find the lhs of the first mapping whose rhs invokes `name`.
--- Mappings defined with a Lua callback have no rhs and are skipped.
--- @param keymaps table[] entries with `lhs` and optional `rhs` (as returned by nvim_get_keymap)
--- @param name string command name
--- @return string|nil lhs
function M.find_keymap_for_command(keymaps, name)
	for _, km in ipairs(keymaps) do
		if type(km.rhs) == "string" and km.rhs ~= "" and M.rhs_invokes_command(km.rhs, name) then
			return km.lhs
		end
	end
	return nil
end

--- Build the palette entries for the given state.
--- Keeps entries whose `available(state)` is true and `palette ~= false`,
--- attaches the detected key mapping, and orders them by category
--- (`category_order`) then registry order.
--- @param cmds table[] registry entries (`commands.list`)
--- @param state table `config.state`
--- @param keymaps table[] mappings to search for keys (see find_keymap_for_command)
--- @param category_order string[]|nil category order (default `commands.CATEGORIES`)
--- @return table[] entries `{ name, desc, category, key, range, index }`
function M.build_palette_entries(cmds, state, keymaps, category_order)
	local order_index = {}
	for i, category in ipairs(category_order or commands.CATEGORIES) do
		order_index[category] = i
	end

	local entries = {}
	for i, cmd in ipairs(cmds) do
		if cmd.palette ~= false and cmd.available(state) then
			table.insert(entries, {
				name = cmd.name,
				desc = cmd.desc,
				category = cmd.category,
				key = M.find_keymap_for_command(keymaps, cmd.name),
				range = cmd.range == true,
				index = i,
			})
		end
	end

	table.sort(entries, function(a, b)
		local ca = order_index[a.category] or math.huge
		local cb = order_index[b.category] or math.huge
		if ca ~= cb then
			return ca < cb
		end
		return a.index < b.index
	end)
	return entries
end

--- Column widths for aligned display.
--- @param entries table[] from build_palette_entries
--- @return { category: number, desc: number, name: number, key: number }
function M.calculate_palette_widths(entries)
	local widths = { category = 0, desc = 0, name = 0, key = 0 }
	for _, entry in ipairs(entries) do
		widths.category = math.max(widths.category, #entry.category)
		widths.desc = math.max(widths.desc, #entry.desc)
		widths.name = math.max(widths.name, #entry.name + 1) -- leading ":"
		if entry.key then
			widths.key = math.max(widths.key, #entry.key)
		end
	end
	return widths
end

--- Compact picker size for the palette: wide enough for the widest row and
--- tall enough for every entry, clamped to the editor size.
--- @param widths table from calculate_palette_widths
--- @param count number number of entries
--- @param columns number editor columns (`vim.o.columns`)
--- @param lines number editor lines (`vim.o.lines`)
--- @return { width: number, height: number } absolute window size in cells
function M.calculate_palette_layout(widths, count, columns, lines)
	-- `[Category]` + 2 + desc + 2 + `:Name` (+ 2 + key)
	local row = (widths.category + 2) + 2 + widths.desc + 2 + widths.name
	if widths.key > 0 then
		row = row + 2 + widths.key
	end
	local width = math.min(math.max(row + 6, 40), math.max(columns - 4, 20))
	-- prompt (3 lines with border) + results border (2) + rows
	local height = math.min(count + 5, math.max(lines - 4, 6))
	return { width = width, height = height }
end

--- Render a mapping lhs for display, restoring `<leader>` for the leader
--- character that `nvim_get_keymap` expands (e.g. " eb" → "<leader>eb").
--- @param lhs string
--- @param mapleader string|nil `vim.g.mapleader` (nil → the default "\")
--- @return string
function M.format_key_lhs(lhs, mapleader)
	local leader = mapleader
	if leader == nil or leader == "" then
		leader = "\\"
	end
	if lhs:sub(1, #leader) == leader then
		return "<leader>" .. lhs:sub(#leader + 1)
	end
	return lhs
end

local function pad(text, width)
	local w = #text
	if w >= width then
		return text
	end
	return text .. string.rep(" ", width - w)
end

--- Format one entry as `[Category]  Description  :Name  key`.
--- @param entry table from build_palette_entries
--- @param widths table from calculate_palette_widths
--- @return string
function M.format_palette_entry(entry, widths)
	local line = pad("[" .. entry.category .. "]", widths.category + 2) .. "  " .. pad(entry.desc, widths.desc) .. "  "
	if entry.key then
		-- Pad the name column only when a key follows it (no trailing spaces otherwise)
		return line .. pad(":" .. entry.name, widths.name) .. "  " .. entry.key
	end
	return line .. ":" .. entry.name
end

----------------------------------------------------------------
-- Side effects
----------------------------------------------------------------

--- Collect buffer-local then global mappings for the given modes, with each
--- lhs rendered for display via format_key_lhs.
--- @param modes string[]
--- @param buf number
--- @return table[]
function M.collect_keymaps(modes, buf)
	local list = {}
	local mapleader = vim.g.mapleader
	local function add(km)
		km.lhs = M.format_key_lhs(km.lhs, mapleader)
		table.insert(list, km)
	end
	for _, mode in ipairs(modes) do
		for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
			add(km)
		end
		for _, km in ipairs(vim.api.nvim_get_keymap(mode)) do
			add(km)
		end
	end
	return list
end

--- Execute the selected entry through its user command, in the window the
--- palette was opened from, forwarding the range only to range commands.
--- @param entry table from build_palette_entries
--- @param ctx { win: number|nil, range: number[]|nil }
function M.execute(entry, ctx)
	if ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_get_current_win() ~= ctx.win then
		vim.api.nvim_set_current_win(ctx.win)
	end
	local cmd = { cmd = entry.name }
	if entry.range and ctx.range then
		cmd.range = ctx.range
	end
	vim.cmd(cmd)
end

--- When called while visual mode is still active (a `<Cmd>FudeCommandPalette<CR>` mapping
--- keeps the selection but passes no range), leave visual mode and return the
--- selected line range so range commands still act on the selection.
--- @return number[]|nil `{ line1, line2 }` or nil when not in visual mode
function M.resolve_visual_range()
	local mode = vim.fn.mode()
	if not (mode == "v" or mode == "V" or mode == "\22") then
		return nil
	end
	-- Leaving visual mode updates the '< and '> marks
	vim.cmd("normal! \27")
	local line1 = vim.fn.line("'<")
	local line2 = vim.fn.line("'>")
	if line1 == 0 or line2 == 0 then
		return nil
	end
	return { math.min(line1, line2), math.max(line1, line2) }
end

--- Open the palette.
--- @param opts { range: number[]|nil }|nil `range = { line1, line2 }` when opened with a range
function M.open(opts)
	opts = opts or {}
	if not opts.range then
		opts.range = M.resolve_visual_range()
	end
	local ctx = { win = vim.api.nvim_get_current_win(), range = opts.range }
	local modes = { "n" }
	if opts.range then
		modes = { "x", "n" }
	end
	local keymaps = M.collect_keymaps(modes, vim.api.nvim_get_current_buf())
	local entries = M.build_palette_entries(commands.list, config.state, keymaps)
	if #entries == 0 then
		vim.notify("fude.nvim: No commands available", vim.log.levels.WARN)
		return
	end

	if config.opts.file_list_mode == "telescope" then
		M.show_telescope(entries, ctx)
	elseif config.opts.file_list_mode == "snacks" then
		M.show_snacks(entries, ctx)
	else
		M.show_vim_select(entries, ctx)
	end
end

--- Show the palette in a Telescope picker.
--- @param entries table[]
--- @param ctx table
function M.show_telescope(entries, ctx)
	local has_telescope, pickers = pcall(require, "telescope.pickers")
	if not has_telescope then
		vim.notify("fude.nvim: telescope.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(entries, ctx)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")
	local themes = require("telescope.themes")

	local widths = M.calculate_palette_widths(entries)
	local layout = M.calculate_palette_layout(widths, #entries, vim.o.columns, vim.o.lines)
	local displayer = entry_display.create({
		separator = "  ",
		items = {
			{ width = widths.category + 2 },
			{ width = widths.desc },
			{ width = widths.name },
			{ remaining = true },
		},
	})

	local function make_display(entry)
		return displayer({
			{ "[" .. entry.category .. "]", "Title" },
			entry.desc,
			{ ":" .. entry.name, "Comment" },
			{ entry.key or "", "Special" },
		})
	end

	local results = {}
	for _, entry in ipairs(entries) do
		entry.display = make_display
		entry.ordinal = entry.desc .. " " .. entry.name
		table.insert(results, entry)
	end

	-- Compact centered dropdown sized to the list instead of the user's
	-- (typically screen-filling) default layout: the palette is a short menu.
	local theme = themes.get_dropdown({
		previewer = false,
		layout_config = { width = layout.width, height = layout.height },
	})

	pickers
		.new(theme, {
			prompt_title = "Fude Command Palette",
			finder = finders.new_table({
				results = results,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						M.execute(selection, ctx)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Show the palette in a snacks.picker.
--- @param entries table[]
--- @param ctx table
function M.show_snacks(entries, ctx)
	local has_snacks, snacks_picker = pcall(require, "snacks.picker")
	if not has_snacks then
		vim.notify("fude.nvim: snacks.nvim not found, falling back to vim.ui.select", vim.log.levels.WARN)
		M.show_vim_select(entries, ctx)
		return
	end

	local widths = M.calculate_palette_widths(entries)
	local layout = M.calculate_palette_layout(widths, #entries, vim.o.columns, vim.o.lines)
	-- The select preset has no results border: input (1) + separator (1) + rows
	local height = math.min(layout.height, #entries + 2)
	local items = {}
	for _, entry in ipairs(entries) do
		entry.text = entry.desc .. " " .. entry.name
		table.insert(items, entry)
	end

	snacks_picker.pick({
		source = "fude_palette",
		title = "Fude Command Palette",
		items = items,
		-- Compact centered "select" preset sized to the list, no preview pane
		layout = {
			preset = "select",
			preview = false,
			layout = {
				width = layout.width,
				min_width = layout.width,
				max_width = layout.width,
				height = height,
				min_height = height,
				max_height = height,
			},
		},
		format = function(item, _)
			local chunks = {
				{ pad("[" .. item.category .. "]", widths.category + 2) .. "  ", "Title" },
				{ pad(item.desc, widths.desc) .. "  " },
				{ pad(":" .. item.name, widths.name), "Comment" },
			}
			if item.key then
				table.insert(chunks, { "  " .. item.key, "Special" })
			end
			return chunks
		end,
		confirm = function(picker, item)
			picker:close()
			if item then
				M.execute(item, ctx)
			end
		end,
	})
end

--- Show the palette using vim.ui.select.
--- @param entries table[]
--- @param ctx table
function M.show_vim_select(entries, ctx)
	local widths = M.calculate_palette_widths(entries)
	vim.ui.select(entries, {
		prompt = "Fude Command Palette:",
		format_item = function(entry)
			return M.format_palette_entry(entry, widths)
		end,
	}, function(choice)
		if choice then
			M.execute(choice, ctx)
		end
	end)
end

return M
