local completion = require("fude.completion")

describe("completion.get_context", function()
	it("detects @mention at end of line", function()
		assert.are.equal("mention", completion.get_context("hello @flex"))
	end)

	it("detects bare @ trigger", function()
		assert.are.equal("mention", completion.get_context("cc @"))
	end)

	it("detects @mention with hyphen", function()
		assert.are.equal("mention", completion.get_context("@user-name"))
	end)

	it("detects @mention with underscore", function()
		assert.are.equal("mention", completion.get_context("ping @my_user"))
	end)

	it("detects #issue reference", function()
		assert.are.equal("issue", completion.get_context("fixes #12"))
	end)

	it("detects bare # trigger", function()
		assert.are.equal("issue", completion.get_context("see #"))
	end)

	it("returns nil for plain text", function()
		assert.is_nil(completion.get_context("hello world"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(completion.get_context(""))
	end)
end)
