local check = require("check_claude_md")

describe("check_claude_md.count_utf8_chars", function()
	it("counts ASCII characters", function()
		assert.equals(5, check.count_utf8_chars("hello"))
	end)

	it("returns 0 for an empty string", function()
		assert.equals(0, check.count_utf8_chars(""))
	end)

	it("counts multi-byte characters once each, not per byte", function()
		-- "日本語" is 9 bytes, "✓" 3 bytes, "→" 3 bytes
		local text = "日本語 ✓ → a"
		assert.equals(19, #text)
		assert.equals(9, check.count_utf8_chars(text))
	end)

	it("counts 4-byte characters once", function()
		assert.equals(2, check.count_utf8_chars("😀a"))
	end)
end)

describe("check_claude_md.is_within_limit", function()
	it("accepts a count below the limit", function()
		assert.is_true(check.is_within_limit(39999, 40000))
	end)

	it("accepts a count exactly at the limit", function()
		assert.is_true(check.is_within_limit(40000, 40000))
	end)

	it("rejects a count above the limit", function()
		assert.is_false(check.is_within_limit(40001, 40000))
	end)

	it("uses 40000 as the default limit", function()
		assert.equals(40000, check.MAX_CHARS)
	end)

	it("judges multi-byte text by characters, not bytes", function()
		-- 3 characters, 9 bytes
		local count = check.count_utf8_chars("日本語")
		assert.is_true(check.is_within_limit(count, 3))
		assert.is_false(check.is_within_limit(count, 2))
	end)
end)

describe("check_claude_md path mapping", function()
	it("maps a top-level module to its doc", function()
		assert.equals("init.md", check.module_to_doc("init.lua"))
	end)

	it("maps a nested module to its doc", function()
		assert.equals("local/session.md", check.module_to_doc("local/session.lua"))
	end)

	it("maps a doc back to its module", function()
		assert.equals("ui/sidepanel/tree.lua", check.doc_to_module("ui/sidepanel/tree.md"))
	end)

	it("returns nil for other extensions", function()
		assert.is_nil(check.module_to_doc("README.md"))
		assert.is_nil(check.doc_to_module("notes.txt"))
	end)

	it("strips the root prefix", function()
		assert.equals("local/session.lua", check.relative_to("lua/fude/local/session.lua", "lua/fude"))
		assert.equals("init.lua", check.relative_to("lua/fude/init.lua", "lua/fude/"))
	end)

	it("returns nil for a path outside the root or a sibling prefix", function()
		assert.is_nil(check.relative_to("lua/fudex/init.lua", "lua/fude"))
		assert.is_nil(check.relative_to("lua/fude/", "lua/fude"))
	end)
end)

describe("check_claude_md.find_mismatches", function()
	it("reports nothing when every module has a doc", function()
		local diff = check.find_mismatches({ "init.lua", "local/session.lua" }, { "local/session.md", "init.md" })
		assert.same({}, diff.missing)
		assert.same({}, diff.extra)
	end)

	it("reports a module without a doc as missing", function()
		local diff = check.find_mismatches({ "init.lua", "ui/format.lua", "chat.lua" }, { "init.md" })
		assert.same({ "chat.md", "ui/format.md" }, diff.missing)
		assert.same({}, diff.extra)
	end)

	it("reports a doc without a module as extra", function()
		local diff = check.find_mismatches({ "init.lua" }, { "init.md", "old/gone.md", "removed.md" })
		assert.same({}, diff.missing)
		assert.same({ "old/gone.md", "removed.md" }, diff.extra)
	end)

	it("does not match a doc in another directory", function()
		local diff = check.find_mismatches({ "ui/format.lua" }, { "format.md" })
		assert.same({ "ui/format.md" }, diff.missing)
		assert.same({ "format.md" }, diff.extra)
	end)

	it("treats an empty doc list as every module missing", function()
		local diff = check.find_mismatches({ "a.lua", "b.lua" }, {})
		assert.same({ "a.md", "b.md" }, diff.missing)
	end)
end)

describe("check_claude_md.format_report", function()
	it("reports OK with zero problems", function()
		local report, total = check.format_report({ char_count = 100, limit = 40000, missing = {}, extra = {} })
		assert.equals(0, total)
		assert.is_truthy(report:find("CLAUDE.md is 100 / 40000 characters", 1, true))
		assert.is_falsy(report:find("FAIL", 1, true))
	end)

	it("reports OK exactly at the limit", function()
		local _, total = check.format_report({ char_count = 40000, limit = 40000, missing = {}, extra = {} })
		assert.equals(0, total)
	end)

	it("reports the count and the limit when over", function()
		local report, total = check.format_report({ char_count = 40001, limit = 40000, missing = {}, extra = {} })
		assert.equals(1, total)
		assert.is_truthy(report:find("CLAUDE.md: 40001 characters exceeds the limit of 40000", 1, true))
		assert.is_truthy(report:find("FAIL: 1 problems found.", 1, true))
	end)

	it("names missing and extra docs with full paths", function()
		local report, total = check.format_report({
			char_count = 10,
			limit = 40000,
			missing = { "local/session.md" },
			extra = { "gone.md" },
		})
		assert.equals(2, total)
		assert.is_truthy(
			report:find("docs/architecture/local/session.md: missing (for lua/fude/local/session.lua)", 1, true)
		)
		assert.is_truthy(report:find("docs/architecture/gone.md: no lua/fude/gone.lua", 1, true))
	end)
end)
