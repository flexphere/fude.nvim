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

--- Mark of a reaction the viewer gave, in the picker.
M.MINE_MARK = "●"
M.OTHER_MARK = "○"

local function count_of(rollup, content)
	local n = type(rollup) == "table" and rollup[content] or nil
	if type(n) == "number" and n > 0 and n == math.floor(n) then
		return n
	end
	return 0
end

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

--- The picker rows: every reaction in M.CONTENTS order with its count and
--- whether the viewer gave it (`● 👍 +1  2`). Pure.
--- @param rollup table|nil
--- @param mine table<string, number> from find_user_reactions
--- @return table[] { content, emoji, count, mine, label }
function M.build_reaction_choices(rollup, mine)
	local choices = {}
	for _, c in ipairs(M.CONTENTS) do
		local n = count_of(rollup, c.content)
		local is_mine = mine[c.content] ~= nil
		local label = string.format("%s %s %s", is_mine and M.MINE_MARK or M.OTHER_MARK, c.emoji, c.content)
		if n > 0 then
			label = label .. "  " .. n
		end
		table.insert(choices, { content = c.content, emoji = c.emoji, count = n, mine = is_mine, label = label })
	end
	return choices
end

--- The repository endpoint prefix for the PR of `ctx` (its URL's
--- `owner/repo`, else gh's cwd-based template).
--- @param ctx table
--- @return string
local function repo_api_path(ctx)
	local repo = ctx and ctx.pr_url and require("fude.drafts").repo_slug(ctx.pr_url) or nil
	return require("fude.gh").build_repo_api_path(repo)
end

--- Open the reaction picker for `comment`: lists the reactions with the
--- viewer's own marked, and toggles the picked one (adds it, or removes the
--- viewer's). On success the comment's `reactions` is replaced with the
--- rollup of a fresh listing and `on_done(comment)` runs, so the caller can
--- redraw it.
--- @param comment table|nil
--- @param ctx table ui.capture_open_context(), taken when the comment was shown
--- @param on_done fun(comment: table)|nil
function M.pick(comment, ctx, on_done)
	local path, reason = M.find_reaction_target(comment, ctx, repo_api_path(ctx))
	if not path then
		vim.notify("fude.nvim: " .. reason, vim.log.levels.INFO)
		return
	end
	local gh = require("fude.gh")
	local login = config.state.github_user
	gh.get_reactions(path, function(err, list)
		if err then
			vim.notify("fude.nvim: Failed to load reactions: " .. err, vim.log.levels.ERROR)
			return
		end
		local mine = M.find_user_reactions(list, login)
		local choices = M.build_reaction_choices(M.build_rollup(list), mine)
		vim.ui.select(choices, {
			prompt = "Reaction (toggle):",
			kind = "fude_reaction",
			format_item = function(choice)
				return choice.label
			end,
		}, function(choice)
			if not choice then
				return
			end
			local function refresh(action_err)
				if action_err then
					vim.notify("fude.nvim: Failed to update reaction: " .. action_err, vim.log.levels.ERROR)
					return
				end
				gh.get_reactions(path, function(list_err, new_list)
					if list_err then
						vim.notify("fude.nvim: Failed to reload reactions: " .. list_err, vim.log.levels.ERROR)
						return
					end
					comment.reactions = M.build_rollup(new_list)
					vim.notify(
						string.format("fude.nvim: Reaction %s %s", choice.emoji, choice.mine and "removed" or "added"),
						vim.log.levels.INFO
					)
					if on_done then
						on_done(comment)
					end
				end)
			end
			if choice.mine then
				gh.remove_reaction(path, mine[choice.content], refresh)
			else
				gh.add_reaction(path, choice.content, function(add_err)
					refresh(add_err)
				end)
			end
		end)
	end)
end

return M
