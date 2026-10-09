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

describe("build_changed_files", function()
	it("converts API file objects to changed_files entries", function()
		local files = gh.build_changed_files({
			{ filename = "lua/a.lua", status = "modified", additions = 3, deletions = 1, patch = "@@ -1 +1 @@" },
		})
		assert.same({
			{ path = "lua/a.lua", status = "modified", additions = 3, deletions = 1, patch = "@@ -1 +1 @@" },
		}, files)
	end)

	it("keeps previous_filename of a renamed file as previous_path", function()
		local files = gh.build_changed_files({
			{ filename = "lua/new.lua", previous_filename = "lua/old.lua", status = "renamed", additions = 2, deletions = 2 },
		})
		assert.equals("lua/new.lua", files[1].path)
		assert.equals("lua/old.lua", files[1].previous_path)
		assert.equals("renamed", files[1].status)
	end)

	it("ignores a JSON null previous_filename", function()
		local files = gh.build_changed_files({ { filename = "a.lua", previous_filename = vim.NIL, status = "modified" } })
		assert.is_nil(files[1].previous_path)
	end)

	it("returns an empty list for no files", function()
		assert.same({}, gh.build_changed_files({}))
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
		assert.are.equal("open", result.state)
	end)

	it("includes merged state", function()
		local data = {
			{
				number = 50,
				state = "merged",
				html_url = "https://github.com/owner/repo/pull/50",
				base = { ref = "main" },
				head = { ref = "merged-branch" },
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(50, result.number)
		assert.are.equal("merged", result.state)
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

	it("defaults to empty string for missing base and head fields", function()
		local data = {
			{
				number = 99,
				state = "open",
				html_url = "https://github.com/owner/repo/pull/99",
			},
		}
		local result = gh.parse_pr_from_commit_api(data)
		assert.are.equal(99, result.number)
		assert.are.equal("", result.baseRefName)
		assert.are.equal("", result.headRefName)
	end)
end)

describe("build_review_threads_query", function()
	it("builds query without cursor", function()
		local query = gh.build_review_threads_query("owner", "repo", 42, nil)
		assert.truthy(query:find('"owner"'))
		assert.truthy(query:find('"repo"'))
		assert.truthy(query:find("number: 42"))
		assert.truthy(query:find("after: null"))
		assert.truthy(query:find("isOutdated"))
		assert.truthy(query:find("isResolved"))
		assert.truthy(query:find("databaseId"))
		assert.truthy(query:find("originalLine"))
		-- Thread node ID is required for addPullRequestReviewThreadReply mutation
		assert.truthy(query:find("nodes {%s+id"))
		-- Only fetch top-level comment per thread: thread_map keys reply targets by root id,
		-- and outdated info is per-thread (no need to enumerate replies).
		assert.truthy(query:find("comments%(first: 1%)"))
	end)

	it("builds query with cursor", function()
		local query = gh.build_review_threads_query("owner", "repo", 10, "cursor123")
		assert.truthy(query:find('"cursor123"'))
		assert.falsy(query:find("after: null"))
	end)
end)

describe("build_resolve_thread_mutation", function()
	it("builds resolveReviewThread when resolving", function()
		local query = gh.build_resolve_thread_mutation(true)
		assert.truthy(query:find("resolveReviewThread%(input: { threadId: %$threadId }%)"))
		assert.falsy(query:find("unresolveReviewThread"))
		assert.truthy(query:find("%$threadId: ID!"))
	end)

	it("builds unresolveReviewThread when unresolving", function()
		local query = gh.build_resolve_thread_mutation(false)
		assert.truthy(query:find("unresolveReviewThread%(input: { threadId: %$threadId }%)"))
	end)
end)

describe("set_review_thread_resolved", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("passes the mutation and thread id as GraphQL variables", function()
		local seen
		helpers.mock(gh, "run_json", function(args, callback)
			seen = args
			callback(nil, {})
		end)

		gh.set_review_thread_resolved("THREAD_1", false, function() end)

		assert.are.equal("api", seen[1])
		assert.are.equal("graphql", seen[2])
		assert.are.equal("query=" .. gh.build_resolve_thread_mutation(false), seen[4])
		assert.are.equal("threadId=THREAD_1", seen[6])
	end)
end)

describe("parse_review_threads_response", function()
	it("parses valid response with outdated and resolved threads", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							pageInfo = { hasNextPage = false, endCursor = nil },
							nodes = {
								{
									id = "THREAD_A",
									isOutdated = true,
									isResolved = false,
									comments = {
										nodes = {
											{ databaseId = 100, path = "a.lua", originalLine = 10 },
											{ databaseId = 101, path = "a.lua", originalLine = 10 },
										},
									},
								},
								{
									id = "THREAD_B",
									isOutdated = false,
									isResolved = true,
									comments = {
										nodes = {
											{ databaseId = 200, path = "b.lua", originalLine = 20 },
										},
									},
								},
							},
						},
					},
				},
			},
		}
		local thread_info_map, thread_map, has_next, end_cursor = gh.parse_review_threads_response(data)
		assert.is_true(thread_info_map[100].is_outdated)
		assert.are.equal(10, thread_info_map[100].original_line)
		assert.is_true(thread_info_map[101].is_outdated)
		assert.is_false(thread_info_map[200].is_outdated)
		assert.are.equal(20, thread_info_map[200].original_line)
		assert.is_false(thread_info_map[100].is_resolved)
		assert.is_false(thread_info_map[101].is_resolved)
		assert.is_true(thread_info_map[200].is_resolved)
		assert.are.equal("THREAD_A", thread_map[100])
		assert.are.equal("THREAD_A", thread_map[101])
		assert.are.equal("THREAD_B", thread_map[200])
		assert.is_false(has_next)
		assert.is_nil(end_cursor)
	end)

	it("parses response with pagination", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							pageInfo = { hasNextPage = true, endCursor = "cursor456" },
							nodes = {
								{
									id = "THREAD_C",
									isOutdated = true,
									comments = {
										nodes = {
											{ databaseId = 300, path = "c.lua", originalLine = 5 },
										},
									},
								},
							},
						},
					},
				},
			},
		}
		local thread_info_map, thread_map, has_next, end_cursor = gh.parse_review_threads_response(data)
		assert.is_true(thread_info_map[300].is_outdated)
		assert.are.equal("THREAD_C", thread_map[300])
		assert.is_true(has_next)
		assert.are.equal("cursor456", end_cursor)
	end)

	it("returns empty maps for missing pullRequest", function()
		local data = { data = { repository = {} } }
		local thread_info_map, thread_map, has_next, _ = gh.parse_review_threads_response(data)
		assert.are.same({}, thread_info_map)
		assert.are.same({}, thread_map)
		assert.is_false(has_next)
	end)

	it("returns empty maps for nil data", function()
		local thread_info_map, thread_map, has_next, _ = gh.parse_review_threads_response({})
		assert.are.same({}, thread_info_map)
		assert.are.same({}, thread_map)
		assert.is_false(has_next)
	end)

	it("handles empty nodes list", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							pageInfo = { hasNextPage = false },
							nodes = {},
						},
					},
				},
			},
		}
		local thread_info_map, thread_map, _, _ = gh.parse_review_threads_response(data)
		assert.are.same({}, thread_info_map)
		assert.are.same({}, thread_map)
	end)

	it("handles thread with no comments", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							pageInfo = { hasNextPage = false },
							nodes = {
								{
									id = "THREAD_EMPTY",
									isOutdated = true,
									comments = { nodes = {} },
								},
							},
						},
					},
				},
			},
		}
		local thread_info_map, thread_map, _, _ = gh.parse_review_threads_response(data)
		assert.are.same({}, thread_info_map)
		assert.are.same({}, thread_map)
	end)

	it("handles nil isOutdated and isResolved as false", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							pageInfo = { hasNextPage = false },
							nodes = {
								{
									id = "THREAD_D",
									-- isOutdated is nil
									comments = {
										nodes = {
											{ databaseId = 400, path = "d.lua", originalLine = 1 },
										},
									},
								},
							},
						},
					},
				},
			},
		}
		local thread_info_map, thread_map, _, _ = gh.parse_review_threads_response(data)
		assert.is_false(thread_info_map[400].is_outdated)
		assert.is_false(thread_info_map[400].is_resolved)
		assert.are.equal("THREAD_D", thread_map[400])
	end)
