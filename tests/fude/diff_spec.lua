local diff = require("fude.diff")

describe("parse_log_first_subject", function()
	it("returns first line from single-line output", function()
		assert.are.equal("Add feature X", diff.parse_log_first_subject("Add feature X\n"))
	end)

	it("returns first line from multi-line output", function()
		assert.are.equal("First commit", diff.parse_log_first_subject("First commit\nSecond commit\n"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(diff.parse_log_first_subject(""))
	end)

	it("returns nil for nil input", function()
		assert.is_nil(diff.parse_log_first_subject(nil))
	end)

	it("returns nil for empty first line", function()
		assert.is_nil(diff.parse_log_first_subject("\nSecond line"))
	end)

	it("returns nil for whitespace-only first line", function()
		assert.is_nil(diff.parse_log_first_subject("   \nSecond line"))
	end)

	it("trims whitespace from subject", function()
		assert.are.equal("Trimmed subject", diff.parse_log_first_subject("  Trimmed subject  \n"))
	end)

	it("truncates subject exceeding 100 characters", function()
		local long_subject = string.rep("a", 150)
		local result = diff.parse_log_first_subject(long_subject)
		assert.are.equal(100, #result)
		assert.are.equal(string.rep("a", 100), result)
	end)

	it("does not truncate subject at exactly 100 characters", function()
		local exact_subject = string.rep("b", 100)
		assert.are.equal(exact_subject, diff.parse_log_first_subject(exact_subject))
	end)

	it("handles CRLF line endings", function()
		assert.are.equal("Windows commit", diff.parse_log_first_subject("Windows commit\r\nNext line"))
	end)

	it("handles output without trailing newline", function()
		assert.are.equal("No newline", diff.parse_log_first_subject("No newline"))
	end)
end)

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

describe("to_repo_relative", function()
	local original_system

	before_each(function()
		original_system = vim.system
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 0, stdout = "/repo\n" }
				end,
			}
		end
	end)

	after_each(function()
		vim.system = original_system
	end)

	it("returns nil for empty string filepath", function()
		assert.is_nil(diff.to_repo_relative(""))
	end)

	it("returns nil for nil filepath", function()
		assert.is_nil(diff.to_repo_relative(nil))
	end)

	it("returns nil when make_relative yields empty string (repo root path)", function()
		-- fnamemodify("/repo/", ":p") = "/repo/" → make_relative("/repo/", "/repo") = ""
		assert.is_nil(diff.to_repo_relative("/repo/"))
	end)
end)

describe("get_merge_base", function()
	local original_system

	before_each(function()
		original_system = vim.system
	end)

	after_each(function()
		vim.system = original_system
	end)

	it("returns merge-base SHA when ref succeeds", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					if cmd[3] == "main" then
						return { code = 0, stdout = "abc123def456\n" }
					end
					return { code = 1 }
				end,
			}
		end
		assert.are.equal("abc123def456", diff.get_merge_base("main"))
	end)

	it("falls back to origin/<ref> when ref fails", function()
		vim.system = function(cmd, _opts)
			return {
				wait = function()
					if cmd[3] == "main" then
						return { code = 1 }
					elseif cmd[3] == "origin/main" then
						return { code = 0, stdout = "fallback789\n" }
					end
					return { code = 1 }
				end,
			}
		end
		assert.are.equal("fallback789", diff.get_merge_base("main"))
	end)

	it("returns nil when both ref and origin/<ref> fail", function()
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 1 }
				end,
			}
		end
		assert.is_nil(diff.get_merge_base("nonexistent"))
	end)

	it("trims whitespace from output", function()
		vim.system = function(_cmd, _opts)
			return {
				wait = function()
					return { code = 0, stdout = "  sha_with_spaces  \n" }
				end,
			}
		end
		assert.are.equal("sha_with_spaces", diff.get_merge_base("main"))
	end)
end)
