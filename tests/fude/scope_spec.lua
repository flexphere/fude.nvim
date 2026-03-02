local scope = require("fude.scope")

describe("build_scope_entries", function()
	it("returns full PR entry first followed by commits", function()
		local commits = {
			{
				sha = "abc1234567890",
				short_sha = "abc1234",
				message = "feat: add login",
				author_name = "Alice",
				date = "2026-03-01T10:00:00Z",
			},
			{
				sha = "def5678901234",
				short_sha = "def5678",
				message = "fix: typo",
				author_name = "Bob",
				date = "2026-03-02T12:00:00Z",
			},
		}
		local entries = scope.build_scope_entries(commits, "main", "feat/login")
		assert.are.equal(3, #entries)

		-- First entry is Full PR
		assert.is_true(entries[1].is_full_pr)
		assert.are.equal("full_pr", entries[1].value)
		assert.is_nil(entries[1].sha)
		assert.truthy(entries[1].display_text:find("main"))
		assert.truthy(entries[1].display_text:find("feat/login"))

		-- Subsequent entries are commits
		assert.is_false(entries[2].is_full_pr)
		assert.are.equal("abc1234567890", entries[2].sha)
		assert.truthy(entries[2].display_text:find("abc1234"))
		assert.truthy(entries[2].display_text:find("feat: add login"))
		assert.truthy(entries[2].display_text:find("Alice"))

		assert.is_false(entries[3].is_full_pr)
		assert.are.equal("def5678901234", entries[3].sha)
	end)

	it("returns only full PR entry when no commits", function()
		local entries = scope.build_scope_entries({}, "main", "feat/x")
		assert.are.equal(1, #entries)
		assert.is_true(entries[1].is_full_pr)
	end)

	it("includes branch names in full PR display text", function()
		local entries = scope.build_scope_entries({}, "develop", "feature/auth")
		assert.truthy(entries[1].display_text:find("develop"))
		assert.truthy(entries[1].display_text:find("feature/auth"))
	end)
end)
