local pr = require("fude.pr")
local diff = require("fude.diff")
local gh = require("fude.gh")
local drafts = require("fude.drafts")
local helpers = require("tests.helpers")

-- The creation draft key create() resolves from the mocked git state below
local CREATE_DRAFT_KEY = pr.build_create_draft_key("/repo/.git", "feat/me")

describe("create passes default title to open_pr_float", function()
	local captured_title_lines
	local captured_body_lines
	local captured_opts
	local base_entries
	local base_callback
	local stack_prompts
	local stack_answer
	local lookup_branches
	local lookup_result
	local notifications
	local draft_dir
	local resume_prompts
	local resume_answer

	before_each(function()
		-- Mock the draft prompt: record it and pick resume_answer, or the first
		-- entry like a fresh <CR> in the picker would
		resume_prompts = {}
		resume_answer = nil
		helpers.mock(pr, "confirm_draft_resume", function(d, callback)
			local choices = pr.build_draft_resume_choices(d)
			table.insert(resume_prompts, { draft = d, choices = choices })
			callback(resume_answer or choices[1].value)
		end)
		captured_title_lines = nil
		captured_body_lines = nil
		captured_opts = nil
		base_entries = nil
		base_callback = nil
		pr.clear_draft()
		draft_dir = vim.fn.tempname()
		vim.fn.mkdir(draft_dir, "p")
		drafts._dir = draft_dir

		-- Mock diff functions
		helpers.mock(diff, "get_repo_root", function()
			return "/repo"
		end)
		helpers.mock(diff, "get_git_common_dir", function()
			return "/repo/.git"
		end)
		helpers.mock(diff, "get_default_branch", function()
			return "main"
		end)
		helpers.mock(diff, "get_remote_branches", function()
			return { "feat/other", "main" }
		end)
		helpers.mock(diff, "get_current_branch", function()
			return "feat/me"
		end)
		helpers.mock(diff, "get_gh_stack_parent", function(_)
			return nil
		end)
		helpers.mock(diff, "get_ancestor_branches", function(_)
			return {}
		end)
		stack_prompts = {}
		stack_answer = false
		helpers.mock(pr, "confirm_stack", function(base, callback)
			table.insert(stack_prompts, base)
			callback(stack_answer)
		end)
		lookup_branches = {}
		lookup_result = {
			nil,
			{ url = "https://github.com/o/r/pull/1", stack_number = 3, stack_size = 2, stack_position = 2 },
		}
		helpers.mock(gh, "get_open_pr_stack", function(branch, callback)
			table.insert(lookup_branches, branch)
			callback(lookup_result[1], lookup_result[2])
		end)
		notifications = {}
		helpers.mock(pr, "show_stack_error", function(msg)
			table.insert(notifications, { msg = msg, level = vim.log.levels.ERROR })
		end)
		helpers.mock(vim, "notify", function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end)
		helpers.mock(diff, "get_first_commit_subject", function(_)
			return "Initial commit message"
		end)

		-- Mock the base picker: capture entries, pick the first entry (the
		-- default branch) synchronously like a fresh <CR> in the picker would
		helpers.mock(pr, "select_base_branch", function(entries, callback)
			base_entries = entries
			base_callback = callback
			callback(entries[1].value)
		end)

		-- Mock find_templates to return empty (no templates, no draft)
		helpers.mock(pr, "find_templates", function()
			return {}
		end)

		-- Mock open_pr_float to capture arguments
		helpers.mock(pr, "open_pr_float", function(title_lines, body_lines, opts)
			captured_title_lines = title_lines
			captured_body_lines = body_lines
			captured_opts = opts
		end)
	end)

	after_each(function()
		helpers.cleanup()
		drafts._dir = nil
		vim.fn.delete(draft_dir, "rf")
	end)

	it("passes default title when no templates and no draft", function()
		pr.create()
		assert.are.same({ "Initial commit message" }, captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("wires the stack parent and ancestors from git right after the default branch", function()
		local stack_arg, ancestor_arg
		helpers.mock(diff, "get_remote_branches", function()
			return { "feat/me", "zzz", "feat/base", "feat/parent", "main" }
		end)
		helpers.mock(diff, "get_gh_stack_parent", function(branch)
			stack_arg = branch
			return "feat/parent"
		end)
		helpers.mock(diff, "get_ancestor_branches", function(default_branch)
			ancestor_arg = default_branch
			return { "feat/parent", "feat/base" }
		end)
		pr.create()
		assert.are.equal("feat/me", stack_arg)
		assert.are.equal("main", ancestor_arg)
		assert.are.same(
			{ "main (default)", "feat/parent (stack parent)", "feat/base (ancestor)", "zzz" },
			vim.tbl_map(function(e)
				return e.display
			end, base_entries)
		)
	end)

	it("asks whether to stack for a non-default base and follows the answer", function()
		helpers.mock(diff, "get_remote_branches", function()
			return { "feat/parent", "feat/base", "main" }
		end)
		helpers.mock(diff, "get_gh_stack_parent", function(_)
			return "feat/parent"
		end)
		helpers.mock(diff, "get_ancestor_branches", function(_)
			return { "feat/base" }
		end)
		local pick
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback(pick)
		end)

		pick = "feat/parent"
		stack_answer = true
		pr.create()
		assert.are.same({ "feat/parent" }, stack_prompts)
		assert.are.same({ "feat/parent" }, lookup_branches)
		assert.are.equal("feat/parent", captured_opts.base)
		assert.are.same(
			{ parent_url = "https://github.com/o/r/pull/1", new_stack = false, stack_number = 3 },
			captured_opts.stack
		)

		pick = "feat/base"
		stack_answer = false
		pr.create()
		assert.are.same({ "feat/parent", "feat/base" }, stack_prompts)
		assert.are.same({ "feat/parent" }, lookup_branches)
		assert.are.equal("feat/base", captured_opts.base)
		assert.is_nil(captured_opts.stack)
	end)

	it("does not ask about stacking when the default branch is picked", function()
		pr.create()
		assert.are.same({}, stack_prompts)
		assert.are.same({}, lookup_branches)
		assert.are.equal("main", captured_opts.base)
		assert.is_nil(captured_opts.stack)
	end)

	it("creates a new stack without asking again when the parent PR is in no stack", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = true
		lookup_result = { nil, { url = "https://github.com/o/r/pull/1", base_ref = "feat/grand" } }
		pr.create()
		assert.are.same({ "feat/other" }, stack_prompts)
		assert.are.same(
			{ parent_url = "https://github.com/o/r/pull/1", new_stack = true, parent_base = "feat/grand" },
			captured_opts.stack
		)
	end)

	describe("when the parent PR is below the top of its stack", function()
		local non_top_prompts
		local non_top_answer

		before_each(function()
			helpers.mock(pr, "select_base_branch", function(_, callback)
				callback("feat/other")
			end)
			stack_answer = true
			lookup_result = {
				nil,
				{
					url = "https://github.com/o/r/pull/1",
					stack_number = 3,
					stack_size = 3,
					stack_position = 1,
					stack_top = { url = "https://github.com/o/r/pull/9", branch = "feat/top" },
				},
			}
			non_top_prompts = {}
			non_top_answer = "top"
			helpers.mock(pr, "confirm_non_top_stack", function(base, top_branch, stack_number, callback)
				table.insert(non_top_prompts, { base, top_branch, stack_number })
				callback(non_top_answer)
			end)
		end)

		it("stacks on the top branch, which replaces the base, when chosen", function()
			pr.create()
			assert.are.same({ { "feat/other", "feat/top", 3 } }, non_top_prompts)
			assert.are.equal("feat/top", captured_opts.base)
			assert.are.same(
				{ parent_url = "https://github.com/o/r/pull/9", new_stack = false, stack_number = 3 },
				captured_opts.stack
			)
		end)

		it("creates an ordinary PR on the picked base when chosen", function()
			non_top_answer = "ordinary"
			pr.create()
			assert.are.equal("feat/other", captured_opts.base)
			assert.is_nil(captured_opts.stack)
		end)

		it("aborts without opening the float when the picker is cancelled", function()
			non_top_answer = nil
			pr.create()
			assert.is_nil(captured_opts)
		end)

		it("aborts creation when the top PR is unknown", function()
			lookup_result[2].stack_top = nil
			pr.create()
			assert.are.same({}, non_top_prompts)
			assert.is_nil(captured_opts)
			assert.are.equal(1, #notifications)
			assert.is_not_nil(notifications[1].msg:find("Cannot determine the top PR of stack #3", 1, true))
		end)
	end)

	it("aborts creation and preserves the draft when the parent has no open PR", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = true
		lookup_result = { nil, nil }
		pr.save_draft({ "draft title" }, { "draft body" }, CREATE_DRAFT_KEY)
		pr.create()
		assert.is_nil(captured_opts)
		assert.are.same({ "draft title" }, pr.get_draft(CREATE_DRAFT_KEY).title_lines)
		assert.are.equal(1, #notifications)
		assert.is_not_nil(notifications[1].msg:find("feat/other has no open PR", 1, true))
	end)

	it("aborts with gh's error, not 'no open PR', when the parent lookup fails", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = true
		lookup_result = { "HTTP 401: Bad credentials\n", nil }
		pr.create()
		assert.is_nil(captured_opts)
		assert.are.equal(1, #notifications)
		assert.is_not_nil(notifications[1].msg:find("failed to look up the PR of feat/other: HTTP 401", 1, true))
		assert.is_nil(notifications[1].msg:find("has no open PR", 1, true))
	end)

	it("aborts when both stack position and size are missing instead of matching nils", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = true
		lookup_result[2].stack_position = nil
		lookup_result[2].stack_size = nil
		pr.create()
		assert.is_nil(captured_opts)
		assert.are.equal(1, #notifications)
	end)

	it("aborts when a new stack's parent base cannot be determined", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = true
		lookup_result = { nil, { url = "https://github.com/o/r/pull/1" } }
		pr.create()
		assert.is_nil(captured_opts)
		assert.are.equal(1, #notifications)
	end)

	it("aborts without opening the float when the stack prompt is cancelled", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		stack_answer = nil
		pr.create()
		assert.are.equal(1, #stack_prompts)
		assert.is_nil(captured_opts)
	end)

	it("offers the default branch first and passes it as the float base", function()
		pr.create()
		assert.are.equal("main", base_entries[1].value)
		assert.is_true(base_entries[1].is_default)
		assert.are.equal("feat/other", base_entries[2].value)
		assert.are.equal("main", captured_opts.base)
	end)

	it("derives the default title from the selected base branch", function()
		local subject_base
		helpers.mock(diff, "get_first_commit_subject", function(base)
			subject_base = base
			return "From " .. base
		end)
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback("feat/other")
		end)
		pr.create()
		assert.are.equal("feat/other", subject_base)
		assert.are.same({ "From feat/other" }, captured_title_lines)
		assert.are.equal("feat/other", captured_opts.base)
	end)

	it("aborts without opening the float when the base picker is cancelled", function()
		helpers.mock(pr, "select_base_branch", function(_, callback)
			callback(nil)
		end)
		pr.create()
		assert.is_nil(captured_opts)
		assert.is_nil(captured_body_lines)
	end)

	it("skips the base picker and lets gh choose when there are no candidates", function()
		helpers.mock(diff, "get_default_branch", function()
			return nil
		end)
		helpers.mock(diff, "get_remote_branches", function()
			return {}
		end)
		pr.create()
		assert.is_nil(base_callback)
		assert.is_nil(captured_opts.base)
		assert.is_nil(captured_title_lines)
		assert.are.same({ "" }, captured_body_lines)
	end)

	it("offers a locally resolved default branch when there are no remote branches", function()
		-- remote-less repo: get_default_branch falls back to a local main, which
		-- is still offered so the default title keeps its commit range
		local subject_base
		helpers.mock(diff, "get_first_commit_subject", function(base)
			subject_base = base
			return "Local subject"
		end)
		helpers.mock(diff, "get_remote_branches", function()
			return {}
		end)
		pr.create()
		assert.are.equal(1, #base_entries)
		assert.are.equal("main", base_entries[1].value)
		assert.are.equal("main", captured_opts.base)
		assert.are.equal("main", subject_base)
		assert.are.same({ "Local subject" }, captured_title_lines)
	end)

	it("still offers remote branches (without a default marker) when the default branch is unknown", function()
		helpers.mock(diff, "get_default_branch", function()
			return nil
		end)
		pr.create()
		assert.are.equal("feat/other", base_entries[1].value)
		assert.is_false(base_entries[1].is_default)
		assert.are.equal("feat/other", captured_opts.base)
		assert.are.same({ "Initial commit message" }, captured_title_lines)
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
		pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY)

		pr.create()

		assert.is_true(captured_opts.from_draft)
		assert.are.equal("main", captured_opts.base)
		captured_opts.on_discard_draft()
		assert.is_nil(pr.get_draft(CREATE_DRAFT_KEY))
	end)

	it("does not fetch default title when only draft exists", function()
		local get_first_commit_called = false
		helpers.mock(diff, "get_first_commit_subject", function(_)
			get_first_commit_called = true
			return "Should not be called"
		end)

		-- Save a draft
		pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY)

		-- Mock open_pr_float to track if draft is restored
		local draft_title_lines
		helpers.mock(pr, "open_pr_float", function(title_lines, _)
			draft_title_lines = title_lines
		end)

		pr.create()

		assert.is_false(get_first_commit_called)
		assert.are.same({ "Draft title" }, draft_title_lines)
	end)

	it("passes the branch draft key to the float", function()
		pr.create()
		assert.are.equal(CREATE_DRAFT_KEY, captured_opts.draft_key)
	end)

	it("restores a draft persisted to drafts.json, surviving a lost session", function()
		pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY)
		-- a Neovim restart drops the session-local fallback, not drafts.json
		pr.clear_draft()

		pr.create()

		assert.is_true(captured_opts.from_draft)
		assert.are.same({ "Draft title" }, captured_title_lines)
		assert.are.same({ "Draft body" }, captured_body_lines)
	end)

	it("does not offer another branch's draft", function()
		pr.save_draft({ "Other" }, { "other body" }, pr.build_create_draft_key("/repo/.git", "feat/other"))

		pr.create()

		assert.is_nil(captured_opts.from_draft)
		assert.are.same({ "Initial commit message" }, captured_title_lines)
	end)

	it("falls back to the session-local draft on a detached HEAD", function()
		helpers.mock(diff, "get_current_branch", function()
			return nil
		end)
		pr.save_draft({ "Session title" }, { "Session body" })

		pr.create()

		assert.is_nil(captured_opts.draft_key)
		assert.is_true(captured_opts.from_draft)
		assert.are.same({ "Session title" }, captured_title_lines)
	end)

	it("falls back to the session-local draft when drafts are disabled", function()
		local config = require("fude.config")
		local orig_drafts = config.opts.drafts
		config.opts.drafts = { enabled = false }
		pr.save_draft({ "Session title" }, { "Session body" }, CREATE_DRAFT_KEY)

		pr.create()

		config.opts.drafts = orig_drafts
		assert.are.equal(0, vim.fn.filereadable(draft_dir .. "/drafts.json"))
		assert.is_true(captured_opts.from_draft)
		assert.are.same({ "Session title" }, captured_title_lines)
	end)

	describe("with a stored draft", function()
		local base_picker_called
		local template_picker_called
		local stack = { parent_url = "https://github.com/o/r/pull/1", new_stack = false, stack_number = 3 }

		before_each(function()
			base_picker_called = false
			template_picker_called = false
			helpers.mock(pr, "select_base_branch", function(entries, callback)
				base_picker_called = true
				callback(entries[1].value)
			end)
			-- two templates, so the new-PR path stops at the template picker
			helpers.mock(pr, "find_templates", function()
				return { "/repo/.github/a.md", "/repo/.github/b.md" }
			end)
			helpers.mock(pr, "select_template", function(_, callback)
				template_picker_called = true
				callback(nil)
			end)
		end)

		it("does not ask about a draft when none is stored", function()
			pr.create()
			assert.are.equal(0, #resume_prompts)
			assert.is_true(base_picker_called)
		end)

		it("resumes the draft with its saved base and stack, skipping every picker", function()
			local get_first_commit_called = false
			helpers.mock(diff, "get_first_commit_subject", function(_)
				get_first_commit_called = true
			end)
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "feat/parent", stack = stack })
			-- the target is read back from drafts.json, not the session
			pr.clear_draft()

			pr.create()

			assert.are.equal(1, #resume_prompts)
			assert.are.equal("resume", resume_prompts[1].choices[1].value)
			assert.is_false(base_picker_called)
			assert.are.equal(0, #stack_prompts)
			assert.is_false(template_picker_called)
			assert.is_false(get_first_commit_called)
			assert.are.same({ "Draft title" }, captured_title_lines)
			assert.are.same({ "Draft body" }, captured_body_lines)
			assert.are.equal("feat/parent", captured_opts.base)
			assert.are.same(stack, captured_opts.stack)
			assert.are.equal(CREATE_DRAFT_KEY, captured_opts.draft_key)
			assert.is_true(captured_opts.from_draft)
			captured_opts.on_discard_draft()
			assert.is_nil(pr.get_draft(CREATE_DRAFT_KEY))
		end)

		it("resumes the session-local draft with its saved base on a detached HEAD", function()
			helpers.mock(diff, "get_current_branch", function()
				return nil
			end)
			pr.save_draft({ "Session title" }, { "Session body" }, nil, { base = "feat/parent" })

			pr.create()

			assert.is_false(base_picker_called)
			assert.are.equal("feat/parent", captured_opts.base)
			assert.is_nil(captured_opts.draft_key)
		end)

		it("resumes the draft through the base picker with another base", function()
			resume_answer = "rebase"
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "feat/parent", stack = stack })

			pr.create()

			assert.is_true(base_picker_called)
			assert.is_false(template_picker_called)
			assert.are.same({ "Draft title" }, captured_title_lines)
			-- the base picker's pick (the default branch) replaces the saved base and stack
			assert.are.equal("main", captured_opts.base)
			assert.is_nil(captured_opts.stack)
			assert.is_true(captured_opts.from_draft)
			assert.is_not_nil(pr.get_draft(CREATE_DRAFT_KEY))
		end)

		it("discards the draft and continues with the normal flow", function()
			resume_answer = "discard"
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "main" })

			pr.create()

			assert.is_nil(pr.get_draft(CREATE_DRAFT_KEY))
			assert.is_true(base_picker_called)
			assert.is_true(template_picker_called)
			assert.is_nil(captured_opts)
		end)

		it("aborts and keeps the draft when the prompt is cancelled", function()
			helpers.mock(pr, "confirm_draft_resume", function(_, callback)
				callback(nil)
			end)
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "main" })

			pr.create()

			assert.is_false(base_picker_called)
			assert.is_nil(captured_opts)
			assert.is_not_nil(pr.get_draft(CREATE_DRAFT_KEY))
		end)

		it("aborts when the draft was cleared while the prompt was open", function()
			helpers.mock(pr, "confirm_draft_resume", function(_, callback)
				-- an in-flight create succeeded and cleared the draft meanwhile
				pr.clear_draft(CREATE_DRAFT_KEY)
				callback("resume")
			end)
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "main" })

			pr.create()

			assert.is_nil(captured_opts)
			assert.is_false(base_picker_called)
			assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
		end)

		it("does not discard a draft re-saved while the prompt was open", function()
			helpers.mock(pr, "confirm_draft_resume", function(_, callback)
				-- same text, but a new save: a newer draft the prompt never showed
				pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "main" })
				callback("discard")
			end)
			pr.save_draft({ "Draft title" }, { "Draft body" }, CREATE_DRAFT_KEY, { base = "main" })

			pr.create()

			assert.is_not_nil(pr.get_draft(CREATE_DRAFT_KEY))
			assert.is_false(base_picker_called)
		end)
	end)
