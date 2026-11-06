local util = require("fude.util")

describe("is_null", function()
	it("returns true for nil", function()
		assert.is_true(util.is_null(nil))
	end)

	it("returns true for vim.NIL", function()
		assert.is_true(util.is_null(vim.NIL))
	end)

	it("returns false for 0", function()
		assert.is_false(util.is_null(0))
	end)

	it("returns false for empty string", function()
		assert.is_false(util.is_null(""))
	end)

	it("returns false for false", function()
		assert.is_false(util.is_null(false))
	end)

	it("returns false for a number", function()
		assert.is_false(util.is_null(42))
	end)

	it("returns false for a string", function()
		assert.is_false(util.is_null("hello"))
	end)

	it("returns false for an empty table", function()
		assert.is_false(util.is_null({}))
	end)
end)

describe("null_to", function()
	it("replaces nil with the default", function()
		assert.are.equal("", util.null_to(nil, ""))
	end)

	it("replaces vim.NIL with the default", function()
		assert.are.equal("", util.null_to(vim.NIL, ""))
	end)

	it("can map null to nil (unlike the and-or idiom)", function()
		assert.is_nil(util.null_to(vim.NIL))
		assert.is_nil(util.null_to(nil))
	end)

	it("returns non-null values unchanged, including false and 0", function()
		assert.are.equal("x", util.null_to("x", ""))
		assert.are.equal(0, util.null_to(0, 99))
		assert.is_false(util.null_to(false, true))
	end)
end)

describe("path_less", function()
	it("orders uppercase before lowercase", function()
		assert.is_true(util.path_less("CLAUDE.md", "lua/a.lua"))
		assert.is_false(util.path_less("lua/a.lua", "CLAUDE.md"))
	end)

	it("orders a file before a same-named directory ('.' < '/')", function()
		assert.is_true(util.path_less("lua/ui.lua", "lua/ui/format.lua"))
		assert.is_false(util.path_less("lua/ui/format.lua", "lua/ui.lua"))
	end)

	it("orders a prefix before the longer path", function()
		assert.is_true(util.path_less("a", "a/b"))
		assert.is_false(util.path_less("a/b", "a"))
	end)

	it("returns false for equal paths", function()
		assert.is_false(util.path_less("a.lua", "a.lua"))
	end)
end)

describe("copy_to_clipboard", function()
	local saved
	before_each(function()
		saved = vim.fn.getreg('"')
	end)
	after_each(function()
		vim.fn.setreg('"', saved)
	end)

	it("sets the unnamed register and reports whether + was set", function()
		local copied = util.copy_to_clipboard("hello")
		assert.are.equal("hello", vim.fn.getreg('"'))
		assert.are.equal(vim.fn.has("clipboard") == 1, copied)
	end)
end)

describe("all_comments_resolved", function()
	it("returns false for an empty list", function()
		assert.is_false(util.all_comments_resolved({}))
	end)

	it("returns true when every comment is resolved", function()
		assert.is_true(util.all_comments_resolved({ { is_resolved = true }, { is_resolved = true } }))
	end)

	it("returns false when any comment is unresolved", function()
		assert.is_false(util.all_comments_resolved({ { is_resolved = true }, {} }))
	end)

	it("returns false when no comment is resolved", function()
		assert.is_false(util.all_comments_resolved({ {}, {} }))
	end)
end)

describe("open_url", function()
	local helpers = require("tests.helpers")
	local opened, notified
	before_each(function()
		opened, notified = {}, {}
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notified, { msg = msg, level = level })
		end)
	end)
	after_each(function()
		helpers.restore_all()
	end)

	it("opens the URL with vim.ui.open", function()
		helpers.mock(vim.ui, "open", function(url)
			table.insert(opened, url)
			return {}, nil
		end)
		assert.is_true(util.open_url("https://github.com/o/r/pull/1"))
		assert.are.same({ "https://github.com/o/r/pull/1" }, opened)
		assert.are.same({}, notified)
	end)

	it("shows the reason as INFO and opens nothing without a URL", function()
		helpers.mock(vim.ui, "open", function(url)
			table.insert(opened, url)
		end)
		assert.is_false(util.open_url(nil, "Local review comments are not on GitHub"))
		assert.is_false(util.open_url(""))
		assert.are.same({}, opened)
		assert.are.same({
			{ msg = "fude.nvim: Local review comments are not on GitHub", level = vim.log.levels.INFO },
			{ msg = "fude.nvim: Nothing to open in the browser", level = vim.log.levels.INFO },
		}, notified)
	end)

	it("reports an ERROR when vim.ui.open returns an error or throws", function()
		helpers.mock(vim.ui, "open", function()
			return nil, "no handler"
		end)
		assert.is_false(util.open_url("https://x"))
		helpers.mock(vim.ui, "open", function()
			error("boom")
		end)
		assert.is_false(util.open_url("https://y"))
		assert.are.equal(2, #notified)
		assert.are.equal("fude.nvim: Failed to open https://x: no handler", notified[1].msg)
		assert.are.equal(vim.log.levels.ERROR, notified[1].level)
		assert.truthy(notified[2].msg:find("Failed to open https://y: .*boom"))
	end)
end)

describe("reset_selection_on_prompt_change", function()
	it("should_reset_selection is true only when the prompt changed", function()
		assert.is_true(util.should_reset_selection("a", ""))
		assert.is_true(util.should_reset_selection("", "a"))
		assert.is_false(util.should_reset_selection("a", "a"))
	end)

	it("selects the first row when the prompt changed, else keeps the picker's strategy", function()
		local calls = {}
		local picker = {}
		function picker._do_selection(_, prompt)
			table.insert(calls, "own:" .. prompt)
		end
		function picker.get_reset_row()
			return 0
		end
		function picker.set_selection(_, row)
			table.insert(calls, "reset:" .. row)
		end
		assert.are.equal(picker, util.reset_selection_on_prompt_change(picker))

		picker:_do_selection("") -- first refresh: the picker's own strategy
		picker:_do_selection("") -- a refresh with the same prompt
		picker:_do_selection("a") -- typed
		picker:_do_selection("a") -- e.g. a <Tab> toggle refreshing the rows
		picker:_do_selection("") -- deleted
		assert.are.same({ "own:", "own:", "reset:0", "own:a", "reset:0" }, calls)
	end)

	it("leaves a picker without _do_selection alone", function()
		local picker = { find = function() end }
		assert.are.equal(picker, util.reset_selection_on_prompt_change(picker))
		assert.is_nil(picker._do_selection)
		assert.is_nil(util.reset_selection_on_prompt_change(nil))
	end)
end)
