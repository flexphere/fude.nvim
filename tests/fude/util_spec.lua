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