end)

describe("build_draft_resume_choices", function()
	local function draft(target, title)
		return { title_lines = { title or "Fix bug" }, body_lines = {}, target = target }
	end

	it("puts resume with the saved base first, then another base, then discard", function()
		assert.are.same({
			{ display = "Resume draft: Fix bug → main", value = "resume" },
			{ display = "Resume draft with another base: Fix bug", value = "rebase" },
			{ display = "Discard draft and start new", value = "discard" },
		}, pr.build_draft_resume_choices(draft({ base = "main" })))
	end)

	it("names the stack target like the float footer", function()
		local stacked = pr.build_draft_resume_choices(draft({ base = "feat/p", stack = { new_stack = false } }))
		assert.are.equal("Resume draft: Fix bug → feat/p (stacked)", stacked[1].display)
		local new_stack = pr.build_draft_resume_choices(draft({ base = "feat/p", stack = { new_stack = true } }))
		assert.are.equal("Resume draft: Fix bug → feat/p (new stack)", new_stack[1].display)
	end)

	it("omits the arrow for a target without a base and marks an empty title", function()
		local choices = pr.build_draft_resume_choices(draft({}, "  "))
		assert.are.equal("Resume draft: (no title)", choices[1].display)
		assert.are.equal("resume", choices[1].value)
	end)

	it("resumes only through the base picker when no target was saved", function()
		assert.are.same({
			{ display = "Resume draft: Fix bug", value = "rebase" },
			{ display = "Discard draft and start new", value = "discard" },
		}, pr.build_draft_resume_choices(draft(nil)))
	end)
end)

