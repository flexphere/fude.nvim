local helpers = require("tests.helpers")
local palette = require("fude.palette")
local commands = require("fude.commands")
local config = require("fude.config")

describe("palette.rhs_invokes_command", function()
	it("matches <cmd>Name<cr>", function()
		assert.is_true(palette.rhs_invokes_command("<cmd>FudeReviewDiff<cr>", "FudeReviewDiff"))
	end)

	it("matches :Name<CR>", function()
		assert.is_true(palette.rhs_invokes_command(":FudeReviewDiff<CR>", "FudeReviewDiff"))
	end)

	it("is case-insensitive on the wrapper", function()
		assert.is_true(palette.rhs_invokes_command("<Cmd>FudeReviewDiff<CR>", "FudeReviewDiff"))
		assert.is_true(palette.rhs_invokes_command("<CMD>FudeReviewDiff<CR>", "FudeReviewDiff"))
	end)

	it("matches the command name exactly (user commands are case-sensitive)", function()
		-- `<cmd>fudereviewdiff<cr>` would fail at runtime, so it is not FudeReviewDiff's key
		assert.is_false(palette.rhs_invokes_command("<cmd>fudereviewdiff<cr>", "FudeReviewDiff"))
		assert.is_false(palette.rhs_invokes_command(":FUDEREVIEWDIFF<CR>", "FudeReviewDiff"))
	end)

	it("matches visual-mode wrappers :<C-u> and :'<,'>", function()
		assert.is_true(palette.rhs_invokes_command(":<C-u>FudeReviewSuggest<CR>", "FudeReviewSuggest"))
		assert.is_true(palette.rhs_invokes_command(":'<,'>FudeReviewComment<CR>", "FudeReviewComment"))
	end)

	it("does not match a longer command sharing the prefix", function()
		assert.is_false(palette.rhs_invokes_command("<cmd>FudeReviewScopeNext<cr>", "FudeReviewScope"))
	end)

	it("does not match the name embedded in another identifier", function()
		assert.is_false(palette.rhs_invokes_command("<cmd>lua MyFudeReviewDiff()<cr>", "FudeReviewDiff"))
	end)

	it("matches after skipping an earlier non-command occurrence", function()
		assert.is_true(palette.rhs_invokes_command(":FudeReviewDiffAll | :FudeReviewDiff<cr>", "FudeReviewDiff"))
	end)

	it("returns false for unrelated rhs", function()
		assert.is_false(palette.rhs_invokes_command("<cmd>Telescope find_files<cr>", "FudeReviewDiff"))
	end)

	it("returns false for an empty command name instead of looping", function()
		assert.is_false(palette.rhs_invokes_command("<cmd>FudeReviewDiff<cr>", ""))
	end)
end)

describe("palette.find_keymap_for_command", function()
	it("returns the lhs of the first matching mapping", function()
		local keymaps = {
			{ lhs = "<leader>ef", rhs = "<cmd>FudeReviewFiles<cr>" },
			{ lhs = "<leader>ed", rhs = "<cmd>FudeReviewDiff<cr>" },
			{ lhs = "<leader>eD", rhs = ":FudeReviewDiff<CR>" },
		}
		assert.are.equal("<leader>ed", palette.find_keymap_for_command(keymaps, "FudeReviewDiff"))
	end)

	it("skips callback mappings without an rhs", function()
		local keymaps = {
			{ lhs = "<leader>er", callback = function() end },
			{ lhs = "<leader>eR", rhs = "" },
		}
		assert.is_nil(palette.find_keymap_for_command(keymaps, "FudeReviewReload"))
	end)

	it("returns nil when nothing matches", function()
		assert.is_nil(palette.find_keymap_for_command({}, "FudeReviewDiff"))
	end)
end)

