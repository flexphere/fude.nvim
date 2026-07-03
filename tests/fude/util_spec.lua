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