describe("parse_create_draft_target", function()
	it("accepts a base alone, an empty target, and well-formed stacks", function()
		assert.are.same({ base = "main" }, pr.parse_create_draft_target({ base = "main" }))
		assert.are.same({}, pr.parse_create_draft_target({}))
		local existing = { parent_url = "u", new_stack = false, stack_number = 3 }
		assert.are.same({ base = "b", stack = existing }, pr.parse_create_draft_target({ base = "b", stack = existing }))
		local new_stack = { parent_url = "u", new_stack = true, parent_base = "main" }
		assert.are.same({ base = "b", stack = new_stack }, pr.parse_create_draft_target({ base = "b", stack = new_stack }))
	end)

	it("drops the whole target when any field is malformed", function()
		assert.is_nil(pr.parse_create_draft_target(nil))
		assert.is_nil(pr.parse_create_draft_target("main"))
		assert.is_nil(pr.parse_create_draft_target({ base = 1 }))
		assert.is_nil(pr.parse_create_draft_target({ base = "" }))
		-- a stack needs a base
		assert.is_nil(pr.parse_create_draft_target({ stack = { parent_url = "u", new_stack = false, stack_number = 3 } }))
		assert.is_nil(pr.parse_create_draft_target({ base = "b", stack = vim.NIL }))
		assert.is_nil(pr.parse_create_draft_target({ base = "b", stack = { new_stack = false, stack_number = 3 } }))
		assert.is_nil(pr.parse_create_draft_target({ base = "b", stack = { parent_url = "u", stack_number = 3 } }))
		assert.is_nil(pr.parse_create_draft_target({ base = "b", stack = { parent_url = "u", new_stack = false } }))
		assert.is_nil(pr.parse_create_draft_target({ base = "b", stack = { parent_url = "u", new_stack = true } }))
	end)
end)

describe("save_draft target", function()
	local draft_dir

	before_each(function()
		pr.clear_draft()
		draft_dir = vim.fn.tempname()
		vim.fn.mkdir(draft_dir, "p")
		drafts._dir = draft_dir
	end)

	after_each(function()
		pr.clear_draft()
		drafts._dir = nil
		vim.fn.delete(draft_dir, "rf")
	end)

	it("round-trips the base and stack target through drafts.json", function()
		local stack = { parent_url = "u", new_stack = true, parent_base = "main" }
		pr.save_draft({ "t" }, { "b" }, CREATE_DRAFT_KEY, { base = "feat/x", stack = stack, draft_key = "ignored" })
		local d = pr.get_draft(CREATE_DRAFT_KEY)
		assert.are.same({ "t" }, d.title_lines)
		assert.are.same({ base = "feat/x", stack = stack }, d.target)
	end)

	it("keeps the target with the session-local fallback", function()
		pr.save_draft({ "t" }, { "b" }, nil, { base = "feat/x" })
		assert.are.same({ base = "feat/x" }, pr.get_draft().target)
	end)

	it("leaves the target nil when none is given", function()
		pr.save_draft({ "t" }, { "b" }, CREATE_DRAFT_KEY)
		assert.is_nil(pr.get_draft(CREATE_DRAFT_KEY).target)
	end)

	it("drops a malformed target read from drafts.json", function()
		drafts.set(CREATE_DRAFT_KEY, "t\nb", { base = "feat/x", stack = { parent_url = "u" } })
		assert.is_nil(pr.get_draft(CREATE_DRAFT_KEY).target)
	end)
end)

