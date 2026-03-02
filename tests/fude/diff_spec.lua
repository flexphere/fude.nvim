local diff = require("fude.diff")

describe("make_relative", function()
	it("strips root prefix", function()
		assert.are.equal("lua/foo.lua", diff.make_relative("/home/user/project/lua/foo.lua", "/home/user/project"))
	end)

	it("returns nil when filepath is not under root", function()
		assert.is_nil(diff.make_relative("/other/path/file.lua", "/home/user/project"))
	end)

	it("handles root at filesystem root", function()
		assert.are.equal("file.lua", diff.make_relative("//file.lua", "/"))
	end)

	it("returns nil for empty filepath", function()
		assert.is_nil(diff.make_relative("", "/root"))
	end)

	it("handles deeply nested paths", function()
		assert.are.equal("a/b/c/d.lua", diff.make_relative("/repo/a/b/c/d.lua", "/repo"))
	end)

	it("returns single filename for file directly under root", function()
		assert.are.equal("init.lua", diff.make_relative("/repo/init.lua", "/repo"))
	end)
end)