end)

describe("create_draft_pr / edit_pr --attach args", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("create_draft_pr appends one --attach pair per attachment", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "https://github.com/o/r/pull/1\n")
		end)
		gh.create_draft_pr("t", "b", { "./a.png", "./b.mp4" }, nil, function() end)
		assert.are.same({
			"pr",
			"create",
			"--draft",
			"--title",
			"t",
			"--body",
			"b",
			"--attach",
			"./a.png",
			"--attach",
			"./b.mp4",
		}, captured_args)
	end)

	it("create_draft_pr omits --attach when attachments is nil or empty", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "")
		end)
		gh.create_draft_pr("t", "b", nil, nil, function() end)
		assert.are.same({ "pr", "create", "--draft", "--title", "t", "--body", "b" }, captured_args)
		gh.create_draft_pr("t", "b", {}, nil, function() end)
		assert.are.same({ "pr", "create", "--draft", "--title", "t", "--body", "b" }, captured_args)
	end)

	it("create_draft_pr passes --base before --attach when a base branch is given", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "https://github.com/o/r/pull/1\n")
		end)
		gh.create_draft_pr("t", "b", { "./a.png" }, "develop", function() end)
		assert.are.same(
			{ "pr", "create", "--draft", "--title", "t", "--body", "b", "--base", "develop", "--attach", "./a.png" },
			captured_args
		)
	end)

	it("create_draft_pr omits --base when base is nil or empty", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "")
		end)
		gh.create_draft_pr("t", "b", nil, "", function() end)
		assert.are.same({ "pr", "create", "--draft", "--title", "t", "--body", "b" }, captured_args)
	end)

	--- Wrap PR nodes in the `ref.associatedPullRequests` response shape.
	local function pr_response(nodes)
		return { data = { repository = { ref = { associatedPullRequests = { nodes = nodes } } } } }
	end

	it("get_open_pr_stack queries the open PRs of the branch ref via GraphQL", function()
		local captured_args
		helpers.mock(gh, "run_json", function(args, callback)
			captured_args = args
			callback(
				nil,
				pr_response({
					{
						url = "https://github.com/o/r/pull/1",
						stack = { number = 3, size = 2 },
						stackEntry = { position = 2 },
					},
				})
			)
		end)
		local got_err, got = "unset", "unset"
		gh.get_open_pr_stack("feat/a", function(err, info)
			got_err, got = err, info
		end)
		-- the ref of this repository excludes fork PRs with the same branch name
		assert.are.same(
			{ "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f", "ref=refs/heads/feat/a" },
			{ unpack(captured_args, 1, 8) }
		)
		assert.is_not_nil(captured_args[10]:find("associatedPullRequests", 1, true))
		assert.is_nil(got_err)
		assert.are.same(
			{ url = "https://github.com/o/r/pull/1", stack_number = 3, stack_size = 2, stack_position = 2 },
			got
		)
	end)

	it("get_open_pr_stack reports a failed lookup as an error, not as no PR", function()
		helpers.mock(gh, "run_json", function(_, callback)
			callback("HTTP 401: Bad credentials", nil)
		end)
		local got_err, got = "unset", "unset"
		gh.get_open_pr_stack("feat/a", function(err, info)
			got_err, got = err, info
		end)
		assert.are.equal("HTTP 401: Bad credentials", got_err)
		assert.is_nil(got)
	end)

	for _, case in ipairs({
		{ name = "accepts explicit null stack membership", fields = ',"stack":null,"stackEntry":null' },
		{ name = "rejects missing stack membership", fields = "", fails = true },
	}) do
		it("get_open_pr_stack decodes raw JSON and " .. case.name, function()
			-- Keep run_json real so the supported Neovim versions exercise their decoder.
			helpers.mock(gh, "run", function(_, callback)
				callback(
					nil,
					'{"data":{"repository":{"ref":{"associatedPullRequests":{"nodes":[{"url":"u",'
						.. '"baseRefName":"main"'
						.. case.fields
						.. "}]}}}}}"
				)
			end)
			local got_err, got = "unset", "unset"
			gh.get_open_pr_stack("parent", function(err, info)
				got_err, got = err, info
			end)
			if case.fails then
				assert.are.equal("Incomplete stack information for the parent PR", got_err)
				assert.is_nil(got)
			else
				assert.is_nil(got_err)
				assert.are.same({ url = "u", base_ref = "main" }, got)
			end
		end)
	end

	it("reports incomplete stack membership as an error rather than an unstacked parent", function()
		for _, node in ipairs({
			{ url = "u" },
			{ url = "u", stack = {} },
			{ url = "u", stack = { size = 2 }, stackEntry = { position = 2 } },
			{ url = "u", stack = { number = 3, size = 2 }, stackEntry = vim.NIL },
		}) do
			helpers.mock(gh, "run_json", function(_, callback)
				callback(nil, pr_response({ node }))
			end)
			local result, result_err
			gh.get_open_pr_stack("parent", function(err, info)
				result, result_err = info, err
			end)
			assert.is_nil(result)
			assert.are.equal("Incomplete stack information for the parent PR", result_err)
		end
	end)

	it("parse_open_pr_stack returns the PR with its stack", function()
		assert.are.same(
			{
				url = "u",
				base_ref = "dev",
				stack_number = 3,
				stack_size = 4,
				stack_position = 2,
				stack_top = { url = "t", branch = "feat/top" },
			},
			gh.parse_open_pr_stack(pr_response({
				{
					url = "u",
					baseRefName = "dev",
					stack = {
						number = 3,
						size = 4,
						entries = { nodes = { { pullRequest = { url = "t", headRefName = "feat/top" } } } },
					},
					stackEntry = { position = 2 },
				},
			}))
		)
		-- stack is JSON null (vim.NIL) for a PR in no stack
		assert.are.same({ url = "u" }, gh.parse_open_pr_stack(pr_response({ { url = "u", stack = vim.NIL } })))
	end)

	it("parse_stack_top returns the last entry's PR, nil when missing or malformed", function()
		local function stack(nodes)
			return { entries = { nodes = nodes } }
		end
		assert.are.same(
			{ url = "b", branch = "top" },
			gh.parse_stack_top(stack({ { pullRequest = { url = "b", headRefName = "top" } } }))
		)
		assert.is_nil(gh.parse_stack_top(nil))
		assert.is_nil(gh.parse_stack_top(vim.NIL))
		assert.is_nil(gh.parse_stack_top(stack({})))
		assert.is_nil(gh.parse_stack_top(stack({ { pullRequest = { url = "b" } } })))
	end)

	it("parse_open_pr_stack returns nil when there is no open PR or the response is unexpected", function()
		assert.is_nil(gh.parse_open_pr_stack(pr_response({})))
		-- ref is null when the branch does not exist on GitHub
		assert.is_nil(gh.parse_open_pr_stack({ data = { repository = { ref = vim.NIL } } }))
		assert.is_nil(gh.parse_open_pr_stack({ data = { repository = vim.NIL } }))
		assert.is_nil(gh.parse_open_pr_stack(nil))
		assert.is_nil(gh.parse_open_pr_stack(pr_response({ { url = 1 } })))
	end)

	it("checks the stack command and repository capability without mutations", function()
		local calls = {}
		helpers.mock(gh, "run", function(args, callback)
			table.insert(calls, args)
			callback(nil, "")
		end)
		local result = "unset"
		gh.check_stack_available(function(err)
			result = err
		end)
		assert.is_nil(result)
		assert.are.same({
			{ "stack", "link", "--help" },
			{ "api", "repos/{owner}/{repo}/stacks?per_page=1" },
		}, calls)
	end)

	for _, fail_at in ipairs({ 1, 2 }) do
		it("stops the capability check at failed command " .. fail_at, function()
			local calls = 0
			helpers.mock(gh, "run", function(_, callback)
				calls = calls + 1
				callback(calls == fail_at and "failure detail" or nil)
			end)
			local result
			gh.check_stack_available(function(err)
				result = err
			end)
			assert.are.equal(fail_at, calls)
			assert.is_not_nil(result:find("failure detail", 1, true))
		end)
	end

	it("link_stack runs gh stack link with the refs bottom to top", function()
		local calls = {}
		helpers.mock(gh, "run", function(args, callback)
			table.insert(calls, args)
			callback(nil, "")
		end)
		local done_err = "unset"
		gh.link_stack({ "7", "https://github.com/o/r/pull/2" }, nil, function(err)
			done_err = err
		end)
		gh.link_stack({ "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2" }, "dev", function() end)
		assert.are.same({
			{ "stack", "link", "7", "https://github.com/o/r/pull/2" },
			{ "stack", "link", "--base", "dev", "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2" },
		}, calls)
		assert.is_nil(done_err)
	end)

	it("edit_pr inserts the PR number before flags and appends --attach pairs", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "")
		end)
		gh.edit_pr(42, "t", "b", { "./a.png" }, function() end)
		assert.are.same({ "pr", "edit", "42", "--title", "t", "--body", "b", "--attach", "./a.png" }, captured_args)
	end)