describe("build_create_draft_key", function()
	it("keys the draft by common git dir and branch", function()
		assert.are.equal("git:/repo/.git:#feat/x:pr_create", pr.build_create_draft_key("/repo/.git", "feat/x"))
	end)

	it("returns nil without a branch or common dir", function()
		assert.is_nil(pr.build_create_draft_key("/repo/.git", nil))
		assert.is_nil(pr.build_create_draft_key("/repo/.git", ""))
		assert.is_nil(pr.build_create_draft_key(nil, "feat/x"))
		assert.is_nil(pr.build_create_draft_key("", "feat/x"))
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
	it("returns template entries named by file", function()
		local entries = pr.build_picker_entries({ "/repo/.github/template.md" })
		assert.are.equal(1, #entries)
		assert.are.equal("template.md", entries[1].display)
		assert.are.equal("/repo/.github/template.md", entries[1].value)
	end)

	it("returns empty when no templates", function()
		local entries = pr.build_picker_entries({})
		assert.are.equal(0, #entries)
	end)

	it("preserves template order", function()
		local entries = pr.build_picker_entries({
			"/repo/.github/bug_report.md",
			"/repo/.github/feature_request.md",
		})
		assert.are.equal(2, #entries)
		assert.are.equal("bug_report.md", entries[1].display)
		assert.are.equal("feature_request.md", entries[2].display)
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

	it("saves the float's base and stack with a create draft", function()
		select_choice = "Save draft & close"
		local stack = { parent_url = "u", new_stack = true, parent_base = "main" }
		local h = open_float({ "t" }, { "b" }, { base = "feat/x", stack = stack })
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
		get_q_callback(h.body_buf)()
		assert.are.same({ base = "feat/x", stack = stack }, pr.get_draft().target)
	end)

	describe("on an unedited float restored from a draft", function()
		local discarded
		local function open_restored()
			discarded = false
			return open_float({ "t" }, { "b" }, {
				from_draft = true,
				on_discard_draft = function()
					discarded = true
				end,
			})
		end

		it("asks whether to keep the draft", function()
			select_choice = nil
			local h = open_restored()
			get_q_callback(h.title_buf)()
			assert.are.equal(1, #select_calls)
			assert.are.equal("Restored draft:", select_calls[1].prompt)
			assert.are.same(pr.RESTORED_DRAFT_CLOSE_CHOICES, select_calls[1].items)
		end)

		it("closes and keeps the draft when 'Keep draft & close' chosen", function()
			select_choice = "Keep draft & close"
			local h = open_restored()
			get_q_callback(h.title_buf)()
			assert.is_false(discarded)
			assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
			assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
		end)

		it("discards the draft and closes when 'Discard draft & close' chosen", function()
			select_choice = "Discard draft & close"
			local h = open_restored()
			get_q_callback(h.body_buf)()
			assert.is_true(discarded)
			assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
			assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
		end)

		it("keeps the float open when 'Keep editing' chosen", function()
			select_choice = nil
			local h = open_restored()
			get_q_callback(h.title_buf)()
			assert.is_false(discarded)
			assert.is_true(vim.api.nvim_win_is_valid(h.title_win))
			assert.is_true(vim.api.nvim_win_is_valid(h.body_win))
		end)

		it("closes without asking when drafts are disabled", function()
			local h = open_float({ "t" }, { "b" }, {
				mode = "edit",
				from_draft = true,
				allow_draft = false,
				on_discard_draft = function()
					discarded = true
				end,
			})
			get_q_callback(h.title_buf)()
			assert.are.equal(0, #select_calls)
			assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
		end)

		it("closes without asking when there is no draft to discard", function()
			local h = open_float({ "t" }, { "b" }, { mode = "edit", from_draft = true })
			get_q_callback(h.title_buf)()
			assert.are.equal(0, #select_calls)
			assert.is_false(vim.api.nvim_win_is_valid(h.title_win))
		end)
	end)

	it("closes without saving when 'Discard & close' chosen", function()
		select_choice = "Discard & close"
		local h = open_float({ "t" }, { "b" }, {})
		vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
		get_q_callback(h.body_buf)()
		assert.is_nil(pr.get_draft())
		assert.is_false(vim.api.nvim_win_is_valid(h.body_win))
	end)

	describe("with a drafts.json key", function()
		local draft_dir
		local key = pr.build_create_draft_key("/repo/.git", "feat/me")
		local notified

		before_each(function()
			draft_dir = vim.fn.tempname()
			vim.fn.mkdir(draft_dir, "p")
			drafts._dir = draft_dir
			notified = {}
			helpers.mock(vim, "notify", function(msg)
				table.insert(notified, msg)
			end)
		end)

		after_each(function()
			drafts._dir = nil
			vim.fn.delete(draft_dir, "rf")
		end)

		it("saves the create draft to drafts.json", function()
			select_choice = "Save draft & close"
			local h = open_float({ "t" }, { "b" }, { draft_key = key })
			vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "edited body" })
			get_q_callback(h.body_buf)()
			assert.are.equal("t\nedited body", drafts.get(key))
			assert.is_nil(pr.get_draft())
			assert.are.same({ "fude.nvim: Draft saved" }, notified)
		end)

		it("reports a cleared draft when saving empty input", function()
			drafts.set(key, "old\nbody")
			select_choice = "Save draft & close"
			local h = open_float({ "old" }, { "body" }, { draft_key = key })
			vim.api.nvim_buf_set_lines(h.title_buf, 0, -1, false, { "" })
			vim.api.nvim_buf_set_lines(h.body_buf, 0, -1, false, { "" })
			get_q_callback(h.body_buf)()
			assert.is_nil(drafts.get(key))
			assert.are.same({ "fude.nvim: Empty input — draft cleared" }, notified)
		end)
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

describe("create submit draft cleanup", function()
	local orig_paste

	local function get_cr_callback(buf)
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if map.lhs == "<CR>" then
				return map.callback
			end
		end
		error("<CR> mapping not found for buffer " .. buf)
	end

	local draft_dir
	local key = pr.build_create_draft_key("/repo/.git", "feat/me")
	local push_calls

	before_each(function()
		pr.clear_draft()
		orig_paste = vim.paste
		draft_dir = vim.fn.tempname()
		vim.fn.mkdir(draft_dir, "p")
		drafts._dir = draft_dir
		-- never run the real git push from the test repository
		push_calls = {}
		helpers.mock(diff, "get_push_target", function()
			return { branch = "feat/a", remote = "origin" }
		end)
		helpers.mock(diff, "push_branch", function(remote, branch, callback)
			table.insert(push_calls, { remote = remote, branch = branch })
			callback(nil)
		end)
	end)

	after_each(function()
		vim.cmd("stopinsert")
		helpers.cleanup()
		vim.paste = orig_paste
		pr.clear_draft()
		drafts._dir = nil
		vim.fn.delete(draft_dir, "rf")
	end)

	it("persists the input to drafts.json and keeps it when creation fails", function()
		local finish_create
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			finish_create = callback
		end)
		helpers.mock(vim, "notify", function() end)

		pr.open_pr_float({ "t" }, { "b" }, { draft_key = key })
		get_cr_callback(vim.api.nvim_get_current_buf())()
		finish_create("must push the branch first", nil)

		assert.are.equal("t\nb", drafts.get(key))
		-- the session-local fallback is untouched
		assert.is_nil(pr.get_draft())
	end)

	it("clears the drafts.json entry after success when nothing was saved in flight", function()
		local finish_create
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			finish_create = callback
		end)

		pr.open_pr_float({ "t" }, { "b" }, { draft_key = key })
		get_cr_callback(vim.api.nvim_get_current_buf())()
		assert.is_not_nil(drafts.get(key))

		finish_create(nil, { url = "https://github.com/o/r/pull/1" })
		assert.is_nil(drafts.get(key))
	end)

	it("keeps a drafts.json entry re-saved with the same content while in flight", function()
		local finish_create
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			finish_create = callback
		end)

		pr.open_pr_float({ "t" }, { "b" }, { draft_key = key })
		get_cr_callback(vim.api.nvim_get_current_buf())()
		pr.save_draft({ "t" }, { "b" }, key)

		finish_create(nil, { url = "https://github.com/o/r/pull/1" })
		assert.are.equal("t\nb", drafts.get(key))
	end)

	describe("pushing an unpushed branch", function()
		local UNPUSHED = "aborted: you must first push the current branch to a remote, or use the --head flag"
		local events
		local notifications

		--- gh fails with `errors` in order, then succeeds
		local function mock_create(errors)
			local calls = 0
			helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
				calls = calls + 1
				table.insert(events, "create")
				if errors[calls] then
					callback(errors[calls])
				else
					callback(nil, { url = "https://github.com/o/r/pull/1" })
				end
			end)
		end

		before_each(function()
			events = {}
			notifications = {}
			helpers.mock(require("fude.config").opts, "pr", { push_before_create = true })
			helpers.mock(diff, "push_branch", function(remote, branch, callback)
				table.insert(events, "push " .. remote .. " " .. branch)
				callback(nil)
			end)
			mock_create({})
			helpers.mock(vim, "notify", function(msg, level)
				table.insert(notifications, { msg = msg, level = level })
			end)
		end)

		local function submit(opts)
			pr.open_pr_float({ "t" }, { "b" }, opts or {})
			get_cr_callback(vim.api.nvim_get_current_buf())()
		end

		local function float_text()
			local buf = vim.api.nvim_get_current_buf()
			local win = vim.api.nvim_get_current_win()
			return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
				vim.api.nvim_win_get_config(win).title[1][1]
		end

		local function press_c()
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
				if map.lhs == "c" then
					map.callback()
				end
			end
		end

		local function find_notification(pattern)
			for _, n in ipairs(notifications) do
				if n.msg:find(pattern, 1, true) then
					return n
				end
			end
			return nil
		end

		it("pushes and retries once when gh reports the branch unpushed", function()
			mock_create({ UNPUSHED })
			submit()
			assert.are.same({ "create", "push origin feat/a", "create" }, events)
			assert.is_nil(pr.get_draft())
			assert.is_not_nil(find_notification("Draft PR created"))
		end)

		it("pushes to the target get_push_target chose", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "get_push_target", function()
				return { branch = "feat/a", remote = "fork" }
			end)
			submit()
			assert.are.same({ "create", "push fork feat/a", "create" }, events)
		end)

		it("neither pushes nor reads the push target when gh succeeds", function()
			helpers.mock(diff, "get_push_target", function()
				error("the push target must only be read after gh reports an unpushed branch")
			end)
			submit()
			assert.are.same({ "create" }, events)
		end)

		it("does not push on other gh errors", function()
			mock_create({ "HTTP 502" })
			submit()
			assert.are.same({ "create" }, events)
			assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
		end)

		it("retries only once", function()
			mock_create({ UNPUSHED, UNPUSHED })
			submit()
			assert.are.same({ "create", "push origin feat/a", "create" }, events)
			local last = notifications[#notifications]
			assert.are.equal(vim.log.levels.ERROR, last.level)
			assert.is_not_nil(last.msg:find("must first push", 1, true))
		end)

		it("leaves a detached HEAD to gh's message", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "get_push_target", function()
				return nil
			end)
			submit()
			assert.are.same({ "create" }, events)
			assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
		end)

		it("shows the push error in a float, creates no PR and keeps the draft", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "push_branch", function(_, _, callback)
				table.insert(events, "push")
				callback("! [rejected] feat/a -> feat/a (non-fast-forward)")
			end)
			submit()
			assert.are.same({ "create", "push" }, events)
			assert.are.same({ "t" }, pr.get_draft().title_lines)
			local text, title = float_text()
			assert.are.equal(" Push failed ", title)
			assert.is_not_nil(text:find('Failed to push "feat/a" to origin', 1, true))
			assert.is_not_nil(text:find("non-fast-forward", 1, true))
			-- the error line is drawn in the error highlight
			local marks =
				vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().fude_error_float, 0, -1, { details = true })
			local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
			assert.are.equal(1, #marks)
			assert.are.equal(pr.ERROR_HL, marks[1][4].hl_group)
			assert.are.equal("! [rejected] feat/a -> feat/a (non-fast-forward)", lines[marks[1][2] + 1])
			assert.are.equal(#lines[marks[1][2] + 1], marks[1][4].end_col)
		end)

		it("copies the whole float with c", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "push_branch", function(_, _, callback)
				callback("! [rejected]")
			end)
			submit()
			local expected = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
			vim.fn.setreg('"', "")
			press_c()
			assert.are.equal(expected, vim.fn.getreg('"'))
			assert.is_not_nil(expected:find('Failed to push "feat/a"', 1, true))
			assert.is_not_nil(expected:find("! [rejected]", 1, true))
		end)

		it("says only the unnamed register got the text without a clipboard", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "push_branch", function(_, _, callback)
				callback("! [rejected]")
			end)
			submit()
			local has = vim.fn.has
			helpers.mock(vim.fn, "has", function(feature)
				if feature == "clipboard" then
					return 0
				end
				return has(feature)
			end)
			press_c()
			local last = notifications[#notifications]
			assert.are.equal(vim.log.levels.WARN, last.level)
			assert.is_not_nil(last.msg:find("unnamed register (clipboard unavailable)", 1, true))
			assert.is_not_nil(vim.fn.getreg('"'):find("! [rejected]", 1, true))
		end)

		it("reports the copy when the clipboard accepts it", function()
			mock_create({ UNPUSHED })
			helpers.mock(diff, "push_branch", function(_, _, callback)
				callback("! [rejected]")
			end)
			submit()
			local has, setreg = vim.fn.has, vim.fn.setreg
			local clipboard
			helpers.mock(vim.fn, "has", function(feature)
				if feature == "clipboard" then
					return 1
				end
				return has(feature)
			end)
			helpers.mock(vim.fn, "setreg", function(reg, text, ...)
				if reg == "+" then
					clipboard = text
					return 0
				end
				return setreg(reg, text, ...)
			end)
			press_c()
			assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
			assert.is_not_nil(clipboard:find("! [rejected]", 1, true))
		end)

		describe("with pr.push_before_create = false", function()
			before_each(function()
				helpers.mock(require("fude.config").opts, "pr", { push_before_create = false })
			end)

			it("is the default", function()
				local config = require("fude.config")
				helpers.mock(config.opts, "pr", vim.deepcopy(config.defaults.pr))
				mock_create({ UNPUSHED })
				submit()
				assert.are.same({ "create" }, events)
				local _, title = float_text()
				assert.are.equal(" Branch not pushed ", title)
			end)

			it("explains the unpushed branch and the option in a float without pushing", function()
				mock_create({ UNPUSHED })
				submit()
				assert.are.same({ "create" }, events)
				assert.are.same({ "t" }, pr.get_draft().title_lines)
				local text, title = float_text()
				assert.are.equal(" Branch not pushed ", title)
				assert.is_not_nil(text:find('"feat/a" is not pushed', 1, true))
				assert.is_not_nil(text:find("you must first push the current branch", 1, true))
				assert.is_not_nil(text:find("pr.push_before_create = true", 1, true))
			end)

			it("keeps the plain notification for other gh errors", function()
				-- an unrelated failure is not blamed on the push, and the
				-- gh-upgrade hint for --attach still shows
				local win = vim.api.nvim_get_current_win()
				mock_create({ "unknown flag: --attach" })
				submit()
				assert.are.equal(win, vim.api.nvim_get_current_win())
				local last = notifications[#notifications]
				assert.are.equal(vim.log.levels.ERROR, last.level)
				assert.is_not_nil(last.msg:find("require gh >= 2.99.0", 1, true))
			end)
		end)
	end)

	it("keeps a session draft saved while the create request is in flight", function()
		local finish_create
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			finish_create = callback
		end)

		pr.open_pr_float({ "t" }, { "b" }, {})
		local title_buf = vim.api.nvim_get_current_buf()
		get_cr_callback(title_buf)() -- submit: closes the float, starts the request

		-- the user reopens :FudePR and saves a newer draft mid-flight
		pr.save_draft({ "newer" }, { "newer body" })

		finish_create(nil, { url = "https://github.com/o/r/pull/1" })

		local d = pr.get_draft()
		assert.is_not_nil(d)
		assert.are.same({ "newer" }, d.title_lines)
	end)

	it("clears the draft after success when nothing was saved in flight", function()
		local finish_create
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			finish_create = callback
		end)

		pr.open_pr_float({ "t" }, { "b" }, {})
		local title_buf = vim.api.nvim_get_current_buf()
		get_cr_callback(title_buf)()

		finish_create(nil, { url = "https://github.com/o/r/pull/1" })
		assert.is_nil(pr.get_draft())
	end)

	it("keeps the base with the draft when creation fails", function()
		helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
			callback("boom")
		end)
		helpers.mock(vim, "notify", function() end)

		pr.open_pr_float({ "t" }, { "b" }, { base = "develop" })
		get_cr_callback(vim.api.nvim_get_current_buf())()

		local d = pr.get_draft()
		assert.are.same({ "t" }, d.title_lines)
		assert.are.same({ base = "develop" }, d.target)
	end)

	it("passes opts.base to gh.create_draft_pr on submit", function()
		local captured_base = "unset"
		helpers.mock(gh, "create_draft_pr", function(_, _, _, base, callback)
			captured_base = base
			callback(nil, { url = "https://github.com/o/r/pull/1" })
		end)

		pr.open_pr_float({ "t" }, { "b" }, { base = "develop" })
		get_cr_callback(vim.api.nvim_get_current_buf())()
		assert.are.equal("develop", captured_base)
	end)

	it("passes nil base to gh.create_draft_pr when opts.base is absent", function()
		local captured_base = "unset"
		helpers.mock(gh, "create_draft_pr", function(_, _, _, base, callback)
			captured_base = base
			callback(nil, { url = "https://github.com/o/r/pull/1" })
		end)

		pr.open_pr_float({ "t" }, { "b" }, {})
		get_cr_callback(vim.api.nvim_get_current_buf())()
		assert.is_nil(captured_base)
	end)

	describe("stacking on the gh-stack parent", function()
		local NEW_URL = "https://github.com/o/r/pull/2"
		local PARENT_URL = "https://github.com/o/r/pull/1"
		local notifications
		local link_calls

		before_each(function()
			notifications = {}
			link_calls = {}
			helpers.mock(gh, "check_stack_available", function(callback)
				callback(nil)
			end)
			helpers.mock(gh, "get_open_pr_stack", function(_, callback)
				callback(nil, { url = PARENT_URL, stack_number = 7, stack_position = 2, stack_size = 2 })
			end)
			helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
				callback(nil, { url = NEW_URL })
			end)
			helpers.mock(gh, "link_stack", function(refs, base, callback)
				table.insert(link_calls, { refs = refs, base = base })
				callback(nil)
			end)
			helpers.mock(vim, "notify", function(msg, level)
				table.insert(notifications, { msg = msg, level = level })
			end)
		end)

		local function submit(opts)
			pr.open_pr_float({ "t" }, { "b" }, opts)
			get_cr_callback(vim.api.nvim_get_current_buf())()
		end

		local function find_notification(pattern)
			for _, n in ipairs(notifications) do
				if n.msg:find(pattern, 1, true) then
					return n
				end
			end
			return nil
		end

		it("appends the new PR to the parent's existing stack by stack number", function()
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, new_stack = false, stack_number = 7 } })
			-- the update mode without a stack number would need every PR already in the stack
			assert.are.same({ { refs = { "7", NEW_URL } } }, link_calls)
			assert.is_not_nil(find_notification("Stacked on " .. PARENT_URL))
		end)

		it("creates a new stack keeping the parent's base branch", function()
			helpers.mock(gh, "get_open_pr_stack", function(_, callback)
				callback(nil, { url = PARENT_URL, base_ref = "feat/grand" })
			end)
			submit({
				base = "feat/parent",
				stack = { parent_url = PARENT_URL, new_stack = true, parent_base = "feat/grand" },
			})
			assert.are.same({ { refs = { PARENT_URL, NEW_URL }, base = "feat/grand" } }, link_calls)
			assert.is_not_nil(find_notification("New stack created on " .. PARENT_URL))
		end)

		it("does not link when stack is not set", function()
			helpers.mock(gh, "check_stack_available", function()
				error("ordinary PRs must not require gh-stack")
			end)
			submit({ base = "feat/parent" })
			assert.are.same({}, link_calls)
		end)

		it("shows a persistent failure float without closing the created PR", function()
			local opened_url
			helpers.mock(vim.ui, "open", function(url)
				opened_url = url
			end)
			local close_calls = 0
			helpers.mock(gh, "set_pr_state", function()
				close_calls = close_calls + 1
			end)
			helpers.mock(gh, "link_stack", function(_, _, callback)
				callback('unknown command "stack" for "gh"\n')
			end)
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, new_stack = false, stack_number = 7 } })
			local win = vim.api.nvim_get_current_win()
			local buf = vim.api.nvim_get_current_buf()
			local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			assert.is_not_nil(lines:find(NEW_URL, 1, true))
			assert.is_not_nil(lines:find('unknown command "stack" for "gh"', 1, true))
			assert.is_not_nil(lines:find("NOT been closed or deleted", 1, true))
			assert.are.equal(" q close | c copy | o open PR ", vim.api.nvim_win_get_config(win).footer[1][1])
			assert.is_false(vim.bo[buf].modifiable)
			assert.are.equal(0, close_calls)
			assert.is_nil(pr.get_draft())
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
				if map.lhs == "o" then
					map.callback()
				end
			end
			assert.are.equal(NEW_URL, opened_url)
			assert.is_true(vim.api.nvim_win_is_valid(win))
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
				if map.lhs == "q" then
					map.callback()
				end
			end
			assert.is_false(vim.api.nvim_win_is_valid(win))
			assert.is_false(vim.api.nvim_buf_is_valid(buf))
			assert.is_not_nil(find_notification("Draft PR created: " .. NEW_URL))
		end)

		it("does not create or link when the capability check fails and keeps input as a draft", function()
			local creates = 0
			helpers.mock(gh, "create_draft_pr", function()
				creates = creates + 1
			end)
			helpers.mock(gh, "check_stack_available", function(callback)
				callback("HTTP 404: stacks unavailable")
			end)
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, stack_number = 7 } })
			assert.are.equal(0, creates)
			-- a failed preflight leaves the remote untouched too
			assert.are.same({}, push_calls)
			assert.are.same({}, link_calls)
			assert.are.same({ "t" }, pr.get_draft().title_lines)
			local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
			assert.is_not_nil(lines:find("before creating a PR", 1, true))
			assert.is_not_nil(lines:find("HTTP 404", 1, true))
		end)

		it("waits for both preflight callbacks before creating, and preserves a newer draft", function()
			local finish_check, finish_lookup, finish_link
			helpers.mock(gh, "check_stack_available", function(callback)
				finish_check = callback
			end)
			helpers.mock(gh, "get_open_pr_stack", function(_, callback)
				finish_lookup = callback
			end)
			helpers.mock(gh, "link_stack", function(_, _, callback)
				finish_link = callback
			end)
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, stack_number = 7 } })
			assert.is_nil(find_notification("Draft PR created"))
			assert.is_nil(finish_lookup)
			finish_check(nil)
			assert.is_nil(find_notification("Draft PR created"))
			pr.save_draft({ "new draft" }, { "new body" })
			finish_lookup(nil, { url = PARENT_URL, stack_number = 7, stack_position = 2, stack_size = 2 })
			assert.is_not_nil(find_notification("Draft PR created"))
			finish_link("connection lost")
			assert.are.same({ "new draft" }, pr.get_draft().title_lines)
		end)

		it("aborts when the unstacked parent acquired a stack while composing", function()
			local creates = 0
			helpers.mock(gh, "create_draft_pr", function()
				creates = creates + 1
			end)
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, new_stack = true, parent_base = "main" } })
			assert.are.equal(0, creates)
			assert.are.same({}, link_calls)
		end)

		for _, case in ipairs({
			{ name = "lookup failure", err = "HTTP 401" },
			{ name = "missing parent" },
			{ name = "changed parent", info = { url = "another" } },
			{ name = "changed stack", info = { url = PARENT_URL, stack_number = 8, stack_position = 2, stack_size = 2 } },
			{ name = "new top PR", info = { url = PARENT_URL, stack_number = 7, stack_position = 2, stack_size = 3 } },
			{ name = "missing position", info = { url = PARENT_URL, stack_number = 7 } },
		}) do
			it("aborts the submit preflight on " .. case.name, function()
				local creates = 0
				helpers.mock(gh, "create_draft_pr", function()
					creates = creates + 1
				end)
				helpers.mock(gh, "get_open_pr_stack", function(_, callback)
					callback(case.err, case.info)
				end)
				submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, stack_number = 7 } })
				assert.are.equal(0, creates)
				assert.are.same({}, link_calls)
				assert.is_not_nil(pr.get_draft())
			end)
		end

		it("does not link when PR creation fails", function()
			helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
				callback("boom", nil)
			end)
			submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, new_stack = false, stack_number = 7 } })
			assert.are.same({}, link_calls)
		end)

		for _, result in ipairs({ false, {}, { url = "" }, { url = " \n " }, { url = vim.NIL } }) do
			it("reports missing PR URLs as a post-create failure: " .. vim.inspect(result), function()
				helpers.mock(gh, "create_draft_pr", function(_, _, _, _, callback)
					callback(nil, result or nil)
				end)
				submit({ base = "feat/parent", stack = { parent_url = PARENT_URL, stack_number = 7 } })
				assert.are.same({}, link_calls)
				assert.is_nil(find_notification("Draft PR created"))
				local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
				assert.is_not_nil(lines:find("PR URL was not returned", 1, true))
				assert.is_not_nil(lines:find("NOT been closed or deleted", 1, true))
				assert.is_nil(lines:find("before creating a PR", 1, true))
				assert.is_nil(pr.get_draft())
				assert.are.equal(" q close | c copy ", vim.api.nvim_win_get_config(0).footer[1][1])
				for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
					assert.is_not.equal("o", map.lhs)
				end
			end)
		end
	end)
