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

	it("marks reviewed commits with reviewed = true", function()
		local commits = {
			{ sha = "aaa111", short_sha = "aaa111", message = "first", author_name = "A", date = "" },
			{ sha = "bbb222", short_sha = "bbb222", message = "second", author_name = "B", date = "" },
		}
		local reviewed = { ["aaa111"] = true }
		local entries = scope.build_scope_entries(commits, "main", "dev", reviewed)

		assert.is_true(entries[2].reviewed)
		assert.is_false(entries[3].reviewed)
	end)

	it("full PR entry is always not reviewed", function()
		local reviewed = { ["abc"] = true }
		local entries = scope.build_scope_entries({}, "main", "dev", reviewed)

		assert.is_false(entries[1].reviewed)
		assert.are.equal(" ", entries[1].reviewed_icon)
	end)

	it("handles commit with nil sha without error", function()
		local commits = {
			{ sha = nil, short_sha = "", message = "broken", author_name = "C", date = "" },
		}
		local reviewed = { ["aaa"] = true }
		local entries = scope.build_scope_entries(commits, "main", "dev", reviewed)

		assert.is_false(entries[2].reviewed)
		assert.are.equal(" ", entries[2].reviewed_icon)
	end)

	it("defaults reviewed to false when reviewed_commits is nil", function()
		local commits = {
			{ sha = "aaa111", short_sha = "aaa111", message = "first", author_name = "A", date = "" },
		}
		local entries = scope.build_scope_entries(commits, "main", "dev")

		assert.is_false(entries[2].reviewed)
		assert.are.equal(" ", entries[2].reviewed_icon)
	end)
end)

describe("reviewed_icon", function()
	it("returns viewed sign for reviewed commit", function()
		local icon, hl = scope.reviewed_icon(true)
		assert.truthy(icon ~= " ")
		assert.are.equal("DiagnosticOk", hl)
	end)

	it("returns space for non-reviewed commit", function()
		local icon, hl = scope.reviewed_icon(false)
		assert.are.equal(" ", icon)
		assert.are.equal("Comment", hl)
	end)
end)
