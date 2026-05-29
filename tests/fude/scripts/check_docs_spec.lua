local check = require("check_docs")

describe("check_docs.strip_comments_only", function()
	it("blanks line comments but preserves string contents", function()
		local stripped = check.strip_comments_only('local x = "FudeFoo" -- nvim_create_user_command("FudeBar"\n')
		-- String "FudeFoo" should be intact, comment content gone
		assert.is_truthy(stripped:find('"FudeFoo"'))
		assert.is_falsy(stripped:find("FudeBar"))
	end)

	it("blanks block comments but preserves strings", function()
		local stripped = check.strip_comments_only('local x = "real"\n--[[ nvim_create_user_command("FakeCmd"\n]]\n')
		assert.is_truthy(stripped:find('"real"'))
		assert.is_falsy(stripped:find("FakeCmd"))
	end)
end)

describe("check_docs.extract_registered_commands", function()
	it("extracts a single double-quoted registration", function()
		local set =
			check.extract_registered_commands('vim.api.nvim_create_user_command("FudeReviewStart", function() end, {})\n')
		assert.is_true(set.FudeReviewStart)
	end)

	it("extracts a single single-quoted registration", function()
		local set = check.extract_registered_commands("vim.api.nvim_create_user_command('FudeFoo', function() end, {})\n")
		assert.is_true(set.FudeFoo)
	end)

	it("extracts multiple registrations as a set", function()
		local src = 'vim.api.nvim_create_user_command("A", f1, {})\n' .. 'vim.api.nvim_create_user_command("B", f2, {})\n'
		local set = check.extract_registered_commands(src)
		assert.is_true(set.A)
		assert.is_true(set.B)
	end)

	it("ignores commented-out registrations", function()
		local src = '-- vim.api.nvim_create_user_command("Removed", ...)\n'
			.. 'vim.api.nvim_create_user_command("Kept", f, {})\n'
		local set = check.extract_registered_commands(src)
		assert.is_nil(set.Removed)
		assert.is_true(set.Kept)
	end)

	it("ignores registrations inside block comments", function()
		local src = '--[[\nvim.api.nvim_create_user_command("Blocked", ...)\n]]\n'
			.. 'vim.api.nvim_create_user_command("Active", f, {})\n'
		local set = check.extract_registered_commands(src)
		assert.is_nil(set.Blocked)
		assert.is_true(set.Active)
	end)

	it("allows whitespace between `(` and the name", function()
		local set = check.extract_registered_commands('vim.api.nvim_create_user_command(  "Spaced"  , f, {})\n')
		assert.is_true(set.Spaced)
	end)

	it("returns empty set for source with no registrations", function()
		local set = check.extract_registered_commands("local x = 1\n")
		assert.are.equal(0, vim.tbl_count(set))
	end)
end)

describe("check_docs.extract_documented_commands", function()
	it("extracts a single tag", function()
		local set = check.extract_documented_commands(":FudeReviewStart  *:FudeReviewStart*\n")
		assert.is_true(set.FudeReviewStart)
	end)

	it("extracts multiple tags as a set", function()
		local set = check.extract_documented_commands("*:FudeA*\nsome text\n*:FudeB*\n")
		assert.is_true(set.FudeA)
		assert.is_true(set.FudeB)
	end)

	it("does NOT match non-colon tags (e.g. *g:fude_xxx*)", function()
		local set = check.extract_documented_commands("*g:fude_option*\n*fude-section*\n")
		-- only `*:FudeXxx*` should match
		assert.are.equal(0, vim.tbl_count(set))
	end)

	it("does NOT match bare command references without asterisks", function()
		local set = check.extract_documented_commands("use :FudeReviewStart to start review\n")
		assert.is_nil(set.FudeReviewStart)
	end)

	it("returns empty set for doc with no tags", function()
		local set = check.extract_documented_commands("Just prose with no helptags.\n")
		assert.are.equal(0, vim.tbl_count(set))
	end)
end)

describe("check_docs.compare", function()
	it("returns empty diffs for identical sets", function()
		local diff = check.compare({ A = true, B = true }, { A = true, B = true })
		assert.are.equal(0, #diff.undocumented)
		assert.are.equal(0, #diff.stale)
	end)

	it("flags commands registered but not documented", function()
		local diff = check.compare({ A = true, B = true }, { A = true })
		assert.are.same({ "B" }, diff.undocumented)
		assert.are.equal(0, #diff.stale)
	end)

	it("flags commands documented but not registered", function()
		local diff = check.compare({ A = true }, { A = true, B = true })
		assert.are.equal(0, #diff.undocumented)
		assert.are.same({ "B" }, diff.stale)
	end)

	it("flags both directions when sets diverge", function()
		local diff = check.compare({ A = true, X = true }, { A = true, Y = true })
		assert.are.same({ "X" }, diff.undocumented)
		assert.are.same({ "Y" }, diff.stale)
	end)

	it("sorts results deterministically", function()
		local diff = check.compare({ Z = true, A = true, M = true }, {})
		assert.are.same({ "A", "M", "Z" }, diff.undocumented)
	end)
end)

describe("check_docs.format_report", function()
	it("emits OK message and total 0 when there are no discrepancies", function()
		local report, total = check.format_report({ undocumented = {}, stale = {} })
		assert.are.equal(0, total)
		assert.is_truthy(report:find("OK"))
	end)

	it("emits sections for both undocumented and stale with counts", function()
		local report, total = check.format_report({
			undocumented = { "NewCmd" },
			stale = { "OldCmd", "DeletedCmd" },
		})
		assert.are.equal(3, total)
		assert.is_truthy(report:find("Undocumented commands %(1%)"))
		assert.is_truthy(report:find("Stale documentation %(2%)"))
		assert.is_truthy(report:find("FAIL: 3"))
	end)

	it("omits empty sections", function()
		local report = check.format_report({ undocumented = { "X" }, stale = {} })
		assert.is_truthy(report:find("Undocumented"))
		assert.is_falsy(report:find("Stale"))
	end)
end)