describe("palette.build_palette_entries", function()
	local cmds = {
		{
			name = "FudeB",
			desc = "b",
			category = "PR",
			available = function()
				return true
			end,
		},
		{
			name = "FudeA",
			desc = "a",
			category = "Session",
			available = function(s)
				return s.active
			end,
		},
		{
			name = "FudeHidden",
			desc = "h",
			category = "Session",
			available = function()
				return true
			end,
			palette = false,
		},
		{
			name = "FudeC",
			desc = "c",
			category = "Session",
			available = function()
				return true
			end,
			range = true,
		},
	}

	it("filters by availability and hides palette=false entries", function()
		local entries = palette.build_palette_entries(cmds, { active = false }, {})
		local names = vim.tbl_map(function(e)
			return e.name
		end, entries)
		assert.are.same({ "FudeC", "FudeB" }, names)
	end)

	it("orders by category then registry order", function()
		local entries = palette.build_palette_entries(cmds, { active = true }, {})
		local names = vim.tbl_map(function(e)
			return e.name
		end, entries)
		assert.are.same({ "FudeA", "FudeC", "FudeB" }, names)
	end)

	it("attaches the detected key and range flag", function()
		local keymaps = { { lhs = "<leader>c", rhs = "<cmd>FudeC<cr>" } }
		local entries = palette.build_palette_entries(cmds, { active = false }, keymaps)
		assert.are.equal("<leader>c", entries[1].key)
		assert.is_true(entries[1].range)
		assert.is_nil(entries[2].key)
		assert.is_false(entries[2].range)
	end)

	it("puts unknown categories last", function()
		local entries = palette.build_palette_entries({
			{
				name = "FudeX",
				desc = "x",
				category = "Zzz",
				available = function()
					return true
				end,
			},
			{
				name = "FudeY",
				desc = "y",
				category = "PR",
				available = function()
					return true
				end,
			},
		}, {}, {})
		assert.are.equal("FudeY", entries[1].name)
		assert.are.equal("FudeX", entries[2].name)
	end)
end)

describe("palette.format_palette_entry", function()
	local entries = {
		{ name = "FudeA", desc = "Short", category = "PR" },
		{ name = "FudeLonger", desc = "A longer description", category = "Session", key = "<leader>x" },
	}

	it("computes column widths from the widest entry", function()
		local widths = palette.calculate_palette_widths(entries)
		assert.are.same({ category = 7, desc = 20, name = 11, key = 9 }, widths)
	end)

	it("reports a zero key width when no entry has a key", function()
		local widths = palette.calculate_palette_widths({ entries[1] })
		assert.are.equal(0, widths.key)
	end)
end)

describe("palette.calculate_palette_layout", function()
	local widths = { category = 8, desc = 40, name = 30, key = 0 }

	it("sizes the window to the widest row plus padding and the entry count", function()
		local layout = palette.calculate_palette_layout(widths, 20, 200, 60)
		-- (8+2) + 2 + 40 + 2 + 30 = 84, + 6 padding
		assert.are.same({ width = 90, height = 25 }, layout)
	end)

	it("adds the key column when present", function()
		local layout = palette.calculate_palette_layout({ category = 8, desc = 40, name = 30, key = 10 }, 20, 200, 60)
		assert.are.equal(102, layout.width)
	end)

	it("clamps to the editor size", function()
		local layout = palette.calculate_palette_layout(widths, 100, 60, 20)
		assert.are.same({ width = 56, height = 16 }, layout)
	end)

	it("never goes below the minimum size", function()
		local layout = palette.calculate_palette_layout({ category = 2, desc = 3, name = 5, key = 0 }, 1, 200, 60)
		assert.are.same({ width = 40, height = 6 }, layout)
	end)
end)

describe("palette.format_key_lhs", function()
	it("restores <leader> for the configured leader", function()
		assert.are.equal("<leader>eb", palette.format_key_lhs(" eb", " "))
		assert.are.equal("<leader>eb", palette.format_key_lhs(",eb", ","))
	end)

	it("uses the default backslash leader when mapleader is unset", function()
		assert.are.equal("<leader>eb", palette.format_key_lhs("\\eb", nil))
		assert.are.equal("<leader>eb", palette.format_key_lhs("\\eb", ""))
	end)

	it("leaves non-leader mappings unchanged", function()
		assert.are.equal("]c", palette.format_key_lhs("]c", " "))
		assert.are.equal("<C-p>", palette.format_key_lhs("<C-p>", "\\"))
	end)
end)

