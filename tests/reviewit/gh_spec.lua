local gh = require("reviewit.gh")

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
