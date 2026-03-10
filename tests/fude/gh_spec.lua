local gh = require("fude.gh")

describe("build_viewed_files_query", function()
	it("builds query without cursor", function()
		local query = gh.build_viewed_files_query("owner", "repo", 42, nil)
		assert.truthy(query:find('"owner"'))
		assert.truthy(query:find('"repo"'))
		assert.truthy(query:find("number: 42"))
		assert.truthy(query:find("after: null"))
		assert.truthy(query:find("viewerViewedState"))
	end)

	it("builds query with cursor", function()
		local query = gh.build_viewed_files_query("owner", "repo", 10, "abc123")
		assert.truthy(query:find('"abc123"'))
		assert.falsy(query:find("after: null"))
	end)
end)

describe("parse_viewed_files_response", function()
	it("parses valid response with files", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						id = "PR_kwDOtest",
						files = {
							pageInfo = { hasNextPage = false, endCursor = nil },
							nodes = {
								{ path = "a.lua", viewerViewedState = "VIEWED" },
								{ path = "b.lua", viewerViewedState = "UNVIEWED" },
							},
						},
					},
				},
			},
		}
		local viewed_map, pr_node_id, has_next, end_cursor = gh.parse_viewed_files_response(data)
		assert.are.equal("VIEWED", viewed_map["a.lua"])
		assert.are.equal("UNVIEWED", viewed_map["b.lua"])
		assert.are.equal("PR_kwDOtest", pr_node_id)
		assert.is_false(has_next)
		assert.is_nil(end_cursor)
	end)

	it("parses response with pagination", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						id = "PR_abc",
						files = {
							pageInfo = { hasNextPage = true, endCursor = "cursor123" },
							nodes = {
								{ path = "c.lua", viewerViewedState = "DISMISSED" },
							},
						},
					},
				},
			},
		}
		local viewed_map, _, has_next, end_cursor = gh.parse_viewed_files_response(data)
		assert.are.equal("DISMISSED", viewed_map["c.lua"])
		assert.is_true(has_next)
		assert.are.equal("cursor123", end_cursor)
	end)

	it("returns empty map for missing pullRequest", function()
		local data = { data = { repository = {} } }
		local viewed_map, pr_node_id, has_next, _ = gh.parse_viewed_files_response(data)
		assert.are.same({}, viewed_map)
		assert.is_nil(pr_node_id)
		assert.is_false(has_next)
	end)

	it("returns empty map for nil data", function()
		local viewed_map, pr_node_id, has_next, _ = gh.parse_viewed_files_response({})
		assert.are.same({}, viewed_map)
		assert.is_nil(pr_node_id)
		assert.is_false(has_next)
	end)

	it("handles empty nodes list", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						id = "PR_empty",
						files = {
							pageInfo = { hasNextPage = false },
							nodes = {},
						},
					},
				},
			},
		}
		local viewed_map, pr_node_id, _, _ = gh.parse_viewed_files_response(data)
		assert.are.same({}, viewed_map)
		assert.are.equal("PR_empty", pr_node_id)
	end)
end)

describe("parse_commit_entries", function()
	it("parses commits with full data", function()
		local raw = {
			{
				sha = "abc1234567890abcdef",
				commit = {
					message = "feat: add login page\n\nDetailed description",
					author = { name = "Alice", date = "2026-03-01T10:00:00Z" },
				},
			},
			{
				sha = "def5678901234abcdef",
				commit = {
					message = "fix: typo in header",
					author = { name = "Bob", date = "2026-03-02T12:00:00Z" },
				},
			},
		}
		local entries = gh.parse_commit_entries(raw)
		assert.are.equal(2, #entries)
		assert.are.equal("abc1234567890abcdef", entries[1].sha)
		assert.are.equal("abc1234", entries[1].short_sha)
		assert.are.equal("feat: add login page", entries[1].message)
		assert.are.equal("Alice", entries[1].author_name)
		assert.are.equal("2026-03-01T10:00:00Z", entries[1].date)
		assert.are.equal("def5678", entries[2].short_sha)
		assert.are.equal("fix: typo in header", entries[2].message)
	end)

	it("uses first line of multiline commit message", function()
		local raw = {
			{
				sha = "abc1234567890",
				commit = {
					message = "First line\nSecond line\nThird line",
					author = { name = "Alice", date = "" },
				},
			},
		}
		local entries = gh.parse_commit_entries(raw)
		assert.are.equal("First line", entries[1].message)
	end)

	it("handles missing commit fields gracefully", function()
		local raw = {
			{ sha = "abc1234567890", commit = {} },
		}
		local entries = gh.parse_commit_entries(raw)
		assert.are.equal("abc1234", entries[1].short_sha)
		assert.are.equal("", entries[1].message)
		assert.are.equal("", entries[1].author_name)
		assert.are.equal("", entries[1].date)
	end)

	it("handles missing commit object", function()
		local raw = {
			{ sha = "abc1234567890" },
		}
		local entries = gh.parse_commit_entries(raw)
		assert.are.equal("abc1234", entries[1].short_sha)
		assert.are.equal("", entries[1].message)
	end)

	it("returns empty for empty input", function()
		local entries = gh.parse_commit_entries({})
		assert.are.same({}, entries)
	end)
end)

describe("parse_pr_from_commit_api", function()
	it("parses single PR with full data", function()
		local data = {
			{
				number = 42,
				state = "open",
				html_url = "https://github.com/owner/repo/pull/42",
				base = { ref = "main" },
				head = { ref = "feature-branch" },
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(42, result.number)
		assert.are.equal("main", result.baseRefName)
		assert.are.equal("feature-branch", result.headRefName)
		assert.are.equal("https://github.com/owner/repo/pull/42", result.url)
	end)

	it("prefers open PR over closed", function()
		local data = {
			{
				number = 10,
				state = "closed",
				html_url = "https://github.com/owner/repo/pull/10",
				base = { ref = "main" },
				head = { ref = "old-branch" },
			},
			{
				number = 20,
				state = "open",
				html_url = "https://github.com/owner/repo/pull/20",
				base = { ref = "main" },
				head = { ref = "current-branch" },
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(20, result.number)
		assert.are.equal("current-branch", result.headRefName)
	end)

	it("uses first PR when all are closed", function()
		local data = {
			{
				number = 5,
				state = "closed",
				html_url = "https://github.com/owner/repo/pull/5",
				base = { ref = "main" },
				head = { ref = "branch-a" },
			},
			{
				number = 6,
				state = "closed",
				html_url = "https://github.com/owner/repo/pull/6",
				base = { ref = "main" },
				head = { ref = "branch-b" },
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(5, result.number)
	end)

	it("returns nil for empty array", function()
		local result = gh.parse_pr_from_commit_api({})
		assert.is_nil(result)
	end)

	it("returns nil for nil input", function()
		local result = gh.parse_pr_from_commit_api(nil)
		assert.is_nil(result)
	end)

	it("handles missing base and head fields", function()
		local data = {
			{
				number = 99,
				state = "open",
				html_url = "https://github.com/owner/repo/pull/99",
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(99, result.number)
		assert.is_nil(result.baseRefName)
		assert.is_nil(result.headRefName)
	end)
end)
