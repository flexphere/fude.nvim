--- Shared test helpers for fude.nvim integration tests.
--- Provides mock management, test buffer creation, and async wait utilities.
local M = {}

-- Track mocked functions for restore
local mocked = {}

--- Replace a module function with a fake, saving the original for later restore.
--- @param mod table the module table
--- @param name string function name on the module
--- @param fake_fn function replacement function
function M.mock(mod, name, fake_fn)
	table.insert(mocked, { mod = mod, name = name, original = mod[name] })
	mod[name] = fake_fn
end

--- Restore all mocked functions to their originals.
function M.restore_all()
	for i = #mocked, 1, -1 do
		local entry = mocked[i]
		entry.mod[entry.name] = entry.original
	end
	mocked = {}
end

--- Mock gh.run and gh.run_json with a response table.
--- Responses are keyed by "args[1]:args[2]" pattern (e.g. "pr:view", "api:repos").
--- Each value is either:
---   - a table: returned as success via callback(nil, data)
---   - a string: returned as error via callback(err, nil)
---   - a function(args, callback, stdin): called directly for custom logic
--- Callbacks are invoked via vim.schedule() to simulate real async flow.
--- @param responses table<string, table|string|function> pattern -> response
function M.mock_gh(responses)
	local gh = require("fude.gh")
	responses = responses or {}

	M.mock(gh, "run_json", function(args, callback, stdin)
		local key = (args[1] or "") .. ":" .. (args[2] or "")
		local resp = responses[key]
		if type(resp) == "function" then
			resp(args, callback, stdin)
			return
		end
		vim.schedule(function()
			if type(resp) == "string" then
				callback(resp, nil)
			elseif resp ~= nil then
				callback(nil, resp)
			else
				callback(nil, {})
			end
		end)
	end)

	M.mock(gh, "run", function(args, callback, stdin)
		local key = (args[1] or "") .. ":" .. (args[2] or "")
		local resp = responses[key]
		if type(resp) == "function" then
			resp(args, callback, stdin)
			return
		end
		vim.schedule(function()
			if type(resp) == "string" then
				callback(resp, nil)
			elseif resp ~= nil then
				callback(nil, vim.json.encode(resp))
			else
				callback(nil, "{}")
			end
		end)
	end)
end

--- Mock gh.get_head_sha to return a fixed value.
--- @param sha string|nil SHA to return (nil to simulate error)
--- @param err string|nil error message
function M.mock_head_sha(sha, err)
	local gh = require("fude.gh")
	M.mock(gh, "get_head_sha", function()
		return sha, err
	end)
end

--- Mock diff.to_repo_relative to map buffer names to repo-relative paths.
--- @param path_map table<string, string> buffer name pattern -> relative path
function M.mock_diff(path_map)
	local diff = require("fude.diff")

	M.mock(diff, "to_repo_relative", function(filepath)
		for pattern, rel_path in pairs(path_map) do
			if filepath:find(pattern, 1, true) then
				return rel_path
			end
		end
		return nil
	end)

	M.mock(diff, "get_base_content", function(_, _)
		return nil, "mocked: no base content"
	end)
end

--- Mock diff.get_base_content to return specific content.
--- @param content string|nil base file content
function M.mock_base_content(content)
	local diff = require("fude.diff")
	M.mock(diff, "get_base_content", function(_, _)
		if content then
			return content, nil
		end
		return nil, "File not found"
	end)
end

-- Track buffers for cleanup
local test_bufs = {}

--- Create a test buffer with optional lines and name.
--- @param lines string[]|nil buffer lines
--- @param name string|nil buffer name
--- @return number buf handle
function M.create_buf(lines, name)
	local buf = vim.api.nvim_create_buf(false, true)
	if lines then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end
	if name then
		pcall(vim.api.nvim_buf_set_name, buf, name)
	end
	table.insert(test_bufs, buf)
	return buf
end

--- Clean up all test state: buffers, windows, mocks, config state.
function M.cleanup()
	-- Close any extra windows (keep only one)
	local wins = vim.api.nvim_list_wins()
	for i = 2, #wins do
		pcall(vim.api.nvim_win_close, wins[i], true)
	end

	-- Delete test buffers
	for _, buf in ipairs(test_bufs) do
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	test_bufs = {}

	-- Delete preview augroup if exists
	pcall(vim.api.nvim_del_augroup_by_name, "FudePreview")

	-- Restore mocks
	M.restore_all()

	-- Reset config state
	local config = require("fude.config")
	config.reset_state()

	-- Turn off diff mode in remaining windows
	pcall(vim.cmd, "diffoff!")
end

--- Wait for a condition function to return true, with timeout.
--- @param condition_fn fun(): boolean
--- @param timeout_ms number|nil timeout in milliseconds (default 1000)
--- @return boolean success
function M.wait_for(condition_fn, timeout_ms)
	timeout_ms = timeout_ms or 1000
	return vim.wait(timeout_ms, condition_fn, 10)
end

return M
