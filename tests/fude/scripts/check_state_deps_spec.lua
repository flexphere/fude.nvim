local check = require("check_state_deps")

describe("check_state_deps.strip_comments_strings", function()
	it("blanks line comments while preserving content before --", function()
		local src = "local x = 1 -- comment\nlocal y = 2"
		local stripped = check.strip_comments_strings(src)
		assert.is_truthy(stripped:find("local x = 1"))
		assert.is_falsy(stripped:find("comment"))
		assert.is_truthy(stripped:find("local y = 2"))
	end)

	it("blanks block comments spanning multiple lines", function()
		local src = "local x = 1\n--[[ secret\nstate.foo = 1\n]]--\nlocal y = 2"
		local stripped = check.strip_comments_strings(src)
		assert.is_falsy(stripped:find("secret"))
		assert.is_falsy(stripped:find("state%.foo"))
		assert.is_truthy(stripped:find("local x = 1"))
		assert.is_truthy(stripped:find("local y = 2"))
	end)

	it("blanks double-quoted strings", function()
		local src = 'local x = "state.foo = bar"'
		local stripped = check.strip_comments_strings(src)
		assert.is_falsy(stripped:find("state%.foo"))
		assert.is_falsy(stripped:find("bar"))
	end)

	it("blanks single-quoted strings", function()
		local src = "local x = 'state.bar'"
		local stripped = check.strip_comments_strings(src)
		assert.is_falsy(stripped:find("state%.bar"))
	end)

	it("blanks [[ long strings ]]", function()
		local src = "local x = [[state.zzz]]"
		local stripped = check.strip_comments_strings(src)
		assert.is_falsy(stripped:find("state%.zzz"))
	end)

	it("preserves total line count", function()
		local src = "a\n-- comment\n--[[\nblock\n]]\nb"
		local stripped = check.strip_comments_strings(src)
		local _, count_src = src:gsub("\n", "\n")
		local _, count_stripped = stripped:gsub("\n", "\n")
		assert.are.equal(count_src, count_stripped)
	end)
end)

describe("check_state_deps.parse_state_table", function()
	local sample_md = [[
Some intro text.

| Field | W (Write) | R (Read) |
|-------|-----------|----------|
| `active` | init | comments, scope |
| `pr_commits` | init, init(reload) | scope, ui/sidepanel |
| `dead_field` | | |

Trailing prose.
]]

	it("returns entries keyed by field name", function()
		local t = check.parse_state_table(sample_md)
		assert.is_truthy(t["active"])
		assert.is_truthy(t["pr_commits"])
	end)

	it("normalizes init(reload) to init", function()
		local t = check.parse_state_table(sample_md)
		assert.is_true(t["pr_commits"].W["init"])
		assert.is_nil(t["pr_commits"].W["init(reload)"])
	end)

	it("captures multiple modules in W and R", function()
		local t = check.parse_state_table(sample_md)
		assert.is_true(t["active"].W["init"])
		assert.is_true(t["active"].R["comments"])
		assert.is_true(t["active"].R["scope"])
	end)

	it("handles empty W and R cells", function()
		local t = check.parse_state_table(sample_md)
		assert.is_truthy(t["dead_field"])
		assert.are.equal(0, vim.tbl_count(t["dead_field"].W))
		assert.are.equal(0, vim.tbl_count(t["dead_field"].R))
	end)

	it("ignores prose outside the table", function()
		local t = check.parse_state_table(sample_md)
		-- "Some intro text" / "Trailing prose" should not create entries
		assert.is_nil(t["Some"])
		assert.is_nil(t["Trailing"])
	end)

	it("returns empty when no table is present", function()
		local t = check.parse_state_table("# Just a heading\n\nNo table here.\n")
		assert.are.equal(0, vim.tbl_count(t))
	end)
end)

describe("check_state_deps.extract_aliases", function()
	it("always includes config.state itself", function()
		local aliases = check.extract_aliases("")
		assert.is_true(aliases["config.state"])
	end)

	it("detects local <id> = config.state", function()
		local src = "local state = config.state\nlocal s = config.state\n"
		local aliases = check.extract_aliases(src)
		assert.is_true(aliases["state"])
		assert.is_true(aliases["s"])
	end)

	it("does NOT treat single-field copy as an alias", function()
		local src = "local foo = config.state.pr_number\n"
		local aliases = check.extract_aliases(src)
		assert.is_nil(aliases["foo"])
	end)

	it("does NOT detect aliases bound to other tables", function()
		local src = "local state = pr_info.state\n"
		local aliases = check.extract_aliases(src)
		assert.is_nil(aliases["state"])
	end)
end)