end)

describe("get_pr_title_body", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("normalizes JSON null title/body/url (vim.NIL) to safe values", function()
		helpers.mock(gh, "run_json", function(_, callback)
			callback(nil, { title = vim.NIL, body = vim.NIL, url = vim.NIL })
		end)
		local result
		gh.get_pr_title_body(50, function(err, data)
			result = { err = err, data = data }
		end)
		assert.is_nil(result.err)
		assert.are.equal("", result.data.title)
		assert.are.equal("", result.data.body)
		assert.is_nil(result.data.url)
	end)

	it("normalizes absent fields the same way", function()
		helpers.mock(gh, "run_json", function(_, callback)
			callback(nil, {})
		end)
		local result
		gh.get_pr_title_body(50, function(_, data)
			result = data
		end)
		assert.are.equal("", result.title)
		assert.are.equal("", result.body)
		assert.is_nil(result.url)
	end)

	it("passes through regular values and requests the url field", function()
		local captured_args
		helpers.mock(gh, "run_json", function(args, callback)
			captured_args = args
			callback(nil, { title = "T", body = "B", url = "https://github.com/o/r/pull/50" })
		end)
		local result
		gh.get_pr_title_body(50, function(_, data)
			result = data
		end)
		assert.are.same({ "pr", "view", "50", "--json", "title,body,url" }, captured_args)
		assert.are.equal("T", result.title)
		assert.are.equal("B", result.body)
		assert.are.equal("https://github.com/o/r/pull/50", result.url)
	end)
end)