describe("palette.format_palette_entry (rows)", function()
	local entries = {
		{ name = "FudeA", desc = "Short", category = "PR" },
		{ name = "FudeLonger", desc = "A longer description", category = "Session", key = "<leader>x" },
	}

	it("aligns columns and appends the key when present", function()
		local widths = palette.calculate_palette_widths(entries)
		assert.are.equal("[PR]       Short                 :FudeA", palette.format_palette_entry(entries[1], widths))
		assert.are.equal(
			"[Session]  A longer description  :FudeLonger  <leader>x",
			palette.format_palette_entry(entries[2], widths)
		)
	end)
end)

describe("palette.open (vim.ui.select)", function()
	local orig_mode
	local orig_select
	local captured

	before_each(function()
		orig_mode = config.opts.file_list_mode
		orig_select = vim.ui.select
		config.opts.file_list_mode = "quickfix"
		captured = {}
		-- Capture command-table executions only; string commands (e.g. `normal!`)
		-- still run so visual-mode setup in tests and in resolve_visual_range works
		local orig_cmd = vim.cmd
		helpers.mock(vim, "cmd", function(c)
			if type(c) == "table" then
				table.insert(captured, c)
				return
			end
			return orig_cmd(c)
		end)
	end)

	after_each(function()
		vim.ui.select = orig_select
		config.opts.file_list_mode = orig_mode
		helpers.cleanup()
	end)

	local function select_named(name)
		vim.ui.select = function(items, _, on_choice)
			for _, item in ipairs(items) do
				if item.name == name then
					on_choice(item)
					return
				end
			end
			on_choice(nil)
		end
	end

	it("runs the chosen command through vim.cmd", function()
		select_named("FudeReviewStart")
		palette.open()
		assert.are.same({ { cmd = "FudeReviewStart" } }, captured)
	end)

	it("forwards the range to range commands only", function()
		config.state.active = true
		config.state.review_mode = "github"
		select_named("FudeReviewComment")
		palette.open({ range = { 2, 4 } })
		assert.are.same({ { cmd = "FudeReviewComment", range = { 2, 4 } } }, captured)

		captured = {}
		select_named("FudeReviewDiff")
		palette.open({ range = { 2, 4 } })
		assert.are.same({ { cmd = "FudeReviewDiff" } }, captured)
	end)

	it("derives the range from an active visual selection (<Cmd>FudeCommandPalette<CR> mapping)", function()
		config.state.active = true
		config.state.review_mode = "github"
		local buf = helpers.create_buf({ "a", "b", "c", "d" })
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		vim.cmd("normal! Vj")
		assert.are.equal("V", vim.fn.mode())

		select_named("FudeReviewSuggest")
		palette.open()
		assert.are.equal("n", vim.fn.mode())
		assert.are.same({ { cmd = "FudeReviewSuggest", range = { 2, 3 } } }, captured)
	end)

	it("offers only inactive-state commands before a session starts", function()
		local offered
		vim.ui.select = function(items, _, on_choice)
			offered = vim.tbl_map(function(i)
				return i.name
			end, items)
			on_choice(nil)
		end
		palette.open()
		local expected = palette.build_palette_entries(commands.list, { active = false }, {})
		assert.are.same(
			vim.tbl_map(function(e)
				return e.name
			end, expected),
			offered
		)
		assert.are.same({}, captured)
	end)

	it("does nothing when the selection is cancelled", function()
		vim.ui.select = function(_, _, on_choice)
			on_choice(nil)
		end
		palette.open()
		assert.are.same({}, captured)
	end)

	it("shows the user's own mapping next to the command", function()
		vim.keymap.set("n", "<leader>zz", "<cmd>FudeReviewStart<cr>")
		local shown
		vim.ui.select = function(items, opts, on_choice)
			for _, item in ipairs(items) do
				if item.name == "FudeReviewStart" then
					shown = opts.format_item(item)
				end
			end
			on_choice(nil)
		end
		local ok, err = pcall(palette.open)
		vim.keymap.del("n", "<leader>zz")
		assert.is_true(ok, tostring(err))
		assert.is_truthy(shown:find(":FudeReviewStart", 1, true))
		-- nvim_get_keymap expands <leader> (default "\"); the palette restores the token
		assert.is_truthy(shown:find("<leader>zz", 1, true))
	end)
end)