describe("check_state_deps.extract_field_accesses", function()
	local function accesses(src, extra_aliases)
		local aliases = { ["config.state"] = true }
		for _, name in ipairs(extra_aliases or {}) do
			aliases[name] = true
		end
		return check.extract_field_accesses(src, aliases)
	end

	it("detects direct W: config.state.foo = 1", function()
		local r = accesses("config.state.foo = 1\n")
		assert.is_true(r.foo.W)
		assert.is_false(r.foo.R)
	end)

	it("detects direct R: local x = config.state.foo", function()
		local r = accesses("local x = config.state.foo\n")
		assert.is_false(r.foo.W)
		assert.is_true(r.foo.R)
	end)

	it("detects alias W: state.foo = 1", function()
		local r = accesses("state.foo = 1\n", { "state" })
		assert.is_true(r.foo.W)
	end)

	it("detects alias R: state.foo + 1", function()
		local r = accesses("local x = state.foo + 1\n", { "state" })
		assert.is_true(r.foo.R)
	end)

	it("classifies == as R, not W", function()
		local r = accesses("if state.foo == 1 then end\n", { "state" })
		assert.is_true(r.foo.R)
		assert.is_false(r.foo.W)
	end)

	it("classifies indexed assignment as W: state.foo[k] = v", function()
		local r = accesses("state.foo[k] = 1\n", { "state" })
		assert.is_true(r.foo.W)
		assert.is_false(r.foo.R)
	end)

	it("classifies chained .key assignment as W: state.foo.bar = v", function()
		local r = accesses("state.foo.bar = 1\n", { "state" })
		assert.is_true(r.foo.W)
	end)

	it("classifies :method() call as R (mutation not statically provable)", function()
		local r = accesses("state.foo:append(1)\n", { "state" })
		assert.is_true(r.foo.R)
		assert.is_false(r.foo.W)
	end)

	it("classifies function call as R: state.foo()", function()
		local r = accesses("state.foo()\n", { "state" })
		assert.is_true(r.foo.R)
		assert.is_false(r.foo.W)
	end)

	it("does NOT detect identifier suffixes (oldstate.foo)", function()
		local r = accesses("oldstate.foo = 1\n", { "state" })
		assert.is_nil(r.foo)
	end)

	it("does NOT detect other tables' state field (obj.state.foo)", function()
		local r = accesses("local x = pr_info.state.something\n", { "state" })
		assert.is_nil(r.something)
	end)

	it("detects W and R in same line: state.foo = state.foo + 1", function()
		local r = accesses("state.foo = state.foo + 1\n", { "state" })
		assert.is_true(r.foo.W)
		assert.is_true(r.foo.R)
	end)

	it("ignores accesses occurring only inside stripped comments", function()
		-- extract_field_accesses expects already-stripped source. The caller
		-- (scan_module_text) strips first. Verify via scan_module_text instead.
		local r = check.scan_module_text("-- state.foo = 1\nlocal x = 1\n", "test")
		assert.is_nil(r.foo)
	end)
end)

describe("check_state_deps.path_to_module", function()
	it("strips lua/fude/ prefix and .lua suffix", function()
		assert.are.equal("init", check.path_to_module("lua/fude/init.lua"))
	end)

	it("handles nested module paths", function()
		assert.are.equal("comments/sync", check.path_to_module("lua/fude/comments/sync.lua"))
		assert.are.equal("ui/sidepanel", check.path_to_module("lua/fude/ui/sidepanel.lua"))
		assert.are.equal("completion/init", check.path_to_module("lua/fude/completion/init.lua"))
	end)

	it("returns nil for non-fude paths", function()
		assert.is_nil(check.path_to_module("tests/foo.lua"))
		assert.is_nil(check.path_to_module("scripts/bar.lua"))
	end)
end)

describe("check_state_deps.scan_module_text", function()
	it("composes strip + alias + access detection", function()
		local src = [[
local state = config.state
state.active = true
local nr = state.pr_number
-- state.fake = 1
]]
		local r = check.scan_module_text(src, "init")
		assert.is_true(r.active.W)
		assert.is_true(r.pr_number.R)
		assert.is_nil(r.fake)
	end)

	it("treats M.state as config.state inside the config module", function()
		local src = "M.state.ns_id = vim.api.nvim_create_namespace('fude')\n"
		local r_other = check.scan_module_text(src, "init")
		local r_config = check.scan_module_text(src, "config")
		assert.is_nil(r_other.ns_id)
		assert.is_true(r_config.ns_id.W)
	end)
end)

