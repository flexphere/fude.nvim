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
		assert.are.same({ "⣾", toggle_picker.LOADING_HL }, { toggle_picker.resolve_mark(item, session) })
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
		assert.are.equal("⣾", (toggle_picker.resolve_mark(item, session)))
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
		assert.are.same({ "⣾", toggle_picker.LOADING_HL, "DiagnosticOk" }, { toggle_picker.resolve_mark(item, session) })
		-- Without a session nothing is ever loading
		assert.are.same({ "✓", "DiagnosticOk", "DiagnosticOk" }, { toggle_picker.resolve_mark(item) })
	end)

	it("pads the spinner to the width of the mark it replaces, so a 💬 row's name does not move", function()
		local item = {
			text = "@bob",
			on = false,
			mark = function()
				return "💬", "Normal", "Comment"
			end,
		}
		local opts = {
			on_toggle = function() end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item(item, opts, session)
		local mark = toggle_picker.resolve_mark(item, session)
		assert.are.equal("⣾ ", mark)
		assert.are.equal(vim.fn.strdisplaywidth("💬"), vim.fn.strdisplaywidth(mark))
		-- A one-cell mark gets no padding
		assert.are.equal("⣾", toggle_picker.format_loading_mark(1, 1))
		assert.are.equal("⣾", toggle_picker.format_loading_mark(1))
	end)

	it("follows the session's frame through the one-cell braille spinner, looping", function()
		assert.are.same({ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷", "⣾" }, {
			toggle_picker.format_loading_mark(1),
			toggle_picker.format_loading_mark(2),
			toggle_picker.format_loading_mark(3),
			toggle_picker.format_loading_mark(4),
			toggle_picker.format_loading_mark(5),
			toggle_picker.format_loading_mark(6),
			toggle_picker.format_loading_mark(7),
			toggle_picker.format_loading_mark(8),
			toggle_picker.format_loading_mark(9),
		})
		-- Every frame is one cell wide, like the marks it replaces
		for _, frame in ipairs(toggle_picker.LOADING_FRAMES) do
			assert.are.equal(1, vim.fn.strdisplaywidth(frame), frame)
		end
		local item = { text = "bug", on = false }
		local opts = {
			on_toggle = function() end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item(item, opts, session)
		assert.are.equal("⣾", (toggle_picker.resolve_mark(item, session)))
		session.tick()
		assert.are.equal("⣽", (toggle_picker.resolve_mark(item, session)))
		for _ = 1, 7 do
			session.tick()
		end
		assert.are.equal("⣾", (toggle_picker.resolve_mark(item, session)))
	end)
end)

describe("toggle_picker spinner timer", function()
	local timers

	--- A fake vim.uv timer recording start / stop / close.
	local function fake_timer()
		local t = { started = nil, stopped = false, closed = false }
		function t.start(self, timeout, rep, cb)
			self.started = { timeout = timeout, rep = rep, cb = cb }
		end
		function t.stop(self)
			self.stopped = true
		end
		function t.close(self)
			self.closed = true
		end
		table.insert(timers, t)
		return t
	end

	before_each(function()
		timers = {}
		helpers.mock(vim.uv, "new_timer", fake_timer)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("runs from the first in-flight request to the last, re-rendering on every tick", function()
		local finishes = {}
		local opts = {
			on_toggle = function(_, done)
				table.insert(finishes, done)
			end,
		}
		local session = toggle_picker.new_session(opts)
		local renders = 0
		session.rerender = function()
			renders = renders + 1
		end
		local a, b = { text = "a", on = false }, { text = "b", on = false }

		toggle_picker.toggle_item(a, opts, session)
		assert.are.equal(1, #timers)
		assert.are.equal(toggle_picker.LOADING_INTERVAL_MS, timers[1].started.timeout)
		assert.are.equal(toggle_picker.LOADING_INTERVAL_MS, timers[1].started.rep)
		-- A second request joins the running spinner
		toggle_picker.toggle_item(b, opts, session)
		assert.are.equal(1, #timers)

		timers[1].started.cb()
		assert.is_true(helpers.wait_for(function()
			return renders == 1
		end))
		assert.are.equal(2, session.frame)

		finishes[1](true)
		assert.is_false(timers[1].stopped)
		finishes[2](true)
		assert.is_true(timers[1].stopped)
		assert.is_true(timers[1].closed)

		-- The next request starts a new spinner
		toggle_picker.toggle_item(a, opts, session)
		assert.are.equal(2, #timers)
	end)

	it("stops when the picker closes while a request is in flight", function()
		local opts = {
			on_toggle = function() end,
		}
		local session = toggle_picker.new_session(opts)
		session.rerender = function() end
		toggle_picker.toggle_item({ text = "a", on = false }, opts, session)
		assert.are.equal(1, #timers)
		session.close()
		assert.is_true(timers[1].stopped)
		assert.is_true(timers[1].closed)
	end)

	it("does not start without a rerender (vim.ui.select mode)", function()
		local opts = {
			on_toggle = function() end,
		}
		local session = toggle_picker.new_session(opts)
		toggle_picker.toggle_item({ text = "a", on = false }, opts, session)
		assert.are.equal(0, #timers)
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
		-- Ties are broken by the item order, not by the text length
		assert.are.same({ "score:desc", "idx" }, picked.sort.fields)
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
		assert.are.equal("⣾ ", picked.format(item)[1][1])
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

		-- Telescope keeps the selected entry across the refreshes below
		-- instead of moving the cursor back to the first row
		assert.are.equal("follow", picker.opts.selection_strategy)
		-- Rows of the same score keep the order they were given in (applied
		-- labels first), instead of Telescope's shortest-name-first default
		assert.is_false(picker.opts.tiebreak({ ordinal = "a" }, { ordinal = "longer" }, ""))

		picker.maps["i<Tab>"]()
		assert.are.equal(1, picker.refreshes)
		assert.are.equal("⣾ bug", displayed())
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

describe("toggle_picker row images", function()
	local config = require("fude.config")
	local restore_fakes
	local placed, cleaned, closed

	--- A fake snacks image module recording placements (each a table whose
	--- close() records its index in `closed`).
	local function fake_snacks_image()
		placed, cleaned, closed = {}, {}, {}
		return {
			image = {
				supports_terminal = function()
					return true
				end,
				placement = {
					new = function(buf, file, opts)
						local placement = { buf = buf, file = file, opts = opts, id = #placed + 1 }
						function placement.close(self)
							table.insert(closed, self.id)
						end
						table.insert(placed, placement)
						return placement
					end,
					clean = function(buf)
						table.insert(cleaned, buf)
					end,
				},
			},
		}
	end

	after_each(function()
		if restore_fakes then
			restore_fakes()
			restore_fakes = nil
		end
		helpers.cleanup()
	end)

	it("place_row_images drops the buffer's placements and places one per row with a known file", function()
		restore_fakes = install_fakes({ ["snacks"] = fake_snacks_image() })
		local buf = helpers.create_buf({ "a", "b", "c" })
		local a, b, c = { text = "a" }, { text = "b" }, { text = "c" }
		local session = toggle_picker.new_session({})
		session.images[a] = "/cache/a.png"
		session.images[b] = false
		toggle_picker.place_row_images(
			buf,
			{ { row = 1, item = a }, { row = 2, item = b }, { row = 3, item = c } },
			session
		)
		assert.are.same({ buf }, cleaned)
		assert.are.equal(1, #placed)
		assert.are.same(
			{ buf = buf, file = "/cache/a.png", opts = { pos = { 1, 0 }, inline = true, height = 1, width = 2 } },
			{ buf = placed[1].buf, file = placed[1].file, opts = placed[1].opts }
		)
		assert.are.equal(placed[1], session.placed[buf][1])

		-- `only`: the given rows' placements are closed and made again, the
		-- buffer's other placements and the buffer itself are left alone
		session.images[c] = "/cache/c.png"
		toggle_picker.place_row_images(buf, { { row = 1, item = a }, { row = 3, item = c } }, session, { only = true })
		assert.are.same({ buf }, cleaned)
		assert.are.same({ 1 }, closed)
		assert.are.equal(3, #placed)
		assert.are.same({ { 1, 0 }, { 3, 0 } }, { placed[2].opts.pos, placed[3].opts.pos })
		assert.are.same({ placed[2], placed[3] }, { session.placed[buf][1], session.placed[buf][3] })
		-- Without snacks nothing happens
		restore_fakes()
		restore_fakes = install_fakes({ ["snacks"] = nil })
		toggle_picker.place_row_images(buf, { { row = 1, item = a } }, session)
		assert.are.equal(3, #placed)
	end)

	it("load_images asks once per item and re-renders once per batch of answers", function()
		local asked = {}
		local answers = {}
		local items = { { text = "a" }, { text = "b" } }
		local opts = {
			items = items,
			images = function(item, cb)
				table.insert(asked, item.text)
				answers[item.text] = cb
			end,
		}
		local session = toggle_picker.new_session(opts)
		local renders = 0
		session.rerender = function()
			renders = renders + 1
		end
		session.load_images()
		assert.are.same({ "a", "b" }, asked)
		answers.a("/cache/a.png")
		answers.b(nil)
		assert.are.equal("/cache/a.png", session.images[items[1]])
		assert.is_false(session.images[items[2]])
		assert.is_true(helpers.wait_for(function()
			return renders == 1
		end))
		vim.wait(50)
		assert.are.equal(1, renders)
	end)

	it("snacks: places the rows' images after each dirty render", function()
		config.setup({ file_list_mode = "snacks" })
		local snacks = fake_snacks_image()
		local list_buf = helpers.create_buf({ "", "" })
		local items = { { text = "a" }, { text = "b" } }
		local list = { dirty = true, win = { buf = list_buf }, renders = 0 }
		function list.render(self)
			self.renders = self.renders + 1
			self.dirty = false
		end
		function list.height()
			return 2
		end
		function list.row2idx(_, row)
			return row
		end
		function list.get(_, idx)
			return items[idx]
		end
		function list.update(self)
			self.dirty = true
			self:render()
		end
		local picker = { list = list, closed = false }
		local picked
		snacks.picker = {
			pick = function(popts)
				picked = popts
				return picker
			end,
		}
		restore_fakes = install_fakes({ ["snacks"] = snacks, ["snacks.picker"] = snacks.picker })
		local answers = {}
		toggle_picker.open({
			title = "Reviewers",
			items = items,
			on_toggle = function() end,
			images = function(item, cb)
				answers[item.text] = cb
			end,
		})
		assert.is_not_nil(picked)
		-- The wrapped render places nothing until a file is known
		list:render()
		assert.are.equal(0, #placed)
		answers.a("/cache/a.png")
		assert.is_true(helpers.wait_for(function()
			return #placed == 1
		end))
		assert.are.same({ list_buf, list_buf }, cleaned)
		assert.are.same({ 1, 0 }, placed[1].opts.pos)
		-- A render that is not dirty leaves the placements alone
		list:render()
		assert.are.equal(1, #placed)
	end)

	it("telescope: places the rows' images once a refresh completed", function()
		config.setup({ file_list_mode = "telescope" })
		local prompt_buf = helpers.create_buf()
		local results_buf = helpers.create_buf({ "x", "y" })
		local items = { { text = "a" }, { text = "b" } }
		local entries = { { value = items[1] }, { value = items[2] } }
		local picker = { results_bufnr = results_buf, refreshes = 0, maps = {}, completion = nil }
		picker.manager = {
			get_entry = function(_, index)
				return entries[index]
			end,
		}
		function picker.get_index(_, row)
			return row + 1
		end
		picker.selection_row = 0
		function picker.get_selection_row(self)
			return self.selection_row
		end
		function picker.set_selection(self, row)
			-- Telescope rewrites the old and the new row to move the caret
			self.selection_row = row
		end
		function picker.refresh(self)
			self.refreshes = self.refreshes + 1
			if self.completion then
				self.completion(self)
			end
		end
		function picker.register_completion_callback(self, cb)
			self.completion = cb
		end
		function picker.find(self)
			self.opts.attach_mappings(prompt_buf, function(mode, lhs, fn)
				self.maps[mode .. lhs] = fn
			end)
			self.completion(self)
		end
		local snacks = fake_snacks_image()
		restore_fakes = install_fakes({
			["snacks"] = snacks,
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
					return nil
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
		local answers = {}
		toggle_picker.open({
			title = "Reviewers",
			items = items,
			on_toggle = function() end,
			images = function(item, cb)
				answers[item.text] = cb
			end,
		})
		-- The first render placed nothing (no file known yet) but cleaned
		assert.are.equal(0, #placed)
		assert.are.same({ results_buf }, cleaned)
		answers.b("/cache/b.png")
		assert.is_true(helpers.wait_for(function()
			return #placed == 1
		end))
		assert.are.equal(1, picker.refreshes)
		assert.are.same({ buf = results_buf, file = "/cache/b.png" }, { buf = placed[1].buf, file = placed[1].file })
		assert.are.same({ 2, 0 }, placed[1].opts.pos)

		-- Moving the selection onto row 2 (b) and back redraws b's image each
		-- time without cleaning the buffer; a has no file, so nothing for it
		local cleans = #cleaned
		picker:set_selection(1)
		assert.are.equal(1, picker.selection_row)
		assert.are.same({ 1 }, closed)
		assert.are.equal(2, #placed)
		assert.are.same({ 2, 0 }, placed[2].opts.pos)
		picker:set_selection(0)
		assert.are.same({ 1, 2 }, closed)
		assert.are.equal(3, #placed)
		assert.are.same({ 2, 0 }, placed[3].opts.pos)
		assert.are.equal(cleans, #cleaned)
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
