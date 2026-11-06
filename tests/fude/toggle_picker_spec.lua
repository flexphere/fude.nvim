local helpers = require("tests.helpers")
local toggle_picker = require("fude.ui.toggle_picker")

describe("toggle_picker.toggle_item", function()
	it("flips the item only after on_toggle reports success", function()
		local item = { text = "bug", on = false }
		local finish
		local opts = {
			on_toggle = function(_, done)
				finish = done
			end,
		}
		assert.is_true(toggle_picker.toggle_item(item, opts, toggle_picker.new_session(opts)))
		assert.is_false(item.on)
		finish(true)
		assert.is_true(item.on)
	end)

	it("keeps the item as it was when on_toggle fails", function()
		local item = { text = "bug", on = true }
		local ok_seen
		local opts = {
			on_toggle = function(_, done)
				done(false)
			end,
		}
		toggle_picker.toggle_item(item, opts, toggle_picker.new_session(opts), function(ok)
			ok_seen = ok
		end)
		assert.is_true(item.on)
		assert.is_false(ok_seen)
	end)

	it("ignores a second toggle while the first request is in flight", function()
		local item = { text = "bug", on = false }
		local calls = 0
		local finish
		local opts = {
			on_toggle = function(_, done)
				calls = calls + 1
				finish = done
			end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item(item, opts, session)
		assert.is_false(toggle_picker.toggle_item(item, opts, session))
		assert.are.equal(1, calls)
		finish(true)
		-- Settled: the next toggle is sent again
		assert.is_true(toggle_picker.toggle_item(item, opts, session))
		assert.are.equal(2, calls)
	end)

	it("does nothing for a nil item", function()
		local opts = {
			on_toggle = function()
				error("must not be called")
			end,
		}
		assert.is_false(toggle_picker.toggle_item(nil, opts, toggle_picker.new_session(opts)))
	end)
end)

describe("toggle_picker.resolve_mark", function()
	it("shows the loading mark while the item's request is in flight, then the item's own mark", function()
		local item = { text = "bug", on = false }
		local finish
		local opts = {
			on_toggle = function(_, done)
				finish = done
			end,
		}
		local session = toggle_picker.new_session(opts)
		assert.are.same({ "○", "Comment" }, { toggle_picker.resolve_mark(item, session) })
		toggle_picker.toggle_item(item, opts, session)
		assert.are.same(
			{ toggle_picker.LOADING_MARK, toggle_picker.LOADING_HL },
			{ toggle_picker.resolve_mark(item, session) }
		)
		finish(true)
		assert.are.same({ "●", "DiagnosticOk" }, { toggle_picker.resolve_mark(item, session) })
	end)

	it("drops the loading mark after a failed request, keeping the old mark", function()
		local item = { text = "bug", on = true }
		local finish
		local opts = {
			on_toggle = function(_, done)
				finish = done
			end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item(item, opts, session)
		assert.are.equal(toggle_picker.LOADING_MARK, (toggle_picker.resolve_mark(item, session)))
		finish(false)
		assert.are.same({ "●", "DiagnosticOk" }, { toggle_picker.resolve_mark(item, session) })
	end)

	it("keeps the item's name highlight under the loading mark and ignores other items' requests", function()
		local item = {
			text = "@bob",
			on = false,
			mark = function()
				return "✓", "DiagnosticOk", "DiagnosticOk"
			end,
		}
		local other = { text = "@alice", on = false }
		local opts = {
			on_toggle = function() end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item(other, opts, session)
		assert.are.same({ "✓", "DiagnosticOk", "DiagnosticOk" }, { toggle_picker.resolve_mark(item, session) })
		toggle_picker.toggle_item(item, opts, session)
		assert.are.same(
			{ toggle_picker.LOADING_MARK, toggle_picker.LOADING_HL, "DiagnosticOk" },
			{ toggle_picker.resolve_mark(item, session) }
		)
		-- Without a session nothing is ever loading
		assert.are.same({ "✓", "DiagnosticOk", "DiagnosticOk" }, { toggle_picker.resolve_mark(item) })
	end)
end)

describe("toggle_picker.new_session", function()
	it("runs on_close only after the in-flight request settled", function()
		local closed = 0
		local finish
		local opts = {
			on_toggle = function(_, done)
				finish = done
			end,
			on_close = function()
				closed = closed + 1
			end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item({ text = "bug", on = false }, opts, session)
		session.close()
		assert.are.equal(0, closed)
		finish(true)
		assert.are.equal(1, closed)
	end)

	it("runs on_close at once without a request in flight, and only once", function()
		local closed = 0
		local session = toggle_picker.new_session({
			on_close = function()
				closed = closed + 1
			end,
		})
		session.close()
		session.close()
		assert.are.equal(1, closed)
	end)
end)

describe("toggle_picker.show_vim_select", function()
	local config = require("fude.config")
	local orig_select

	before_each(function()
		config.setup({ file_list_mode = "quickfix" })
		orig_select = vim.ui.select
	end)

	after_each(function()
		vim.ui.select = orig_select
		helpers.cleanup()
	end)

	it("toggles the chosen item and reopens the select until it is cancelled", function()
		local items = { { text = "bug", on = false }, { text = "docs", on = true } }
		local shown = {}
		local choices = { items[1], nil }
		local call = 0
		vim.ui.select = function(list, opts, on_choice)
			call = call + 1
			local lines = {}
			for _, item in ipairs(list) do
				table.insert(lines, opts.format_item(item))
			end
			table.insert(shown, lines)
			on_choice(choices[call])
		end
		local closed = 0
		toggle_picker.open({
			title = "Labels",
			items = items,
			on_toggle = function(_, done)
				done(true)
			end,
			on_close = function()
				closed = closed + 1
			end,
		})

		assert.are.same({ { "○ bug", "● docs" }, { "● bug", "● docs" } }, shown)
		assert.is_true(items[1].on)
		assert.are.equal(1, closed)
	end)

	it("closes instead of reopening when is_alive turns false", function()
		local calls = 0
		vim.ui.select = function(list, _, on_choice)
			calls = calls + 1
			on_choice(list[1])
		end
		local closed = false
		toggle_picker.open({
			title = "Labels",
			items = { { text = "bug", on = false } },
			is_alive = function()
				return false
			end,
			on_toggle = function(_, done)
				done(false)
			end,
			on_close = function()
				closed = true
			end,
		})
		assert.are.equal(1, calls)
		assert.is_true(closed)
	end)

	it("calls on_close without toggling when the first select is cancelled", function()
		vim.ui.select = function(_, _, on_choice)
			on_choice(nil)
		end
		local toggled, closed = false, false
		toggle_picker.open({
			title = "Labels",
			items = { { text = "bug", on = false } },
			on_toggle = function()
				toggled = true
			end,
			on_close = function()
				closed = true
			end,
		})
		assert.is_false(toggled)
		assert.is_true(closed)
	end)
end)

--- Install fake picker plugins so the Telescope / snacks adapters can run
--- without the real plugins, and return a function restoring package.loaded.
--- @param fakes table<string, table> module name -> module
--- @return fun()
local function install_fakes(fakes)
	local saved = {}
	for name, mod in pairs(fakes) do
		saved[name] = package.loaded[name]
		package.loaded[name] = mod
	end
	return function()
		for name, _ in pairs(fakes) do
			package.loaded[name] = saved[name]
		end
	end
end

describe("toggle_picker loading re-render", function()
	local config = require("fude.config")
	local restore_fakes

	after_each(function()
		if restore_fakes then
			restore_fakes()
			restore_fakes = nil
		end
		helpers.cleanup()
	end)

	it("snacks: re-renders when the request starts and again once it settled, success or not", function()
		config.setup({ file_list_mode = "snacks" })
		local picked
		restore_fakes = install_fakes({
			["snacks.picker"] = {
				pick = function(popts)
					picked = popts
				end,
			},
		})
		local item = { text = "bug", on = false }
		local finish
		toggle_picker.open({
			title = "Labels",
			items = { item },
			on_toggle = function(_, done)
				finish = done
			end,
		})
		local updates = 0
		local picker = {
			closed = false,
			list = {
				update = function()
					updates = updates + 1
				end,
			},
		}

		picked.actions.fude_toggle(picker, item)
		assert.are.equal(1, updates)
		assert.are.equal(toggle_picker.LOADING_MARK, picked.format(item)[1][1]:sub(1, #toggle_picker.LOADING_MARK))
		finish(false)
		assert.are.equal(2, updates)
		assert.are.equal("○ ", picked.format(item)[1][1])

		-- A toggle ignored (nil item) re-renders nothing
		picked.actions.fude_toggle(picker, nil)
		assert.are.equal(2, updates)

		picked.actions.fude_toggle(picker, item)
		assert.are.equal(3, updates)
		finish(true)
		assert.are.equal(4, updates)
		assert.are.equal("● ", picked.format(item)[1][1])
	end)

	it("telescope: refreshes when the request starts and again once it settled, success or not", function()
		config.setup({ file_list_mode = "telescope" })
		local prompt_buf = helpers.create_buf()
		local item = { text = "bug", on = false }
		local picker = { refreshes = 0, maps = {}, selected = { value = item } }
		function picker.refresh(self)
			self.refreshes = self.refreshes + 1
		end
		function picker.get_selection_row()
			return 0
		end
		function picker._get_prompt()
			return ""
		end
		function picker.register_completion_callback() end
		function picker.find(self)
			self.opts.attach_mappings(prompt_buf, function(mode, lhs, fn)
				self.maps[mode .. lhs] = fn
			end)
		end
		restore_fakes = install_fakes({
			["telescope.pickers"] = {
				new = function(_, popts)
					picker.opts = popts
					return picker
				end,
			},
			["telescope.finders"] = {
				new_table = function(o)
					return o
				end,
			},
			["telescope.config"] = { values = { generic_sorter = function() end } },
			["telescope.actions"] = { select_default = { replace = function() end }, close = function() end },
			["telescope.actions.state"] = {
				get_selected_entry = function()
					return picker.selected
				end,
				get_current_picker = function()
					return picker
				end,
			},
			["telescope.themes"] = {
				get_dropdown = function(o)
					return o
				end,
			},
		})
		local finish
		toggle_picker.open({
			title = "Labels",
			items = { item },
			on_toggle = function(_, done)
				finish = done
			end,
		})
		local function displayed()
			local entry = picker.opts.finder.entry_maker(item)
			return (entry.display(entry))
		end

		picker.maps["i<Tab>"]()
		assert.are.equal(1, picker.refreshes)
		assert.are.equal(toggle_picker.LOADING_MARK .. " bug", displayed())
		finish(false)
		assert.are.equal(2, picker.refreshes)
		assert.are.equal("○ bug", displayed())

		-- A toggle ignored (no selection) refreshes nothing
		picker.selected = nil
		picker.maps["n<Tab>"]()
		assert.are.equal(2, picker.refreshes)
		picker.selected = { value = item }

		picker.maps["n<Tab>"]()
		assert.are.equal(3, picker.refreshes)
		finish(true)
		assert.are.equal(4, picker.refreshes)
		assert.are.equal("● bug", displayed())
	end)
end)

describe("toggle_picker extra action", function()
	local notified
	local function make_opts(available, run)
		return {
			extra_action = {
				key = "<C-e>",
				label = "re-request",
				available = available,
				unavailable_reason = function(item)
					return item.text .. " cannot"
				end,
				run = run or function(_, done)
					done(true)
				end,
				result_on = true,
			},
		}
	end

	before_each(function()
		notified = {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notified, { msg = msg, level = level })
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("shows the key at the end of a row it applies to, and nothing elsewhere", function()
		local opts = make_opts(function(item)
			return not item.on
		end)
		assert.are.same(
			{ "<C-e>: re-request", "Special" },
			{ toggle_picker.resolve_action_hint({ text = "@bob", on = false }, opts) }
		)
		assert.is_nil(toggle_picker.resolve_action_hint({ text = "@bob", on = true }, opts))
		assert.is_nil(toggle_picker.resolve_action_hint({ text = "@bob", on = false }, {}))
	end)

	it("uses hint_hl for the hint's highlight when given", function()
		local opts = make_opts(function()
			return true
		end)
		opts.extra_action.hint_hl = function(item)
			return item.grey and "Comment" or nil
		end
		assert.are.same(
			{ "<C-e>: re-request", "Comment" },
			{ toggle_picker.resolve_action_hint({ text = "@bob", on = false, grey = true }, opts) }
		)
		assert.are.same(
			{ "<C-e>: re-request", "Special" },
			{ toggle_picker.resolve_action_hint({ text = "@bob", on = false }, opts) }
		)
	end)

	it("sets item.on to result_on only after the request succeeded", function()
		local finish
		local opts = make_opts(function()
			return true
		end, function(_, done)
			finish = done
		end)
		local item = { text = "@bob", on = false }
		assert.is_true(toggle_picker.run_extra_action(item, opts, toggle_picker.new_session(opts)))
		assert.is_false(item.on)
		finish(true)
		assert.is_true(item.on)
	end)

	it("refuses a row it does not apply to with an INFO and sends nothing", function()
		local sent = false
		local opts = make_opts(function()
			return false
		end, function()
			sent = true
		end)
		local item = { text = "@bob", on = true }
		assert.is_false(toggle_picker.run_extra_action(item, opts, toggle_picker.new_session(opts)))
		assert.is_false(sent)
		assert.are.same({ { msg = "fude.nvim: @bob cannot", level = vim.log.levels.INFO } }, notified)
	end)
end)
