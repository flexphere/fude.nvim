--- Local on-disk draft storage for in-progress review comments.
---
--- This is distinct from the in-session "pending review" comments
--- (`config.state.pending_comments`, keyed via `comments/data.lua`'s
--- `parse_draft_key`). Pending comments are submitted to GitHub as a pending
--- review; local drafts are *unsubmitted* text persisted under
--- `stdpath("state")/fude/drafts.json` so editing can be paused (e.g. jump back
--- to the diff) and resumed later, including across PR switches and Neovim
--- restarts.
---
--- Keys are opaque strings produced by `make_draft_key` and include the repo
--- and PR number so drafts for different PRs / repos never collide.
local M = {}
local config = require("fude.config")

-- Directory override for tests (nil = use stdpath("state")/fude).
M._dir = nil

-- === Pure functions ===

--- Build an opaque draft storage key.
--- @param repo string "owner/repo"
--- @param pr_number number|string PR number
--- @param kind string "line"|"suggest"|"issue"|"reply"|"edit"
--- @param ... string|number additional discriminators (path, line range, ids)
--- @return string
function M.make_draft_key(repo, pr_number, kind, ...)
	local parts = { tostring(repo or "?"), "#" .. tostring(pr_number or "?"), tostring(kind) }
	for _, v in ipairs({ ... }) do
		table.insert(parts, tostring(v))
	end
	return table.concat(parts, ":")
end

--- Extract the "owner/repo" slug from a GitHub PR URL. Pure.
--- @param pr_url string|nil
--- @return string|nil
function M.repo_slug(pr_url)
	if not pr_url then
		return nil
	end
	return pr_url:match("github%.com/([^/]+/[^/]+)")
end

--- Serialize a drafts table to a JSON string.
--- @param drafts table
--- @return string
function M.serialize(drafts)
	return vim.json.encode(drafts or {})
end

--- Deserialize a JSON string into a drafts table. Returns {} on empty or
--- malformed input so a corrupt file never breaks comment input.
--- @param json_str string|nil
--- @return table
function M.deserialize(json_str)
	if not json_str or json_str == "" then
		return {}
	end
	local ok, result = pcall(vim.json.decode, json_str)
	if not ok or type(result) ~= "table" then
		return {}
	end
	return result
end

--- Remove drafts whose `saved_at` is older than `retention_days`. Pure; `now`
--- is passed in (unix time) for testability. `saved_at` is a UTC ISO-8601
--- string (same format as GitHub comment timestamps), which sorts
--- chronologically lexicographically, so the comparison is a string compare
--- against an ISO cutoff. Entries without a string timestamp are kept.
--- @param drafts table<string, {body: string, saved_at: string}>
--- @param now number current unix time (os.time())
--- @param retention_days number|nil days to keep (<=0 or nil disables pruning)
--- @return table pruned drafts
function M.prune(drafts, now, retention_days)
	if not drafts then
		return {}
	end
	if not retention_days or retention_days <= 0 then
		return drafts
	end
	local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", now - retention_days * 86400)
	local result = {}
	for key, entry in pairs(drafts) do
		local saved_at = type(entry) == "table" and entry.saved_at or nil
		if type(saved_at) ~= "string" or saved_at >= cutoff then
			result[key] = entry
		end
	end
	return result
end

--- Build a draft key for the active review session, deriving repo / PR number
--- from `config.state`. Returns nil when there is no active PR.
--- @param kind string "line"|"suggest"|"issue"|"reply"|"edit"
--- @param ... string|number additional discriminators
--- @return string|nil
function M.current_key(kind, ...)
	local st = config.state
	if not st.pr_number then
		return nil
	end
	return M.make_draft_key(M.repo_slug(st.pr_url) or "?", st.pr_number, kind, ...)
end