describe("get_pr_state", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("requests state and isDraft for an explicit PR number and normalizes the result", function()
		local captured_args
		helpers.mock(gh, "run_json", function(args, callback)
			captured_args = args
			callback(nil, { number = 7, state = "OPEN", isDraft = true, url = "https://github.com/o/r/pull/7" })
		end)
		local result
		gh.get_pr_state(7, function(err, data)
			result = { err = err, data = data }
		end)
		assert.are.same({ "pr", "view", "7", "--json", "number,state,isDraft,url" }, captured_args)
		assert.is_nil(result.err)
		assert.are.same({ number = 7, state = "OPEN", is_draft = true, url = "https://github.com/o/r/pull/7" }, result.data)
	end)

	it("treats JSON null fields as absent", function()
		helpers.mock(gh, "run_json", function(_, callback)
			callback(nil, { number = vim.NIL, state = vim.NIL, isDraft = vim.NIL, url = vim.NIL })
		end)
		local result
		gh.get_pr_state(7, function(_, data)
			result = data
		end)
		assert.are.same({ state = "", is_draft = false }, result)
	end)

	it("resolves the PR from the commit on a detached HEAD instead of running gh pr view bare", function()
		helpers.mock(vim, "system", function()
			return {
				wait = function()
					return { code = 1, stdout = "", stderr = "" }
				end,
			}
		end)
		helpers.mock(gh, "get_head_sha", function()
			return "abc123"
		end)
		helpers.mock(gh, "get_pr_by_commit", function(sha, callback)
			assert.are.equal("abc123", sha)
			callback(nil, { number = 12 })
		end)
		local captured_args
		helpers.mock(gh, "run_json", function(args, callback)
			captured_args = args
			callback(nil, { number = 12, state = "CLOSED", isDraft = false })
		end)
		gh.get_pr_state(nil, function() end)
		assert.are.same({ "pr", "view", "12", "--json", "number,state,isDraft,url" }, captured_args)
	end)

	it("passes a commit lookup failure through", function()
		helpers.mock(vim, "system", function()
			return {
				wait = function()
					return { code = 1, stdout = "", stderr = "" }
				end,
			}
		end)
		helpers.mock(gh, "get_head_sha", function()
			return "abc123"
		end)
		helpers.mock(gh, "get_pr_by_commit", function(_, callback)
			callback("no PR for commit", nil)
		end)
		local called_run = false
		helpers.mock(gh, "run_json", function()
			called_run = true
		end)
		local result_err
		gh.get_pr_state(nil, function(err)
			result_err = err
		end)
		assert.are.equal("no PR for commit", result_err)
		assert.is_false(called_run)
	end)
end)

