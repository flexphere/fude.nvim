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

	it("detects bare _ trigger for commit", function()
		assert.are.equal("commit", completion.get_context("see _"))
	end)

	it("detects _ with partial sha", function()
		assert.are.equal("commit", completion.get_context("_abc123"))
	end)

	it("detects _ with scope-style filter text", function()
		assert.are.equal("commit", completion.get_context("_[1/3] abc"))
	end)

	it("returns nil for plain text", function()
		assert.is_nil(completion.get_context("hello world"))
	end)

	it("returns nil for empty string", function()
		assert.is_nil(completion.get_context(""))
	end)
end)

describe("completion.build_commit_items", function()
	it("builds items from commit entries in newest-first order", function()
		local commits = {
			{
				sha = "abc1234567890abcdef1234567890abcdef123456",
				short_sha = "abc1234",
				message = "feat: add feature",
				author_name = "Alice",
				date = "2026-01-15T10:00:00Z",
			},
			{
				sha = "def5678901234567890abcdef1234567890abcdef",
				short_sha = "def5678",
				message = "fix: bug fix",
				author_name = "Bob",
				date = "2026-01-16T12:00:00Z",
			},
		}
		local items = completion.build_commit_items(commits)
		assert.are.equal(2, #items)

		-- Items are ordered newest-first: [2/2] comes before [1/2]
		assert.are.equal("[2/2] def5678 fix: bug fix (Bob)", items[1].label)
		assert.are.equal("def5678", items[1].insertText)
		assert.are.equal("_", items[1].filterText)
		assert.are.equal("00001", items[1].sortText)
		assert.are.equal(15, items[1].kind)

		assert.are.equal("[1/2] abc1234 feat: add feature (Alice)", items[2].label)
		assert.are.equal("abc1234", items[2].insertText)
		assert.are.equal("00002", items[2].sortText)
	end)

	it("returns empty table for empty input", function()
		local items = completion.build_commit_items({})
		assert.are.equal(0, #items)
	end)

	it("includes documentation with commit details", function()
		local commits = {
			{
				sha = "abc1234567890",
				short_sha = "abc1234",
				message = "test commit",
				author_name = "Test",
				date = "2026-03-01T00:00:00Z",
			},
		}
		local items = completion.build_commit_items(commits)
		assert.is_not_nil(items[1].documentation)
		assert.are.equal("markdown", items[1].documentation.kind)
		assert.truthy(items[1].documentation.value:find("abc1234567890"))
		assert.truthy(items[1].documentation.value:find("Test"))
	end)
end)
