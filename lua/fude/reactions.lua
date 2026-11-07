--- Comment reactions (👍, ❤️, …): the summary line shown under a comment and
--- the `+` picker that adds or removes the viewer's own reactions through the
--- REST reactions endpoints of review comments (`pulls/comments/<id>`) and
--- PR-level comments (`issues/comments/<id>`). Local review comments, the
--- viewer's pending review comments and submitted review bodies have no such
--- endpoint and are refused.
local M = {}
local config = require("fude.config")

local format = require("fude.ui.format")

--- The reactions GitHub offers, in the order its web UI lists them
--- (format.REACTIONS).
M.CONTENTS = format.REACTIONS
M.format_reactions = format.format_reactions

--- The REST path of a comment's reactions, or why it has none. A review
--- comment (it has a `path`) uses `pulls/comments/<id>/reactions`, any other
--- comment `issues/comments/<id>/reactions`. Pure.
--- @param comment any
--- @param ctx table { pending_review_id, is_local } (ui.capture_open_context)
--- @param repo_api_path string `repos/<owner>/<repo>` (gh.build_repo_api_path)
--- @return string|nil path
--- @return string|nil reason when nil
function M.find_reaction_target(comment, ctx, repo_api_path)
	ctx = ctx or {}
	if type(comment) ~= "table" then
		return nil, "No comment under cursor"
	end
	if ctx.is_local then
		return nil, "Local review comments have no reactions"
	end
	if ctx.pending_review_id ~= nil and comment.pull_request_review_id == ctx.pending_review_id then
		return nil, "Pending comments cannot be reacted to until the review is submitted"
	end
	if comment.is_review_summary then
		return nil, "Review summaries cannot be reacted to from fude"
	end
	if type(comment.id) ~= "number" then
		return nil, "This comment has no GitHub ID"
	end
	local kind = type(comment.path) == "string" and "pulls" or "issues"
	return string.format("%s/%s/comments/%d/reactions", repo_api_path, kind, comment.id)
end

--- The REST path of the PR's own reactions (its body: `issues/<n>/reactions`),
--- or why it has none. Pure.
--- @param pr_info any
--- @param ctx table|nil { is_local } (ui.capture_open_context)
--- @param repo_api_path string `repos/<owner>/<repo>` (gh.build_repo_api_path)
--- @return string|nil path
--- @return string|nil reason when nil
function M.find_pr_reaction_target(pr_info, ctx, repo_api_path)
	if ctx and ctx.is_local then
		return nil, "Local review has no PR to react to"
	end
	if type(pr_info) ~= "table" or type(pr_info.number) ~= "number" then
		return nil, "No PR to react to"
	end
	return string.format("%s/issues/%d/reactions", repo_api_path, pr_info.number)
end

--- The rollup of a reactions listing (`GET …/reactions`): a count per
--- content plus `total_count`, the shape of a comment's `reactions`. Pure.
--- @param list any
--- @return table
function M.build_rollup(list)
	local rollup = { total_count = 0 }
	for _, c in ipairs(M.CONTENTS) do
		rollup[c.content] = 0
	end
	for _, reaction in ipairs(type(list) == "table" and list or {}) do
		if type(reaction) == "table" and rollup[reaction.content] ~= nil and reaction.content ~= "total_count" then
			rollup[reaction.content] = rollup[reaction.content] + 1
			rollup.total_count = rollup.total_count + 1
		end
	end
	return rollup
end

--- The viewer's own reactions in a listing: content → reaction id. Pure.
--- @param list any
--- @param login string|nil the viewer's login
--- @return table<string, number>
function M.find_user_reactions(list, login)
	local mine = {}
	if type(login) ~= "string" then
		return mine
	end
	for _, reaction in ipairs(type(list) == "table" and list or {}) do
		if
			type(reaction) == "table"
			and type(reaction.user) == "table"
			and reaction.user.login == login
			and type(reaction.content) == "string"
			and type(reaction.id) == "number"
		then
			mine[reaction.content] = reaction.id
		end
	end
	return mine
end

--- The detail of a reaction row in the picker: its count and what `<Tab>`
--- does on it (`2 · <Tab>: remove`, `<Tab>: add`), so the key is visible on
--- every row. Pure.
--- @param count number|nil
--- @param on boolean whether the viewer gave this reaction
--- @return string
function M.format_reaction_detail(count, on)
	local hint = "<Tab>: " .. (on and "remove" or "add")
	if type(count) == "number" and count > 0 then
		return string.format("%d · %s", count, hint)
	end
	return hint
end