--- Collect draft markers for the active PR in a single load, used to render
--- `draft` indicators in the diff. Returns line numbers for `line`/`suggest`
--- drafts anchored to `rel_path`, and the comment IDs that have a `reply`/`edit`
--- draft (the caller maps those IDs to lines via the comment map).
--- @param rel_path string|nil repo-relative path of the current buffer
--- @return { lines: table<number, boolean>, comment_ids: table<any, boolean> }
function M.file_markers(rel_path)
	local out = { lines = {}, comment_ids = {} }
	if not M.enabled() then
		return out
	end
	local st = config.state
	if not st.pr_number then
		return out
	end
	local repo = M.repo_slug(st.pr_url) or "?"
	local line_pfx = rel_path and (M.make_draft_key(repo, st.pr_number, "line", rel_path) .. ":")
	local sug_pfx = rel_path and (M.make_draft_key(repo, st.pr_number, "suggest", rel_path) .. ":")
	local reply_pfx = M.make_draft_key(repo, st.pr_number, "reply") .. ":"
	local edit_pfx = M.make_draft_key(repo, st.pr_number, "edit") .. ":"

	local function starts_with(s, prefix)
		return prefix and s:sub(1, #prefix) == prefix
	end

	for key in pairs(M.load()) do
		if starts_with(key, line_pfx) or starts_with(key, sug_pfx) then
			local pfx = starts_with(key, line_pfx) and line_pfx or sug_pfx
			local s = key:sub(#pfx + 1):match("^(%d+)")
			if s then
				out.lines[tonumber(s)] = true
			end
		elseif starts_with(key, reply_pfx) or starts_with(key, edit_pfx) then
			local pfx = starts_with(key, reply_pfx) and reply_pfx or edit_pfx
			local id = key:sub(#pfx + 1)
			out.comment_ids[tonumber(id) or id] = true
		end
	end
	return out
end

-- === Config helpers ===

--- Whether local drafts are enabled (default true).
--- @return boolean
function M.enabled()
	local cfg = config.opts.drafts
	return not cfg or cfg.enabled ~= false
end

--- @return number retention period in days (default 30)
local function retention_days()
	local cfg = config.opts.drafts
	return (cfg and cfg.retention_days) or 30
end

-- === IO layer ===

local function draft_path()
	local dir = M._dir or (vim.fn.stdpath("state") .. "/fude")
	return dir .. "/drafts.json"
end

--- Load all drafts from disk (pruned by retention). Returns {} when disabled,
--- missing, or unreadable.
--- @return table<string, {body: string, saved_at: string}>
function M.load()
	if not M.enabled() then
		return {}
	end
	local path = draft_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	local drafts = M.deserialize(table.concat(lines, "\n"))
	return M.prune(drafts, os.time(), retention_days())
end

--- Persist the full drafts table to disk, creating the parent directory.
--- No-op when disabled.
--- @param drafts table
function M.save(drafts)
	if not M.enabled() then
		return
	end
	local path = draft_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	pcall(vim.fn.writefile, vim.split(M.serialize(drafts or {}), "\n"), path)
end

--- Get a single draft body by key.
--- @param key string|nil
--- @return string|nil body or nil when none / disabled
function M.get(key)
	if not M.enabled() or not key then
		return nil
	end
	local entry = M.load()[key]
	if type(entry) == "table" then
		return entry.body
	end
	return nil
end

--- Save a draft body for `key`. An empty / whitespace-only body removes it.
--- @param key string|nil
--- @param body string|nil
function M.set(key, body)
	if not M.enabled() or not key then
		return
	end
	local drafts = M.load()
	if not body or vim.trim(body) == "" then
		drafts[key] = nil
	else
		-- UTC ISO-8601, matching GitHub comment timestamps (see M.prune).
		drafts[key] = { body = body, saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
	end
	M.save(drafts)
end

--- Remove a draft by key (no-op when absent / disabled).
--- @param key string|nil
function M.remove(key)
	if not M.enabled() or not key then
		return
	end
	local drafts = M.load()
	if drafts[key] == nil then
		return
	end
	drafts[key] = nil
	M.save(drafts)
end

return M