describe("is_no_pr_error", function()
	local helpers_for_no_pr = require("tests.helpers")

	it("matches gh's no-PR message", function()
		assert.is_true(gh.is_no_pr_error('no pull requests found for branch "feat/x"\n'))
	end)

	it("matches the commit lookup's no-PR message used on a detached HEAD", function()
		local msg
		helpers_for_no_pr.mock(gh, "run_json", function(_, callback)
			callback(nil, {})
		end)
		gh.get_pr_by_commit("abcdef1234567", function(err)
			msg = err
		end)
		helpers_for_no_pr.cleanup()
		assert.is_true(gh.is_no_pr_error(msg))
	end)

	it("does not match other failures or nil", function()
		assert.is_false(gh.is_no_pr_error("HTTP 401: Bad credentials"))
		assert.is_false(gh.is_no_pr_error("fetching commit: No PR found for commit"))
		assert.is_false(gh.is_no_pr_error(nil))
	end)
end)

describe("build_pr_state_args", function()
	it("maps each action to its gh command", function()
		assert.are.same({ "pr", "ready", "5" }, gh.build_pr_state_args("ready", 5))
		assert.are.same({ "pr", "ready", "5", "--undo" }, gh.build_pr_state_args("draft", 5))
		assert.are.same({ "pr", "close", "5" }, gh.build_pr_state_args("close", 5))
		assert.are.same({ "pr", "reopen", "5" }, gh.build_pr_state_args("reopen", 5))
	end)

	it("returns nil for an unknown action", function()
		assert.is_nil(gh.build_pr_state_args("merge", 5))
	end)
end)

