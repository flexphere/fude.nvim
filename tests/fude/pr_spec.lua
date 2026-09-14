local pr = require("fude.pr")
local diff = require("fude.diff")
local helpers = require("tests.helpers")

describe("create passes default title to open_pr_float", function()
	local captured_title_lines
	local captured_body_lines

	before_each(function()
		captured_title_lines = nil
		captured_body_lines = nil
		pr.clear_draft()

		-- Mock diff functions
		helpers.mock(diff, "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(diff, "get_default_branch", function()
			return "main"
		end)
		helpers.mock(diff, "get_first_commit_subject", function(_)
			return "Initial commit message"
		end)

		-- Mock find_templates to return empty (no templates, no draft)
		helpers.mock(pr, "find_templates", function()
			return {}
		end)

		-- Mock open_pr_float to capture arguments
		helpers.mock(pr, "open_pr_float", function(title_lines, body_lines)
			captured_title_lines = title_lines
			captured_body_lines = body_lines
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("passes default title when no templates and no draft", function()
		pr.create()
		assert.are.same({ "Initial commit message" }, captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes nil title when default branch is nil", function()
		helpers.mock(diff, "get_default_branch", function()
			return nil
		end)
		pr.create()
		assert.is_nil(captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes nil title when first commit subject is nil", function()
		helpers.mock(diff, "get_first_commit_subject", function(_)
			return nil
		end)
		pr.create()
		assert.is_nil(captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("passes default title when single template exists", function()
		helpers.mock(pr, "find_templates", function()
			return { "/repo/.github/template.md" }
		end)
		-- Mock vim.fn.readfile to return template body
		local original_readfile = vim.fn.readfile
		vim.fn.readfile = function(_)
			return { "Template body line 1", "Template body line 2" }
		end

		pr.create()

		vim.fn.readfile = original_readfile
		assert.are.same({ "Initial commit message" }, captured_title_lines)
		assert.are.same({ "Template body line 1", "Template body line 2" }, captured_body_lines)
	end)

	it("wires on_discard_draft to clear the session draft when opened from the draft", function()
		pr.save_draft({ "Draft title" }, { "Draft body" })
		local captured_opts
		helpers.mock(pr, "open_pr_float", function(_, _, opts)
			captured_opts = opts
		end)

		pr.create()

		assert.is_true(captured_opts.from_draft)
		captured_opts.on_discard_draft()
		assert.is_nil(pr.get_draft())
	end)

	it("does not fetch default title when only draft exists", function()
		local get_first_commit_called = false
		helpers.mock(diff, "get_first_commit_subject", function(_)
			get_first_commit_called = true
			return "Should not be called"
		end)

		-- Save a draft
		pr.save_draft({ "Draft title" }, { "Draft body" })

		-- Mock open_pr_float to track if draft is restored
		local draft_title_lines
		helpers.mock(pr, "open_pr_float", function(title_lines, _)
			draft_title_lines = title_lines
		end)

		pr.create()

		assert.is_false(get_first_commit_called)
		assert.are.same({ "Draft title" }, draft_title_lines)
	end)
end)

describe("build_template_search_paths", function()
	it("returns expected directory paths", function()
		local result = pr.build_template_search_paths("/repo")
		assert.are.equal(3, #result.dirs)
		assert.are.equal("/repo/.github/PULL_REQUEST_TEMPLATE", result.dirs[1])
		assert.are.equal("/repo/PULL_REQUEST_TEMPLATE", result.dirs[2])
		assert.are.equal("/repo/docs/PULL_REQUEST_TEMPLATE", result.dirs[3])
	end)

	it("returns expected file paths", function()
		local result = pr.build_template_search_paths("/repo")
		assert.are.equal(6, #result.files)
		assert.are.equal("/repo/.github/pull_request_template.md", result.files[1])
		assert.are.equal("/repo/.github/PULL_REQUEST_TEMPLATE.md", result.files[2])
		assert.are.equal("/repo/pull_request_template.md", result.files[3])
		assert.are.equal("/repo/PULL_REQUEST_TEMPLATE.md", result.files[4])
		assert.are.equal("/repo/docs/pull_request_template.md", result.files[5])
		assert.are.equal("/repo/docs/PULL_REQUEST_TEMPLATE.md", result.files[6])
	end)

	it("prepends repo_root to all paths", function()
		local result = pr.build_template_search_paths("/home/user/project")
		for _, d in ipairs(result.dirs) do
			assert.is_true(d:sub(1, #"/home/user/project") == "/home/user/project")
		end
		for _, f in ipairs(result.files) do
			assert.is_true(f:sub(1, #"/home/user/project") == "/home/user/project")
		end
	end)
end)

describe("build_picker_entries", function()
	it("returns only template entries when no draft", function()
		local entries = pr.build_picker_entries({ "/repo/.github/template.md" }, false)
		assert.are.equal(1, #entries)
		assert.are.equal("template.md", entries[1].display)
		assert.are.equal("/repo/.github/template.md", entries[1].value)
		assert.is_false(entries[1].is_draft)
	end)

	it("prepends draft entry when draft exists", function()
		local entries = pr.build_picker_entries({ "/repo/.github/template.md" }, true)
		assert.are.equal(2, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.are.equal("__draft__", entries[1].value)
		assert.is_true(entries[1].is_draft)
		assert.are.equal("template.md", entries[2].display)
		assert.is_false(entries[2].is_draft)
	end)

	it("returns only draft entry when no templates", function()
		local entries = pr.build_picker_entries({}, true)
		assert.are.equal(1, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.is_true(entries[1].is_draft)
	end)

	it("returns empty when no templates and no draft", function()
		local entries = pr.build_picker_entries({}, false)
		assert.are.equal(0, #entries)
	end)

	it("preserves template order after draft", function()
		local entries = pr.build_picker_entries({
			"/repo/.github/bug_report.md",
			"/repo/.github/feature_request.md",
		}, true)
		assert.are.equal(3, #entries)
		assert.are.equal("(draft)", entries[1].display)
		assert.are.equal("bug_report.md", entries[2].display)
		assert.are.equal("feature_request.md", entries[3].display)
	end)
end)

describe("parse_pr_buffer", function()
	it("parses title and body from lines", function()
		local result = pr.parse_pr_buffer({ "My PR Title" }, { "## Summary", "", "Description here" })
		assert.are.equal("My PR Title", result.title)
		assert.are.equal("## Summary\n\nDescription here", result.body)
	end)

	it("trims whitespace from title", function()
		local result = pr.parse_pr_buffer({ "  spaced title  " }, { "body" })
		assert.are.equal("spaced title", result.title)
	end)

	it("trims whitespace from body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "", "  body  ", "" })
		assert.are.equal("body", result.body)
	end)

	it("handles empty title", function()
		local result = pr.parse_pr_buffer({ "" }, { "body" })
		assert.are.equal("", result.title)
	end)

	it("handles empty body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "" })
		assert.are.equal("title", result.title)
		assert.are.equal("", result.body)
	end)

	it("handles both empty", function()
		local result = pr.parse_pr_buffer({ "" }, { "" })
		assert.are.equal("", result.title)
		assert.are.equal("", result.body)
	end)

	it("joins multiple title lines with space", function()
		local result = pr.parse_pr_buffer({ "part1", "part2" }, { "body" })
		assert.are.equal("part1 part2", result.title)
	end)

	it("preserves multiline body", function()
		local result = pr.parse_pr_buffer({ "title" }, { "line1", "line2", "line3" })
		assert.are.equal("line1\nline2\nline3", result.body)
	end)

	it("does not trim body when trim_body is false", function()
		local result = pr.parse_pr_buffer({ "title" }, { "", "  body  ", "" }, { trim_body = false })
		assert.are.equal("\n  body  \n", result.body)
	end)

	it("trims body by default (trim_body not specified)", function()
		local result = pr.parse_pr_buffer({ "title" }, { "", "  body  ", "" })
		assert.are.equal("body", result.body)
	end)

	it("trims body when trim_body is true", function()
		local result = pr.parse_pr_buffer({ "title" }, { "", "  body  ", "" }, { trim_body = true })
		assert.are.equal("body", result.body)
	end)
end)

describe("parse_body_attachments", function()
	it("extracts image references with file:// scheme and strips the prefix", function()
		local result = pr.parse_body_attachments("before\n![shot](file://./img/shot.png)\nafter")
		assert.are.equal("before\n![shot](./img/shot.png)\nafter", result.body)
		assert.are.same({ "./img/shot.png" }, result.attachments)
	end)

	it("extracts link references with file:// scheme", function()
		local result = pr.parse_body_attachments("[demo video](file:///tmp/demo.mp4)")
		assert.are.equal("[demo video](/tmp/demo.mp4)", result.body)
		assert.are.same({ "/tmp/demo.mp4" }, result.attachments)
	end)

	it("returns body unchanged and empty attachments when no file:// reference exists", function()
		local body = "![repo image](./docs/logo.png)\nplain text"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("deduplicates multiple references to the same file", function()
		local result = pr.parse_body_attachments("![a](file://./x.png)\n![b](file://./x.png)")
		assert.are.equal("![a](./x.png)\n![b](./x.png)", result.body)
		assert.are.same({ "./x.png" }, result.attachments)
	end)

	it("collects multiple distinct attachments in order of appearance", function()
		local result = pr.parse_body_attachments("![a](file://./a.png) ![b](file://./b.png)")
		assert.are.same({ "./a.png", "./b.png" }, result.attachments)
	end)

	it("skips references inside fenced code blocks", function()
		local body = "```\n![a](file://./in-fence.png)\n```\n![b](file://./out.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal("```\n![a](file://./in-fence.png)\n```\n![b](./out.png)", result.body)
		assert.are.same({ "./out.png" }, result.attachments)
	end)

	it("skips references inside ~~~ fenced code blocks", function()
		local body = "~~~\n![a](file://./in-fence.png)\n~~~\n![b](file://./out.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal("~~~\n![a](file://./in-fence.png)\n~~~\n![b](./out.png)", result.body)
		assert.are.same({ "./out.png" }, result.attachments)
	end)

	it("does not close a ``` fence with a ~~~ line", function()
		local body = "```\n~~~\n![a](file://./still-in-fence.png)\n```\n![b](file://./out.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.same({ "./out.png" }, result.attachments)
	end)

	it("skips everything after an unclosed fence (documented limitation)", function()
		local body = "```lua\ncode\n![s](file://./x.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("captures paths containing spaces and rewrites them in angle-bracket form", function()
		-- gh parses the body as CommonMark: a bare destination with spaces is
		-- not a link, so gh would append the upload instead of rewriting it
		local result = pr.parse_body_attachments("![shot](file://./Screen Shot 2026-09-03.png)")
		assert.are.equal("![shot](<./Screen Shot 2026-09-03.png>)", result.body)
		assert.are.same({ "./Screen Shot 2026-09-03.png" }, result.attachments)
	end)

	it("accepts the angle-bracket input form", function()
		local result = pr.parse_body_attachments("![shot](<file://./a b.png>)")
		assert.are.equal("![shot](<./a b.png>)", result.body)
		assert.are.same({ "./a b.png" }, result.attachments)
	end)

	it("rewrites different spellings of the same file to the first-seen spelling", function()
		local result = pr.parse_body_attachments("![a](file://./img/x.png)\n![b](file://img/x.png)")
		assert.are.equal("![a](./img/x.png)\n![b](./img/x.png)", result.body)
		assert.are.same({ "./img/x.png" }, result.attachments)
	end)

	it("ignores bare file:// URLs outside markdown link syntax", function()
		local body = "see file://./x.png for details"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("keeps angle-bracket form for paths containing parentheses", function()
		local result = pr.parse_body_attachments("![s](<file://./shot(1).png>)")
		assert.are.equal("![s](<./shot(1).png>)", result.body)
		assert.are.same({ "./shot(1).png" }, result.attachments)
	end)

	it("rewrites a bare path containing '(' in angle-bracket form", function()
		local result = pr.parse_body_attachments("![s](file://./shot(1.png)")
		assert.are.equal("![s](<./shot(1.png>)", result.body)
		assert.are.same({ "./shot(1.png" }, result.attachments)
	end)

	it("leaves paths containing '<' untouched", function()
		local body = "![s](file://./a<b.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("does not close a fence with an info-string line inside it", function()
		local body = "```\n```lua\n![s](file://./x.png)\n```\n![b](file://./out.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.same({ "./out.png" }, result.attachments)
	end)

	it("closes a fence with a longer marker run", function()
		local body = "```\ncode\n`````\n![b](file://./out.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.same({ "./out.png" }, result.attachments)
	end)

	it("leaves paths containing '#' untouched (gh's alt text separator)", function()
		local body = "![s](file://./issue#12.png)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("leaves angle-bracket paths containing '#' untouched", function()
		local body = "![s](<file://./issue #12.png>)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("ignores file:// with no path", function()
		local body = "![empty](file://)"
		local result = pr.parse_body_attachments(body)
		assert.are.equal(body, result.body)
		assert.are.same({}, result.attachments)
	end)

	it("applies expand_fn to both body and attachments", function()
		local result = pr.parse_body_attachments("![a](file://~/shot.png)", function(path)
			return (path:gsub("^~", "/home/user"))
		end)
		assert.are.equal("![a](/home/user/shot.png)", result.body)
		assert.are.same({ "/home/user/shot.png" }, result.attachments)
	end)

	it("deduplicates by expanded path when spellings differ", function()
		local result = pr.parse_body_attachments("![a](file://~/x.png) ![b](file:///home/user/x.png)", function(path)
			return (path:gsub("^~", "/home/user"))
		end)
		assert.are.same({ "/home/user/x.png" }, result.attachments)
	end)
end)

describe("format_attach_error", function()
	it("replaces unknown --attach flag errors with a concise upgrade hint", function()
		local result = pr.format_attach_error("unknown flag: --attach\n\nUsage:  gh pr create [flags]\n...")
		assert.are.equal("PR body attachments (--attach) require gh >= 2.99.0; please update GitHub CLI", result)
	end)

	it("returns other errors unchanged", function()
		local result = pr.format_attach_error("gh command failed")
		assert.are.equal("gh command failed", result)
	end)
end)

describe("clean_pasted_path", function()
	it("strips surrounding single quotes", function()
		assert.are.equal("/tmp/shot.png", pr.clean_pasted_path("'/tmp/shot.png'"))
	end)

	it("strips surrounding double quotes", function()
		assert.are.equal("/tmp/shot.png", pr.clean_pasted_path('"/tmp/shot.png"'))
	end)

	it("strips surrounding whitespace and trailing newline", function()
		assert.are.equal("/tmp/shot.png", pr.clean_pasted_path("  /tmp/shot.png\n"))
	end)

	it("unescapes shell-escaped spaces", function()
		assert.are.equal("/tmp/Screen Shot.png", pr.clean_pasted_path("/tmp/Screen\\ Shot.png"))
	end)

	it("keeps unquoted text unchanged", function()
		assert.are.equal("/tmp/shot.png", pr.clean_pasted_path("/tmp/shot.png"))
	end)

	it("does not strip mismatched quotes", function()
		assert.are.equal("'/tmp/shot.png", pr.clean_pasted_path("'/tmp/shot.png"))
	end)
end)

describe("is_local_media_path", function()
	it("accepts absolute, home-relative, and dot-relative media paths", function()
		assert.is_true(pr.is_local_media_path("/tmp/shot.png"))
		assert.is_true(pr.is_local_media_path("~/Movies/demo.mp4"))
		assert.is_true(pr.is_local_media_path("./img/shot.JPG"))
		assert.is_true(pr.is_local_media_path("../shot.webp"))
	end)

	it("rejects non-media extensions", function()
		assert.is_false(pr.is_local_media_path("/tmp/notes.txt"))
		assert.is_false(pr.is_local_media_path("/tmp/archive"))
	end)

	it("rejects bare relative paths and URLs", function()
		assert.is_false(pr.is_local_media_path("img/shot.png"))
		assert.is_false(pr.is_local_media_path("https://example.com/shot.png"))
	end)

	it("rejects paths containing '#' (unattachable via gh --attach)", function()
		assert.is_false(pr.is_local_media_path("/tmp/issue#12.png"))
	end)

	it("rejects paths containing '<' or '>' (break the angle-bracket destination)", function()
		assert.is_false(pr.is_local_media_path("/tmp/a<b.png"))
		assert.is_false(pr.is_local_media_path("/tmp/a>b.png"))
	end)
end)

describe("transform_media_paste", function()
	it("wraps a pasted media path in markdown image syntax with file://", function()
		local result = pr.transform_media_paste({ "/tmp/shot.png" }, "")
		assert.are.same({ "![](file:///tmp/shot.png)" }, result)
	end)

	it("strips Finder quotes and uses angle-bracket form for spaced paths", function()
		local result = pr.transform_media_paste({ "'/tmp/Screen Shot.png'" }, "")
		assert.are.same({ "![](<file:///tmp/Screen Shot.png>)" }, result)
	end)

	it("inserts only the bare path when cursor is right after file://", function()
		local result = pr.transform_media_paste({ "'/tmp/shot.png'" }, "![](file://")
		assert.are.same({ "/tmp/shot.png" }, result)
	end)

	it("inserts file:// plus path when cursor is right after ](", function()
		local result = pr.transform_media_paste({ "/tmp/shot.png" }, "![](")
		assert.are.same({ "file:///tmp/shot.png" }, result)
	end)

	it("ignores a trailing empty line from the paste", function()
		local result = pr.transform_media_paste({ "/tmp/shot.png", "" }, "")
		assert.are.same({ "![](file:///tmp/shot.png)" }, result)
	end)

	it("returns nil for multi-line pastes", function()
		assert.is_nil(pr.transform_media_paste({ "/tmp/a.png", "/tmp/b.png" }, ""))
	end)

	it("returns nil for non-media pastes", function()
		assert.is_nil(pr.transform_media_paste({ "plain text" }, ""))
		assert.is_nil(pr.transform_media_paste({ "/tmp/notes.txt" }, ""))
	end)

	it("uses angle-bracket form for paths containing parentheses", function()
		local result = pr.transform_media_paste({ "/tmp/shot(1).png" }, "")
		assert.are.same({ "![](<file:///tmp/shot(1).png>)" }, result)
	end)
end)

describe("open_pr_float paste interception", function()
	local original_paste

	before_each(function()
		original_paste = vim.paste
	end)

	after_each(function()
		helpers.cleanup()
		vim.paste = original_paste
	end)

	-- Open the PR float and focus the body window; return the body buffer.
	local function open_and_focus_body()
		pr.open_pr_float({ "title" }, { "" }, {})
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].filetype == "markdown" then
				vim.api.nvim_set_current_win(win)
				return buf
			end
		end
		error("body window not found")
	end

	it("merges streamed chunks across arbitrary boundaries", function()
		local buf = open_and_focus_body()
		vim.paste({ "he" }, 1)
		vim.paste({ "llo", "world" }, 2)
		vim.paste({ "!" }, 3)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.are.same("hello\nworld!", table.concat(lines, "\n"))
	end)

	it("handles a streamed paste whose first chunk is empty", function()
		local buf = open_and_focus_body()
		-- nvim_paste can deliver an empty first chunk (chunk boundaries are
		-- arbitrary, e.g. bracketed paste through tmux); this used to crash
		-- with "attempt to concatenate a nil value"
		vim.paste({}, 1)
		vim.paste({ "foo", "bar" }, 2)
		vim.paste({ "baz" }, 3)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.are.same("foo\nbarbaz", table.concat(lines, "\n"))
	end)
end)

describe("serialize_edit_draft / parse_edit_draft", function()
	it("round-trips title and multi-line body", function()
		local text = pr.serialize_edit_draft({ "My Title" }, { "line1", "", "line3" })
		assert.are.equal("My Title\nline1\n\nline3", text)
		local parsed = pr.parse_edit_draft(text)
		assert.are.same({ "My Title" }, parsed.title_lines)
		assert.are.same({ "line1", "", "line3" }, parsed.body_lines)
	end)

	it("joins multi-line titles with spaces like parse_pr_buffer", function()
		assert.are.equal("a b\nbody", pr.serialize_edit_draft({ "a", "b" }, { "body" }))
	end)

	it("round-trips an empty title", function()
		local parsed = pr.parse_edit_draft(pr.serialize_edit_draft({ "" }, { "body" }))
		assert.are.same({ "" }, parsed.title_lines)
		assert.are.same({ "body" }, parsed.body_lines)
	end)

	it("parses a title-only draft with an empty body", function()
		local parsed = pr.parse_edit_draft("only title")
		assert.are.same({ "only title" }, parsed.title_lines)
		assert.are.same({ "" }, parsed.body_lines)
	end)
end)

describe("open_pr_float cancel confirmation", function()
	local orig_select
	local orig_paste
	local select_choice
	local select_calls

	local function get_q_callback(buf)
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if map.lhs == "q" then
				return map.callback
			end
		end
		error("q mapping not found for buffer " .. buf)
	end

	-- Open the float and return title/body buffer and window handles.
	local function open_float(title_lines, body_lines, opts)
		pr.open_pr_float(title_lines, body_lines, opts or {})
		local title_win = vim.api.nvim_get_current_win()
		local title_buf = vim.api.nvim_get_current_buf()
		local body_win, body_buf
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].filetype == "markdown" then
				body_win, body_buf = win, buf
			end
		end
		assert.is_not_nil(body_buf)
		return { title_win = title_win, title_buf = title_buf, body_win = body_win, body_buf = body_buf }
	end

	before_each(function()
		pr.clear_draft()
		orig_select = vim.ui.select
		orig_paste = vim.paste
		select_calls = {}
		vim.ui.select = function(items, sopts, on_choice)
			table.insert(select_calls, { items = items, prompt = sopts and sopts.prompt })
			on_choice(select_choice, nil)
		end
	end)

	after_each(function()
		vim.ui.select = orig_select
		select_choice = nil
		vim.cmd("stopinsert")
		helpers.cleanup()
		vim.paste = orig_paste
		pr.clear_draft()
	end)

	it("closes immediately without prompting when nothing changed", function()
		select_choice = "should-not-be-used"
		local h = open_float({ "t" }, { "b" }, {})
		get_q_callback(h.title_buf)()
		assert.are.equal(0, #select_calls)
		assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("prompts when only the title changed", function()
		select_choice = nil -- keep editing
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.title_buf, 0, -1, false, { "changed" })
		get_q_callback(h.title_buf)()
		assert.are.equal(1, #select_calls)
		assert.are.equal("Unsaved PR:", select_calls[1].prompt)
		assert.is_true(vim.api.nvim_win_is_valid(h.title_win))
	end)

	it("prompts when only the body changed", function()
		select_choice = nil -- keep editing
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "changed" })
		get_q_callback(h.body_buf)()
		assert.are.equal(1, #select_calls)
		assert.is_true(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("saves a create draft and closes when 'Save draft & close' chosen", function()
		select_choice = "Save draft & close"
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
		get_q_callback(h.body_buf)()
		local d = pr.get_draft()
		assert.is_not_nil(d)
		assert.are.same({ "t" }, d.title_lines)
		assert.are.same({ "edited body" }, d.body_lines)
		assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("closes without saving when 'Discard & close' chosen", function()
		select_choice = "Discard & close"
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
		get_q_callback(h.body_buf)()
		assert.is_nil(pr.get_draft())
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("keeps the float open when 'Keep editing' chosen", function()
		select_choice = nil
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
		get_q_callback(h.body_buf)()
		assert.is_true(vim.api.nvim_win_is_valid(h.title_win))
		assert.is_true(vim.api.nvim_win_is_valid(h.body_win))
		assert.is_nil(pr.get_draft())
	end)

	it("routes edit-mode save to the caller's draft handler", function()
		local saved
		select_choice = "Save draft & close"
		local h = open_float({ "t" }, { "b" }, {
			mode = "edit",
			allow_draft = true,
			on_save_draft = function(t_lines, b_lines)
				saved = { t = t_lines, b = b_lines }
			end,
		})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "x" })
		get_q_callback(h.body_buf)()
		assert.are.same({ "t" }, saved.t)
		assert.are.same({ "x" }, saved.b)
		-- the built-in create draft must not be touched in edit mode
		assert.is_nil(pr.get_draft())
	end)

	it("routes edit-mode discard to the caller's draft handler", function()
		local discarded = false
		select_choice = "Discard & close"
		local h = open_float({ "t" }, { "b" }, {
			mode = "edit",
			allow_draft = true,
			on_save_draft = function() end,
			on_discard_draft = function()
				discarded = true
			end,
		})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "x" })
		get_q_callback(h.body_buf)()
		assert.is_true(discarded)
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("falls back to Yes/No confirmation in edit mode without a draft handler", function()
		select_choice = "Yes"
		local h = open_float({ "t" }, { "b" }, { mode = "edit" })
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "x" })
		get_q_callback(h.body_buf)()
		assert.are.equal(1, #select_calls)
		assert.are.equal("Discard changes?", select_calls[1].prompt)
		assert.are.same({ "Yes", "No" }, select_calls[1].items)
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	it("shows the draft-restored footer in edit mode opened from a draft", function()
		local h = open_float({ "t" }, { "b" }, { mode = "edit", from_draft = true })
		local cfg = vim.api.nvim_win_get_config(h.body_win)
		local text = ""
		for _, chunk in ipairs(cfg.footer or {}) do
			text = text .. chunk[1]
		end
		assert.are.equal(" <CR> update | q cancel (draft restored) ", text)
	end)
end)

describe("format_attach_suffix", function()
	it("returns empty string for zero attachments", function()
		assert.are.equal("", pr.format_attach_suffix(0))
	end)

	it("uses singular for one attachment", function()
		assert.are.equal(" (1 file attached)", pr.format_attach_suffix(1))
	end)

	it("uses plural for multiple attachments", function()
		assert.are.equal(" (3 files attached)", pr.format_attach_suffix(3))
	end)
end)

describe("draft management", function()
	before_each(function()
		pr.clear_draft()
	end)

	it("returns nil when no draft exists", function()
		assert.is_nil(pr.get_draft())
	end)

	it("saves and retrieves a draft", function()
		pr.save_draft({ "my title" }, { "body line 1", "body line 2" })
		local d = pr.get_draft()
		assert.is_not_nil(d)
		assert.are.same({ "my title" }, d.title_lines)
		assert.are.same({ "body line 1", "body line 2" }, d.body_lines)
	end)

	it("clears a saved draft", function()
		pr.save_draft({ "title" }, { "body" })
		pr.clear_draft()
		assert.is_nil(pr.get_draft())
	end)

	it("overwrites previous draft on save", function()
		pr.save_draft({ "old title" }, { "old body" })
		pr.save_draft({ "new title" }, { "new body" })
		local d = pr.get_draft()
		assert.are.same({ "new title" }, d.title_lines)
		assert.are.same({ "new body" }, d.body_lines)
	end)
end)

describe("edit", function()
	local gh = require("fude.gh")
	local config = require("fude.config")
	local captured_pr_number
	local captured_title_lines
	local captured_body_lines
	local captured_opts

	before_each(function()
		captured_pr_number = nil
		captured_title_lines = nil
		captured_body_lines = nil
		captured_opts = nil
		config.reset_state()

		-- Mock open_pr_float to capture arguments
		helpers.mock(pr, "open_pr_float", function(title_lines, body_lines, opts)
			captured_title_lines = title_lines
			captured_body_lines = body_lines
			captured_opts = opts
		end)
	end)

	after_each(function()
		helpers.cleanup()
	end)

	it("uses state.pr_number when review mode is active", function()
		config.state.active = true
		config.state.pr_number = 42

		helpers.mock(gh, "get_pr_title_body", function(pr_num, callback)
			captured_pr_number = pr_num
			vim.schedule(function()
				callback(nil, { title = "PR Title", body = "PR Body" })
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_pr_number ~= nil
		end)

		assert.are.equal(42, captured_pr_number)
	end)

	it("resolves pr_number via get_pr_info when review mode is inactive", function()
		config.state.active = false
		config.state.pr_number = nil

		helpers.mock(gh, "get_pr_info", function(callback)
			vim.schedule(function()
				callback(nil, { number = 99, baseRefName = "main", headRefName = "feature", url = "" })
			end)
		end)

		helpers.mock(gh, "get_pr_title_body", function(pr_num, callback)
			captured_pr_number = pr_num
			vim.schedule(function()
				callback(nil, { title = "PR Title", body = "PR Body" })
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_title_lines ~= nil
		end)

		assert.are.equal(99, captured_pr_number)
	end)

	it("opens float with edit mode and correct content", function()
		config.state.active = false

		helpers.mock(gh, "get_pr_info", function(callback)
			vim.schedule(function()
				callback(nil, { number = 50, baseRefName = "main", headRefName = "feature", url = "" })
			end)
		end)

		helpers.mock(gh, "get_pr_title_body", function(_, callback)
			vim.schedule(function()
				callback(nil, { title = "Existing Title", body = "Line 1\nLine 2" })
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		assert.are.same({ "Existing Title" }, captured_title_lines)
		assert.are.same({ "Line 1", "Line 2" }, captured_body_lines)
		assert.are.equal("edit", captured_opts.mode)
		-- footer is no longer passed: open_pr_float derives it from mode/from_draft
		assert.is_nil(captured_opts.footer)
		assert.is_false(captured_opts.from_draft)
		-- no url in the mocked response -> no draft key -> drafts disabled
		assert.is_false(captured_opts.allow_draft)
		assert.is_not_nil(captured_opts.on_submit)
	end)

	it("on_submit calls gh.edit_pr with correct arguments", function()
		config.state.active = true
		config.state.pr_number = 123

		local edit_called_with = nil

		helpers.mock(gh, "get_pr_title_body", function(_, callback)
			vim.schedule(function()
				callback(nil, { title = "Original", body = "Body" })
			end)
		end)

		helpers.mock(gh, "edit_pr", function(pr_num, title, body, attachments, callback)
			edit_called_with = { pr_number = pr_num, title = title, body = body, attachments = attachments }
			vim.schedule(function()
				callback(nil)
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil and captured_opts.on_submit ~= nil
		end)

		-- Simulate submit (pass close_float mock as third arg for edit mode)
		local close_float_called = false
		captured_opts.on_submit("New Title", "New Body", function()
			close_float_called = true
		end)
		helpers.wait_for(function()
			return edit_called_with ~= nil
		end)

		assert.are.equal(123, edit_called_with.pr_number)
		assert.are.equal("New Title", edit_called_with.title)
		assert.are.equal("New Body", edit_called_with.body)
		assert.are.same({}, edit_called_with.attachments)

		-- close_float should be called on success
		helpers.wait_for(function()
			return close_float_called
		end)
		assert.is_true(close_float_called)
	end)

	it("on_submit extracts file:// attachments and passes stripped body to gh.edit_pr", function()
		config.state.active = true
		config.state.pr_number = 123

		local edit_called_with = nil

		helpers.mock(gh, "get_pr_title_body", function(_, callback)
			vim.schedule(function()
				callback(nil, { title = "Original", body = "Body" })
			end)
		end)

		helpers.mock(gh, "edit_pr", function(_, _, body, attachments, callback)
			edit_called_with = { body = body, attachments = attachments }
			vim.schedule(function()
				callback(nil)
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil and captured_opts.on_submit ~= nil
		end)

		captured_opts.on_submit("Title", "intro\n![shot](file://./img.png)", function() end)
		helpers.wait_for(function()
			return edit_called_with ~= nil
		end)

		assert.are.equal("intro\n![shot](./img.png)", edit_called_with.body)
		assert.are.same({ "./img.png" }, edit_called_with.attachments)
	end)
end)

describe("edit draft persistence", function()
	local gh = require("fude.gh")
	local config = require("fude.config")
	local drafts = require("fude.drafts")
	local captured_title_lines
	local captured_body_lines
	local captured_opts
	local key

	before_each(function()
		captured_title_lines = nil
		captured_body_lines = nil
		captured_opts = nil
		config.reset_state()
		drafts._dir = vim.fn.tempname()
		key = drafts.make_draft_key("owner/repo", 77, "pr_edit")
		config.state.active = true
		config.state.pr_number = 77

		helpers.mock(pr, "open_pr_float", function(title_lines, body_lines, opts)
			captured_title_lines = title_lines
			captured_body_lines = body_lines
			captured_opts = opts
		end)
		helpers.mock(gh, "get_pr_title_body", function(_, callback)
			vim.schedule(function()
				callback(nil, {
					title = "API Title",
					body = "api body",
					url = "https://github.com/owner/repo/pull/77",
				})
			end)
		end)
	end)

	after_each(function()
		helpers.cleanup()
		drafts._dir = nil
	end)

	it("enables draft saving and wires handlers when the PR url is available", function()
		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		assert.is_true(captured_opts.allow_draft)
		assert.is_false(captured_opts.from_draft)
		assert.are.same({ "API Title" }, captured_title_lines)
		assert.are.same({ "api body" }, captured_body_lines)

		captured_opts.on_save_draft({ "new title" }, { "new body", "l2" })
		assert.are.equal("new title\nnew body\nl2", drafts.get(key))

		captured_opts.on_discard_draft()
		assert.is_nil(drafts.get(key))
	end)

	it("prefills from a saved draft and marks the float as from_draft", function()
		drafts.set(key, "draft title\ndraft body")

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		assert.are.same({ "draft title" }, captured_title_lines)
		assert.are.same({ "draft body" }, captured_body_lines)
		assert.is_true(captured_opts.from_draft)
		assert.is_true(captured_opts.allow_draft)
	end)

	it("removes the draft after a successful submit", function()
		drafts.set(key, "draft title\ndraft body")
		helpers.mock(gh, "edit_pr", function(_, _, _, _, callback)
			vim.schedule(function()
				callback(nil)
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		local closed = false
		captured_opts.on_submit("T", "B", function()
			closed = true
		end)
		helpers.wait_for(function()
			return closed
		end)

		assert.is_nil(drafts.get(key))
	end)

	it("keeps the draft when submit fails", function()
		drafts.set(key, "draft title\ndraft body")
		local edit_called = false
		helpers.mock(gh, "edit_pr", function(_, _, _, _, callback)
			edit_called = true
			vim.schedule(function()
				callback("boom")
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		captured_opts.on_submit("T", "B", function() end)
		helpers.wait_for(function()
			return edit_called
		end)
		-- the error path runs one scheduled tick after the callback; give it
		-- time to (not) remove the draft
		vim.wait(100, function()
			return false
		end)

		assert.are.equal("draft title\ndraft body", drafts.get(key))
	end)

	it("disables draft saving when drafts.enabled is false", function()
		local orig_drafts_opt = config.opts.drafts
		config.opts.drafts = { enabled = false }

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		local allow_draft = captured_opts.allow_draft
		config.opts.drafts = orig_drafts_opt
		assert.is_false(allow_draft)
	end)

	it("clears the draft instead of claiming a save for empty input", function()
		drafts.set(key, "old title\nold body")

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		captured_opts.on_save_draft({ "" }, { "" })
		assert.is_nil(drafts.get(key))
	end)

	it("disables draft saving when the PR url yields no repo slug", function()
		helpers.mock(gh, "get_pr_title_body", function(_, callback)
			vim.schedule(function()
				callback(nil, { title = "API Title", body = "api body", url = nil })
			end)
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		assert.is_false(captured_opts.allow_draft)
		assert.is_false(captured_opts.from_draft)
	end)
end)