describe("check_state_deps.compare", function()
	local function make_table(spec)
		local t = {}
		for field, mods in pairs(spec) do
			t[field] = { W = {}, R = {} }
			for _, m in ipairs(mods.W or {}) do
				t[field].W[m] = true
			end
			for _, m in ipairs(mods.R or {}) do
				t[field].R[m] = true
			end
		end
		return t
	end

	it("returns no discrepancies for a perfect match", function()
		local td = make_table({ active = { W = { "init" }, R = { "scope" } } })
		local cd = { init = { active = { W = true, R = false } }, scope = { active = { W = false, R = true } } }
		local d = check.compare(td, cd)
		assert.are.equal(0, #d.missing_w)
		assert.are.equal(0, #d.missing_r)
		assert.are.equal(0, #d.false_w)
		assert.are.equal(0, #d.false_r)
		assert.are.equal(0, #d.unknown_fields)
		assert.are.equal(0, #d.dead_fields)
	end)

	it("flags missing W when code writes but table omits the module", function()
		local td = make_table({ active = { W = { "init" }, R = {} } })
		local cd = { scope = { active = { W = true, R = false } } }
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.missing_w)
		assert.are.equal("active", d.missing_w[1].field)
		assert.are.equal("scope", d.missing_w[1].module)
	end)

	it("flags missing R when code reads but table omits the module", function()
		local td = make_table({ active = { W = { "init" }, R = { "scope" } } })
		local cd = { init = { active = { W = true, R = false } }, ui = { active = { W = false, R = true } } }
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.missing_r)
		assert.are.equal("active", d.missing_r[1].field)
		assert.are.equal("ui", d.missing_r[1].module)
	end)

	it("flags false W when table lists module but code does not write", function()
		local td = make_table({ active = { W = { "scope" }, R = { "scope" } } })
		local cd = { scope = { active = { W = false, R = true } } }
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.false_w)
		assert.are.equal("active", d.false_w[1].field)
		assert.are.equal("scope", d.false_w[1].module)
	end)

	it("flags false R when table lists module but code does not read", function()
		local td = make_table({ active = { W = { "init" }, R = { "ui" } } })
		local cd = { init = { active = { W = true, R = false } } }
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.false_r)
		assert.are.equal("active", d.false_r[1].field)
		assert.are.equal("ui", d.false_r[1].module)
	end)

	it("flags unknown fields when code accesses a field not in the table", function()
		local td = make_table({})
		local cd = { init = { augroup = { W = true, R = false } } }
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.unknown_fields)
		assert.are.equal("augroup", d.unknown_fields[1].field)
	end)

	it("flags dead fields when table has a row but no module accesses it", function()
		local td = make_table({ obsolete = { W = { "init" }, R = {} } })
		local cd = {}
		local d = check.compare(td, cd)
		assert.are.equal(1, #d.dead_fields)
		assert.are.equal("obsolete", d.dead_fields[1])
	end)

	it("sorts discrepancies deterministically by field then module", function()
		local td = make_table({ a = { W = {}, R = {} }, b = { W = {}, R = {} } })
		local cd = {
			z_mod = { b = { W = true, R = false }, a = { W = true, R = false } },
			a_mod = { a = { W = true, R = false } },
		}
		local d = check.compare(td, cd)
		-- missing_w should be ordered: a/a_mod, a/z_mod, b/z_mod
		assert.are.equal("a", d.missing_w[1].field)
		assert.are.equal("a_mod", d.missing_w[1].module)
		assert.are.equal("a", d.missing_w[2].field)
		assert.are.equal("z_mod", d.missing_w[2].module)
		assert.are.equal("b", d.missing_w[3].field)
		assert.are.equal("z_mod", d.missing_w[3].module)
	end)
end)

describe("check_state_deps.format_report", function()
	it("emits an OK line and total 0 when there are no discrepancies", function()
		local d = { missing_w = {}, missing_r = {}, false_w = {}, false_r = {}, unknown_fields = {}, dead_fields = {} }
		local report, total = check.format_report(d)
		assert.are.equal(0, total)
		assert.is_truthy(report:find("OK"))
	end)

	it("includes counts in section headers and the total in trailer", function()
		local d = {
			missing_w = { { field = "active", module = "init" } },
			missing_r = { { field = "pr_number", module = "ui" }, { field = "pr_number", module = "files" } },
			false_w = {},
			false_r = {},
			unknown_fields = {},
			dead_fields = { "obsolete" },
		}
		local report, total = check.format_report(d)
		assert.are.equal(4, total)
		assert.is_truthy(report:find("Missing W.*%(1%)"))
		assert.is_truthy(report:find("Missing R.*%(2%)"))
		assert.is_truthy(report:find("Dead fields.*%(1%)"))
		assert.is_truthy(report:find("FAIL: 4"))
	end)

	it("omits empty sections", function()
		local d = {
			missing_w = { { field = "active", module = "init" } },
			missing_r = {},
			false_w = {},
			false_r = {},
			unknown_fields = {},
			dead_fields = {},
		}
		local report = check.format_report(d)
		assert.is_truthy(report:find("Missing W"))
		assert.is_falsy(report:find("Missing R"))
		assert.is_falsy(report:find("False W"))
	end)
end)
