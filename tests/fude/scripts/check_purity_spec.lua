local check = require("check_purity")

describe("check_purity.strip_comments_strings", function()
	it("blanks line comments while preserving following code", function()
		local stripped = check.strip_comments_strings("-- vim.api.foo()\nlocal x = 1\n")
		assert.is_falsy(stripped:find("vim%.api"))
		assert.is_truthy(stripped:find("local x"))
	end)

	it("blanks block comments", function()
		local stripped = check.strip_comments_strings("--[[ vim.fn.expand ]]\nlocal x\n")
		assert.is_falsy(stripped:find("vim%.fn"))
	end)

	it("blanks double-quoted strings", function()
		local stripped = check.strip_comments_strings('local x = "vim.api.nvim_buf_set_lines"')
		assert.is_falsy(stripped:find("vim%.api"))
	end)
end)

describe("check_purity.scan_file_text", function()
	local function violations_of(src)
		return check.scan_file_text(src, "test.lua")
	end

	it("detects vim.api.* access", function()
		local v = violations_of("local b = vim.api.nvim_get_current_buf()\n")
		assert.are.equal(1, #v)
		assert.are.equal(1, v[1].line)
		assert.is_truthy(v[1].pattern:find("vim%.api"))
	end)

	it("detects vim.fn.* access", function()
		local v = violations_of("local w = vim.fn.strdisplaywidth(s)\n")
		assert.are.equal(1, #v)
		assert.is_truthy(v[1].pattern:find("vim%.fn"))
	end)

	it("detects vim.cmd as function and command form", function()
		local v1 = violations_of("vim.cmd('set nowrap')\n")
		local v2 = violations_of('vim.cmd "set nowrap"\n')
		assert.are.equal(1, #v1)
		assert.are.equal(1, #v2)
	end)

	it("detects vim.notify, vim.schedule, vim.system", function()
		assert.are.equal(1, #violations_of("vim.notify('hello')\n"))
		assert.are.equal(1, #violations_of("vim.schedule(function() end)\n"))
		assert.are.equal(1, #violations_of("vim.system({ 'ls' })\n"))
	end)

	it("detects vim.o, vim.bo, vim.wo, vim.opt option access via . and [", function()
		assert.are.equal(1, #violations_of("vim.o.diffopt = 'x'\n"))
		assert.are.equal(1, #violations_of("vim.bo[buf].buftype = 'nofile'\n"))
		assert.are.equal(1, #violations_of("vim.wo[win].number = false\n"))
		assert.are.equal(1, #violations_of("vim.opt.shell = 'bash'\n"))
	end)

	it("detects vim.keymap.*", function()
		local v = violations_of("vim.keymap.set('n', 'q', cb)\n")
		assert.are.equal(1, #v)
	end)

	it("detects config.state direct access", function()
		local v = violations_of("local x = config.state.foo\n")
		assert.are.equal(1, #v)
		assert.is_truthy(v[1].pattern:find("config%.state"))
	end)

	it("detects config.state alias binding", function()
		local v = violations_of("local state = config.state\n")
		assert.are.equal(1, #v)
	end)

	it("does NOT flag vim.tbl_keys / vim.deepcopy / vim.split / vim.NIL", function()
		local src = "local ks = vim.tbl_keys(t)\n"
			.. "local copy = vim.deepcopy(x)\n"
			.. "local parts = vim.split(s, '\\n')\n"
			.. "local n = vim.NIL\n"
			.. "local n2 = vim.list_extend(a, b)\n"
		assert.are.equal(0, #violations_of(src))
	end)

	it("flags vim.cmd even when preceded by another identifier (known limitation)", function()
		-- Document the limitation: we do NOT word-boundary on the prefix side of
		-- `vim.<api>`. `self.vim.cmd(...)` is still flagged as a vim.cmd violation.
		-- Acceptable because no module in this codebase has a sub-table named `vim`.
		assert.are.equal(1, #violations_of("local x = self.vim.cmd('hi')\n"))
	end)

	it("does NOT flag accesses occurring only inside stripped comments", function()
		local src = "-- vim.api.foo()\nlocal y = vim.tbl_keys(t)\n"
		assert.are.equal(0, #violations_of(src))
	end)

	it("reports line numbers correctly across multi-line input", function()
		local src = "local a = 1\n" -- line 1, clean
			.. "local b = 2\n" -- line 2, clean
			.. "vim.notify('x')\n" -- line 3, violation
		local v = violations_of(src)
		assert.are.equal(1, #v)
		assert.are.equal(3, v[1].line)
	end)

	it("detects multiple violations on the same line as separate records", function()
		local v = violations_of("vim.api.foo() vim.fn.bar()\n")
		assert.are.equal(2, #v)
	end)
end)

describe("check_purity.format_report", function()
	it("emits OK message when there are no violations", function()
		local report, total = check.format_report({})
		assert.are.equal(0, total)
		assert.is_truthy(report:find("OK"))
	end)

	it("groups violations by file with per-file headers", function()
		local report, total = check.format_report({
			{ file = "a.lua", line = 10, pattern = "vim.api.*" },
			{ file = "a.lua", line = 5, pattern = "vim.fn.*" },
			{ file = "b.lua", line = 1, pattern = "vim.cmd" },
		})
		assert.are.equal(3, total)
		assert.is_truthy(report:find("## a%.lua %(2%)"))
		assert.is_truthy(report:find("## b%.lua %(1%)"))
		assert.is_truthy(report:find("FAIL: 3"))
	end)

	it("sorts violations within a file by line number", function()
		local report = check.format_report({
			{ file = "x.lua", line = 30, pattern = "vim.api.*" },
			{ file = "x.lua", line = 5, pattern = "vim.fn.*" },
		})
		-- line 5 should appear before line 30
		local pos5 = report:find("x%.lua:5:")
		local pos30 = report:find("x%.lua:30:")
		assert.is_truthy(pos5)
		assert.is_truthy(pos30)
		assert.is_true(pos5 < pos30)
	end)
end)