--- The picker rows (ui/toggle_picker items): every reaction in M.CONTENTS
--- order, `on` when the viewer gave it, its detail re-read from `counts` (a
--- content → count table the caller keeps current) on every render. Pure.
--- @param counts table<string, number> the rollup's counts
--- @param mine table<string, number> from find_user_reactions
--- @return table[] items { text, on, value = content, detail }
function M.build_reaction_items(counts, mine)
	local items = {}
	for _, c in ipairs(M.CONTENTS) do
		table.insert(items, {
			text = c.emoji .. " " .. c.content,
			on = mine[c.content] ~= nil,
			value = c.content,
			detail = function(item)
				return M.format_reaction_detail(counts[c.content], item.on)
			end,
		})
	end
	return items
end

--- The repository endpoint prefix for the PR of `ctx` (its URL's
--- `owner/repo`, else gh's cwd-based template).
--- @param ctx table
--- @return string
local function repo_api_path(ctx)
	local repo = ctx and ctx.pr_url and require("fude.drafts").repo_slug(ctx.pr_url) or nil
	return require("fude.gh").build_repo_api_path(repo)
end

--- Open the reaction picker (ui/toggle_picker) over the reactions at `path`:
--- every reaction with the viewer's own marked and the counts; `<Tab>` adds
--- the one under the cursor, or removes it when it is the viewer's, the row
--- showing a spinner while GitHub is being updated, and the picker stays
--- open. After each change the reactions are listed again: `target.reactions`
--- (a comment, or the PR) is replaced with their rollup in place and
--- `on_done(target)` runs, so the caller can redraw it.
--- @param path string
--- @param target table
--- @param on_done fun(target: table)|nil
local function open_picker(path, target, on_done)
	local gh = require("fude.gh")
	local login = config.state.github_user
	gh.get_reactions(path, function(err, list)
		if err then
			vim.notify("fude.nvim: Failed to load reactions: " .. err, vim.log.levels.ERROR)
			return
		end
		local mine = M.find_user_reactions(list, login)
		local counts = M.build_rollup(list)
		local items = M.build_reaction_items(counts, mine)

		-- After a change: list again so ids, counts and the comment follow
		-- GitHub (another user may have reacted meanwhile)
		local function reload(item, done)
			gh.get_reactions(path, function(list_err, new_list)
				if list_err then
					vim.notify("fude.nvim: Failed to reload reactions: " .. list_err, vim.log.levels.ERROR)
					-- The change itself went through
					done(true)
					return
				end
				local rollup = M.build_rollup(new_list)
				for k, v in pairs(rollup) do
					counts[k] = v
				end
				local new_mine = M.find_user_reactions(new_list, login)
				for k in pairs(mine) do
					mine[k] = nil
				end
				for k, v in pairs(new_mine) do
					mine[k] = v
				end
				target.reactions = rollup
				vim.notify(
					string.format("fude.nvim: Reaction %s %s", item.text, item.on and "removed" or "added"),
					vim.log.levels.INFO
				)
				done(true)
				if on_done then
					on_done(target)
				end
			end)
		end

		require("fude.ui.toggle_picker").open({
			title = "Reactions",
			items = items,
			on_toggle = function(item, done)
				local content = item.value
				local function after(action_err)
					if action_err then
						vim.notify("fude.nvim: Failed to update reaction: " .. action_err, vim.log.levels.ERROR)
						done(false)
						return
					end
					reload(item, done)
				end
				if item.on and mine[content] then
					gh.remove_reaction(path, mine[content], after)
				else
					gh.add_reaction(path, content, function(add_err)
						after(add_err)
					end)
				end
			end,
		})
	end)
end

--- Open the reaction picker for `comment` (see open_picker).
--- @param comment table|nil
--- @param ctx table ui.capture_open_context(), taken when the comment was shown
--- @param on_done fun(comment: table)|nil
function M.pick(comment, ctx, on_done)
	local path, reason = M.find_reaction_target(comment, ctx, repo_api_path(ctx))
	if not path then
		vim.notify("fude.nvim: " .. reason, vim.log.levels.INFO)
		return
	end
	open_picker(path, comment, on_done)
end

--- The same picker for the PR itself (its body): `pr_info.reactions` is
--- replaced with the fresh rollup, which ui/format.find_pr_reactions prefers
--- over the `reactionGroups` the overview was fetched with.
--- @param pr_info table|nil the overview's PR data (number, url, reactionGroups)
--- @param ctx table ui.capture_open_context()
--- @param on_done fun(pr_info: table)|nil
function M.pick_pr(pr_info, ctx, on_done)
	local url = type(pr_info) == "table" and pr_info.url or (ctx and ctx.pr_url)
	local path, reason = M.find_pr_reaction_target(pr_info, ctx, repo_api_path({ pr_url = url }))
	if not path then
		vim.notify("fude.nvim: " .. reason, vim.log.levels.INFO)
		return
	end
	open_picker(path, pr_info, on_done)
end

return M
