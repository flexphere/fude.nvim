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