describe("set_pr_state", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("runs the gh command for the action", function()
		local captured_args
		helpers.mock(gh, "run", function(args, callback)
			captured_args = args
			callback(nil, "")
		end)
		local result = "unset"
		gh.set_pr_state("draft", 9, function(err)
			result = err
		end)
		assert.are.same({ "pr", "ready", "9", "--undo" }, captured_args)
		assert.is_nil(result)
	end)

	it("fails without running gh for an unknown action", function()
		local called = false
		helpers.mock(gh, "run", function()
			called = true
		end)
		local result
		gh.set_pr_state("merge", 9, function(err)
			result = err
		end)
		assert.truthy(result:find("Unknown PR state action", 1, true))
		assert.is_false(called)
	end)
end)

describe("review listings pagination", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	local function capture_args(invoke)
		local captured
		helpers.mock(gh, "run_json", function(args, callback)
			captured = args
			callback(nil, {})
		end)
		invoke()
		return captured
	end

	-- The reviews endpoint returns 30 per page oldest first, so without
	-- --paginate the viewer's pending review (the newest) is never found on a
	-- PR with more than 30 reviews.
	it("get_reviews requests every page", function()
		local args = capture_args(function()
			gh.get_reviews(42, function() end)
		end)
		assert.are.equal("repos/{owner}/{repo}/pulls/42/reviews", args[2])
		assert.truthy(vim.tbl_contains(args, "--paginate"))
	end)

	it("get_review_comments requests every page", function()
		local args = capture_args(function()
			gh.get_review_comments(42, 99, function() end)
		end)
		assert.are.equal("repos/{owner}/{repo}/pulls/42/reviews/99/comments", args[2])
		assert.truthy(vim.tbl_contains(args, "--paginate"))
	end)
end)

describe("re_request_review", function()
	local helpers = require("tests.helpers")

	after_each(function()
		helpers.cleanup()
	end)

	it("errors without calling the API when reviewers is empty", function()
		local run_json_called = false
		helpers.mock(gh, "run_json", function()
			run_json_called = true
		end)
		local got_err
		gh.re_request_review(42, {}, function(err, _)
			got_err = err
		end)
		assert.is_false(run_json_called)
		assert.truthy(got_err)
	end)
end)