end)

describe("stack failure float layout", function()
	local config = require("fude.config")
	local original_float

	before_each(function()
		original_float = config.opts.float
	end)

	after_each(function()
		config.opts.float = original_float
		helpers.cleanup()
	end)

	it("uses configured dimensions, keeps a footer with border=none and normalizes errors", function()
		config.opts.float = { width = 75, height = 60, border = "none" }
		pr.show_stack_error("first\r\nsecond\rthird")
		local cfg = vim.api.nvim_win_get_config(0)
		assert.are.equal(math.floor(vim.o.columns * 0.75), cfg.width)
		assert.are.equal(math.floor(vim.o.lines * 0.60), cfg.height)
		assert.are.equal(" q close | c copy ", cfg.footer[1][1])
		assert.is_not_nil(cfg.border)
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
			assert.is_not.equal("o", map.lhs)
		end
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		assert.are.same({ "first", "second", "third" }, { unpack(lines, #lines - 2) })
	end)

	it("clamps tiny and oversized configured dimensions to a valid float", function()
		for _, percent in ipairs({ 0, 1000 }) do
			config.opts.float = { width = percent, height = percent }
			pr.show_stack_error("failure")
			local cfg = vim.api.nvim_win_get_config(0)
			assert.is_true(cfg.width >= 1 and cfg.width <= vim.o.columns - 2)
			assert.is_true(cfg.height >= 1 and cfg.height <= vim.o.lines - 4)
			vim.api.nvim_win_close(0, true)
		end
	end)
end)

describe("is_unpushed_branch_error", function()
	it("matches gh's unpushed-branch error", function()
		assert.is_true(
			pr.is_unpushed_branch_error("aborted: you must first push the current branch to a remote, or use the --head flag")
		)
	end)

	it("does not match other errors", function()
		assert.is_false(pr.is_unpushed_branch_error("HTTP 401: Bad credentials"))
		assert.is_false(pr.is_unpushed_branch_error("unknown flag: --attach"))
		assert.is_false(pr.is_unpushed_branch_error(nil))
	end)
end)

describe("build_error_footer", function()
	it("offers copy, and open PR only with a URL", function()
		assert.are.equal(" q close | c copy | o open PR ", pr.build_error_footer(true))
		assert.are.equal(" q close | c copy ", pr.build_error_footer(false))
	end)
end)

describe("build_push_error_lines", function()
	it("reports a failed push with its error", function()
		local lines, highlights, title = pr.build_push_error_lines("! [rejected]\nerror: failed", "feat/a", "origin", true)
		assert.are.equal(" Push failed ", title)
		assert.are.same({
			'Failed to push "feat/a" to origin, so no PR was created. The PR input has been kept as a draft.',
			"",
			"Original Error:",
			"! [rejected]",
			"error: failed",
		}, lines)
		-- only the error itself is red; there is no suggestion
		assert.are.same({ [4] = pr.ERROR_HL, [5] = pr.ERROR_HL }, highlights)
	end)

	it("points to the option when pushing is off", function()
		local lines, highlights, title = pr.build_push_error_lines("aborted", "feat/a", nil, false)
		assert.are.equal(" Branch not pushed ", title)
		assert.are.same({
			'"feat/a" is not pushed to the remote, so `gh pr create` failed. The PR input has been kept as a draft.',
			"Push the branch and run :FudeCreatePR again, or set `pr.push_before_create = true`"
				.. " to push it automatically before creating a PR.",
			"",
			"Original Error:",
			"aborted",
		}, lines)
		assert.are.same({ [2] = pr.SUGGESTION_HL, [5] = pr.ERROR_HL }, highlights)
	end)
end)

describe("build_footer_text", function()
	it("shows the base branch in create mode", function()
		assert.are.equal(" <CR> create draft → main | q cancel ", pr.build_footer_text("create", false, "main"))
	end)

	it("omits the base when nil or empty", function()
		assert.are.equal(" <CR> create draft | q cancel ", pr.build_footer_text("create", false, nil))
		assert.are.equal(" <CR> create draft | q cancel ", pr.build_footer_text("create", false, ""))
	end)

	it("appends the draft-restored hint", function()
		assert.are.equal(
			" <CR> create draft → develop | q cancel (draft restored) ",
			pr.build_footer_text("create", true, "develop")
		)
	end)

	it("ignores the base in edit mode", function()
		assert.are.equal(" <CR> update | q cancel ", pr.build_footer_text("edit", false, "main"))
		assert.are.equal(" <CR> update | q cancel (draft restored) ", pr.build_footer_text("edit", true, nil))
		assert.are.equal(" <CR> update | q cancel ", pr.build_footer_text("edit", false, "p", { new_stack = false }))
	end)

	it("marks a stacked PR in create mode", function()
		assert.are.equal(
			" <CR> create draft → feat/parent (stacked) | q cancel ",
			pr.build_footer_text("create", false, "feat/parent", { new_stack = false })
		)
	end)

	it("marks a PR that starts a new stack in create mode", function()
		assert.are.equal(
			" <CR> create draft → feat/parent (new stack) | q cancel ",
			pr.build_footer_text("create", false, "feat/parent", { new_stack = true })
		)
	end)
end)

describe("calculate_compact_picker_height", function()
	it("fits the entries plus the prompt and borders", function()
		assert.are.equal(6, pr.calculate_compact_picker_height(2))
	end)

	it("caps the rows for long lists and keeps one row when empty", function()
		assert.are.equal(19, pr.calculate_compact_picker_height(100))
		assert.are.equal(5, pr.calculate_compact_picker_height(0))
		assert.are.equal(5, pr.calculate_compact_picker_height(nil))
	end)
end)

describe("build_stack_choices", function()
	it("puts Yes first so a bare <CR> stacks the PR", function()
		assert.are.same(
			{ "yes", "no" },
			vim.tbl_map(function(e)
				return e.value
			end, pr.build_stack_choices())
		)
	end)
end)

describe("build_non_top_choices", function()
	it("offers an ordinary PR on the base first, then a stacked PR on the top branch", function()
		assert.are.same({
			{ display = "Ordinary PR on feat/mid (no stack)", value = "ordinary" },
			{ display = "Stacked PR on feat/top (top of stack #3)", value = "top" },
		}, pr.build_non_top_choices("feat/mid", "feat/top", 3))
	end)
end)

describe("confirm_non_top_stack (picker fallback)", function()
	local orig_select

	before_each(function()
		orig_select = vim.ui.select
	end)

	after_each(function()
		vim.ui.select = orig_select
	end)

	it("explains the top-only rule and returns the chosen value", function()
		local prompt
		vim.ui.select = function(items, sopts, on_choice)
			prompt = sopts.prompt
			on_choice(items[2], 2)
		end
		local answer
		pr.confirm_non_top_stack("feat/mid", "feat/top", 3, function(v)
			answer = v
		end)
		assert.are.equal("Stacked PRs can only be added to the top of stack #3.", prompt)
		assert.are.equal("top", answer)
	end)
end)

-- Telescope is not loaded in the test environment, so this covers the
-- vim.ui.select fallback of the shared picker
describe("confirm_stack (picker fallback)", function()
	local orig_select

	before_each(function()
		orig_select = vim.ui.select
	end)

	after_each(function()
		vim.ui.select = orig_select
	end)

	local function answer_with(idx)
		local captured = {}
		vim.ui.select = function(items, sopts, on_choice)
			captured.prompt = sopts.prompt
			captured.labels = items
			on_choice(idx and items[idx], idx)
		end
		local answer = "unset"
		pr.confirm_stack("feat/parent", function(v)
			answer = v
		end)
		return answer, captured
	end

	it("offers Yes first with the base branch in the prompt", function()
		local answer, captured = answer_with(1)
		assert.are.equal("Stack the PR on feat/parent?", captured.prompt)
		assert.are.same({ "Yes (stacked PR)", "No (ordinary PR)" }, captured.labels)
		assert.is_true(answer)
	end)

	it("returns false for No", function()
		assert.is_false((answer_with(2)))
	end)

	it("returns nil on cancel", function()
		assert.is_nil((answer_with(nil)))
	end)
end)

describe("confirm_draft_resume (picker fallback)", function()
	local orig_select

	before_each(function()
		orig_select = vim.ui.select
	end)

	after_each(function()
		vim.ui.select = orig_select
	end)

	local function answer_with(idx)
		local captured = {}
		vim.ui.select = function(items, sopts, on_choice)
			captured.prompt = sopts.prompt
			captured.labels = items
			on_choice(idx and items[idx], idx)
		end
		local answer = "unset"
		pr.confirm_draft_resume({ title_lines = { "Fix bug" }, body_lines = {}, target = { base = "main" } }, function(v)
			answer = v
		end)
		return answer, captured
	end

	it("offers resume first", function()
		local answer, captured = answer_with(1)
		assert.are.equal("A PR draft exists:", captured.prompt)
		assert.are.same({
			"Resume draft: Fix bug → main",
			"Resume draft with another base: Fix bug",
			"Discard draft and start new",
		}, captured.labels)
		assert.are.equal("resume", answer)
	end)

	it("returns rebase and discard for the later entries", function()
		assert.are.equal("rebase", (answer_with(2)))
		assert.are.equal("discard", (answer_with(3)))
	end)

	it("returns nil on cancel", function()
		assert.is_nil((answer_with(nil)))
	end)
end)

describe("build_base_branch_entries", function()
	it("puts the default branch first with a marker and keeps the rest in order", function()
		local entries = pr.build_base_branch_entries({ "feat/a", "main", "release" }, "main")
		assert.are.same({
			{ display = "main (default)", value = "main", is_default = true },
			{ display = "feat/a", value = "feat/a", is_default = false },
			{ display = "release", value = "release", is_default = false },
		}, entries)
	end)

	it("does not list a default branch that is missing from the remote branches", function()
		local entries = pr.build_base_branch_entries({ "feat/a" }, "main")
		assert.are.same({ { display = "feat/a", value = "feat/a", is_default = false } }, entries)
	end)

	it("lists a locally resolved default branch when there are no remote branches", function()
		local entries = pr.build_base_branch_entries({}, "main")
		assert.are.same({ { display = "main (default)", value = "main", is_default = true } }, entries)
	end)

	it("returns the branches unchanged when there is no default branch", function()
		local entries = pr.build_base_branch_entries({ "feat/a", "main" }, nil)
		assert.are.same({ "feat/a", "main" }, { entries[1].value, entries[2].value })
		assert.is_false(entries[1].is_default)
		assert.are.equal("feat/a", entries[1].display)
	end)

	it("returns an empty list when there are no candidates", function()
		assert.are.same({}, pr.build_base_branch_entries({}, nil))
		assert.are.same({}, pr.build_base_branch_entries(nil, ""))
	end)

	it("places related branches right after the default branch with relation markers", function()
		local entries = pr.build_base_branch_entries({ "x", "anc2", "parent", "anc1", "main" }, "main", {
			stack_parent = "parent",
			ancestors = { "anc1", "anc2" },
		})
		assert.are.same(
			{ "main (default)", "parent (stack parent)", "anc1 (ancestor)", "anc2 (ancestor)", "x" },
			vim.tbl_map(function(e)
				return e.display
			end, entries)
		)
		assert.are.equal("stack parent", entries[2].relation)
		assert.are.equal("ancestor", entries[3].relation)
		assert.is_nil(entries[5].relation)
	end)

	it("labels a branch that is both stack parent and ancestor once, as stack parent", function()
		local entries = pr.build_base_branch_entries({ "p", "main" }, "main", {
			stack_parent = "p",
			ancestors = { "p" },
		})
		assert.are.equal(2, #entries)
		assert.are.equal("p (stack parent)", entries[2].display)
	end)

	it("skips related branches that are not on the remote", function()
		local entries = pr.build_base_branch_entries({ "main", "x" }, "main", {
			stack_parent = "unpushed",
			ancestors = { "also-local" },
		})
		assert.are.same({ "main", "x" }, { entries[1].value, entries[2].value })
		assert.are.equal(2, #entries)
	end)

	it("does not list the current branch", function()
		local entries = pr.build_base_branch_entries({ "me", "main", "x" }, "main", {
			current_branch = "me",
			stack_parent = "me",
			ancestors = { "me" },
		})
		assert.are.same({ "main", "x" }, { entries[1].value, entries[2].value })
		assert.are.equal(2, #entries)
	end)

	it("does not treat the default branch as a related branch when it is the stack trunk", function()
		local entries = pr.build_base_branch_entries({ "main", "x" }, "main", { stack_parent = "main" })
		assert.are.same({ "main (default)", "x" }, { entries[1].display, entries[2].display })
	end)
end)

describe("select_base_branch (vim.ui.select fallback)", function()
	local orig_select

	before_each(function()
		orig_select = vim.ui.select
	end)

	after_each(function()
		vim.ui.select = orig_select
		helpers.cleanup()
	end)

	it("lists entry displays and maps the chosen index back to the branch name", function()
		local captured_items, captured_prompt
		vim.ui.select = function(items, sopts, on_choice)
			captured_items = items
			captured_prompt = sopts.prompt
			on_choice(items[2], 2)
		end
		local selected = "unset"
		pr.select_base_branch({
			{ display = "main (default)", value = "main", is_default = true },
			{ display = "develop", value = "develop", is_default = false },
		}, function(value)
			selected = value
		end)
		assert.are.same({ "main (default)", "develop" }, captured_items)
		assert.are.equal("Select base branch:", captured_prompt)
		assert.are.equal("develop", selected)
	end)

	it("passes nil to the callback on cancel", function()
		vim.ui.select = function(_, _, on_choice)
			on_choice(nil, nil)
		end
		local selected = "unset"
		pr.select_base_branch({ { display = "main (default)", value = "main", is_default = true } }, function(value)
			selected = value
		end)
		assert.is_nil(selected)
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
		assert.are.equal(50, captured_opts.pr_number)
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

describe("PR body completion adapters", function()
	local completion = require("fude.completion")
	local original_paste

	before_each(function()
		original_paste = vim.paste
	end)

	after_each(function()
		vim.cmd("stopinsert")
		helpers.cleanup()
		vim.paste = original_paste
	end)

	for _, mode in ipairs({ "create", "edit" }) do
		for _, adapter in ipairs({ "blink", "cmp" }) do
			it("connects all three triggers in " .. mode .. " mode to " .. adapter, function()
				pr.open_pr_float({ "title" }, { "body" }, { mode = mode, pr_number = mode == "edit" and 253 or nil })
				local title_buf = vim.api.nvim_get_current_buf()
				local title_win = vim.api.nvim_get_current_win()
				local body_buf, body_win
				for _, win in ipairs(vim.api.nvim_list_wins()) do
					local buf = vim.api.nvim_win_get_buf(win)
					if vim.bo[buf].filetype == "markdown" then
						body_buf, body_win = buf, win
					end
				end
				assert.is_not_nil(body_buf)
				local source = require("fude.completion." .. adapter).new()
				local available = adapter == "blink" and source.enabled or source.is_available
				assert.is_false(available(source))
				assert.is_false(completion.is_enabled(title_buf))
				vim.api.nvim_set_current_win(body_win)
				assert.is_true(available(source))
				assert.is_nil(vim.b[body_buf].fude_comment)
				for _, spec in ipairs({ { "@", "fetch_mentions" }, { "#", "fetch_issues" }, { "_", "fetch_commits" } }) do
					local called = false
					helpers.mock(completion, spec[2], function(cb, buf)
						assert.are.equal(body_buf, buf)
						called = true
						cb({ { label = "candidate" } })
					end)
					local response
					local function receive(value)
						response = value
					end
					-- The request buffer, not later focus, determines the target.
					vim.api.nvim_set_current_win(title_win)
					if adapter == "blink" then
						source:get_completions({ line = spec[1], cursor = { 1, 1 }, bufnr = body_buf }, receive)
						assert.are.equal("candidate", response.items[1].label)
					else
						source:complete({ context = { cursor_before_line = spec[1], bufnr = body_buf } }, receive)
						assert.are.equal("candidate", response[1].label)
					end
					assert.is_true(called)
					vim.api.nvim_set_current_win(body_win)
				end
				assert.are.same({}, require("fude.ui").comment_input_buffers())
				require("fude.ui").close_comment_ui()
				assert.is_true(vim.api.nvim_win_is_valid(body_win))
				assert.is_true(vim.api.nvim_buf_is_valid(body_buf))
			end)
		end
	end
end)

describe("edit draft persistence", function()
	local config = require("fude.config")
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

	it("keeps a draft saved while the update request is in flight", function()
		drafts.set(key, "before title\nbefore body")
		local finish_edit
		helpers.mock(gh, "edit_pr", function(_, _, _, _, callback)
			finish_edit = callback
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		local closed = false
		captured_opts.on_submit("T", "B", function()
			closed = true
		end)
		-- the float stays open until the request finishes; the user saves a
		-- newer draft in the meantime
		captured_opts.on_save_draft({ "newer title" }, { "newer body" })
		finish_edit(nil)
		helpers.wait_for(function()
			return closed
		end)

		assert.are.equal("newer title\nnewer body", drafts.get(key))
	end)

	it("keeps an in-flight draft even when its content matches the pre-submit one", function()
		drafts.set(key, "same title\nsame body")
		local finish_edit
		helpers.mock(gh, "edit_pr", function(_, _, _, _, callback)
			finish_edit = callback
		end)

		pr.edit()
		helpers.wait_for(function()
			return captured_opts ~= nil
		end)

		local closed = false
		captured_opts.on_submit("T", "B", function()
			closed = true
		end)
		-- re-saving identical content mid-flight is still an explicit save; a
		-- stored-content comparison would wrongly delete it on success
		captured_opts.on_save_draft({ "same title" }, { "same body" })
		finish_edit(nil)
		helpers.wait_for(function()
			return closed
		end)

		assert.are.equal("same title\nsame body", drafts.get(key))
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

describe("build_state_actions", function()
	local function values(entries)
		local out = {}
		for _, e in ipairs(entries) do
			table.insert(out, e.value)
		end
		return out
	end

	it("offers ready and close for an open draft", function()
		assert.are.same({ "ready", "close" }, values(pr.build_state_actions("OPEN", true)))
	end)

	it("offers draft and close for an open ready PR", function()
		assert.are.same({ "draft", "close" }, values(pr.build_state_actions("OPEN", false)))
	end)

	it("offers only reopen for a closed PR", function()
		assert.are.same({ "reopen" }, values(pr.build_state_actions("CLOSED", false)))
	end)

	it("offers nothing for a merged PR or an unknown state", function()
		assert.are.same({}, pr.build_state_actions("MERGED", false))
		assert.are.same({}, pr.build_state_actions("", false))
	end)

	it("gives every entry a label and a completion phrase", function()
		for _, e in ipairs(pr.build_state_actions("OPEN", true)) do
			assert.is_true(type(e.display) == "string" and e.display ~= "")
			assert.is_true(type(e.done) == "string" and e.done ~= "")
		end
	end)
end)

describe("format_pr_state", function()
	it("lower-cases the state and marks an open draft", function()
		assert.are.equal("open (draft)", pr.format_pr_state("OPEN", true))
		assert.are.equal("open", pr.format_pr_state("OPEN", false))
		assert.are.equal("merged", pr.format_pr_state("MERGED", false))
	end)

	it("does not mark a closed draft as draft", function()
		assert.are.equal("closed", pr.format_pr_state("CLOSED", true))
	end)

	it("reports an empty state as unknown", function()
		assert.are.equal("unknown", pr.format_pr_state("", false))
	end)
end)

describe("change_state", function()
	local config = require("fude.config")
	local orig_select, orig_notify
	local notifications, select_calls, set_calls

	before_each(function()
		config.setup({})
		notifications, select_calls, set_calls = {}, {}, {}
		orig_select = vim.ui.select
		orig_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
		helpers.mock(gh, "set_pr_state", function(action, num, callback)
			table.insert(set_calls, { action = action, num = num })
			callback(nil)
		end)
	end)

	after_each(function()
		vim.ui.select = orig_select
		vim.notify = orig_notify
		helpers.cleanup()
	end)

	local function mock_state(err, data, seen)
		helpers.mock(gh, "get_pr_state", function(num, callback)
			if seen then
				seen.num = num
			end
			callback(err, data)
		end)
	end

	local function pick(index)
		vim.ui.select = function(items, sopts, on_choice)
			table.insert(select_calls, { items = items, prompt = sopts.prompt })
			on_choice(items[index], index)
		end
	end

	it("lists only the transitions available from the current state and applies the pick", function()
		mock_state(nil, { number = 3, state = "OPEN", is_draft = true })
		pick(1)

		pr.change_state()

		assert.are.same({ "Ready for review", "Close" }, select_calls[1].items)
		assert.are.equal("PR #3 is open (draft). Change to:", select_calls[1].prompt)
		assert.are.same({ { action = "ready", num = 3 } }, set_calls)
		assert.are.equal("fude.nvim: PR #3 marked ready for review", notifications[#notifications].msg)
	end)

	it("uses the review session's PR number while a review is active", function()
		config.state.active = true
		config.state.pr_number = 42
		local seen = {}
		mock_state(nil, { number = 42, state = "CLOSED", is_draft = false }, seen)
		pick(1)

		pr.change_state()

		assert.are.equal(42, seen.num)
		assert.are.same({ { action = "reopen", num = 42 } }, set_calls)
	end)

	it("detects the current branch's PR outside a review", function()
		local seen = { num = "unset" }
		mock_state(nil, { number = 5, state = "OPEN", is_draft = false }, seen)
		pick(1)

		pr.change_state()

		assert.is_nil(seen.num)
		assert.are.same({ { action = "draft", num = 5 } }, set_calls)
	end)

	it("does nothing when the picker is cancelled", function()
		mock_state(nil, { number = 3, state = "OPEN", is_draft = false })
		vim.ui.select = function(_, _, on_choice)
			on_choice(nil, nil)
		end

		pr.change_state()

		assert.are.equal(0, #set_calls)
	end)

	it("shows no picker for a merged PR", function()
		mock_state(nil, { number = 3, state = "MERGED", is_draft = false })
		pick(1)

		pr.change_state()

		assert.are.equal(0, #select_calls)
		assert.are.equal(0, #set_calls)
		assert.truthy(notifications[1].msg:find("PR #3 is merged", 1, true))
	end)

	it("reports a branch without a PR as a WARN without showing the picker", function()
		mock_state('no pull requests found for branch "feat/x"\n', nil)
		pick(1)

		pr.change_state()

		assert.are.equal(0, #select_calls)
		assert.are.equal('fude.nvim: no pull requests found for branch "feat/x"', notifications[1].msg)
		assert.are.equal(vim.log.levels.WARN, notifications[1].level)
	end)

	it("reports a detached HEAD whose commit has no PR as a WARN", function()
		mock_state("No PR found for commit abc1234", nil)
		pick(1)

		pr.change_state()

		assert.are.equal("fude.nvim: No PR found for commit abc1234", notifications[1].msg)
		assert.are.equal(vim.log.levels.WARN, notifications[1].level)
	end)

	it("refuses in the local commit scope without looking the PR up", function()
		helpers.mock(require("fude.local.session"), "in_commit_scope", function()
			return true
		end)
		local looked_up = false
		helpers.mock(gh, "get_pr_state", function()
			looked_up = true
		end)

		pr.change_state()

		assert.is_false(looked_up)
		assert.truthy(notifications[1].msg:find("commit scope", 1, true))
		assert.are.equal(vim.log.levels.WARN, notifications[1].level)
	end)

	it("reports any other lookup failure as an ERROR without showing the picker", function()
		mock_state("HTTP 401: Bad credentials\n", nil)
		pick(1)

		pr.change_state()

		assert.are.equal(0, #select_calls)
		assert.are.equal("fude.nvim: HTTP 401: Bad credentials", notifications[1].msg)
		assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
	end)

	it("reports a state change failure", function()
		mock_state(nil, { number = 3, state = "OPEN", is_draft = false })
		helpers.mock(gh, "set_pr_state", function(_, _, callback)
			callback("unknown flag: --undo")
		end)
		pick(1)

		pr.change_state()

		local last = notifications[#notifications]
		assert.are.equal("fude.nvim: Failed to change PR state: unknown flag: --undo", last.msg)
		assert.are.equal(vim.log.levels.ERROR, last.level)
	end)
end)
