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
