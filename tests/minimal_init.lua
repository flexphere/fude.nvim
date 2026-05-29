vim.cmd([[set runtimepath+=.]])

-- Allow tests to require dev scripts under scripts/ (e.g. scripts/check_state_deps.lua)
package.path = package.path .. ";./scripts/?.lua"

-- Optional luacov instrumentation. Enable via `LUACOV=1` (or use `make coverage`).
-- When enabled, line-hit stats are accumulated for `lua/fude/` and written to
-- `luacov.stats.out`, which `luacov` (the reporter) turns into a human-readable
-- `luacov.report.out`. luacov is loaded via `pcall` so missing installations
-- fall back to a warning instead of breaking the test run.
if vim.env.LUACOV then
	local ok, runner = pcall(require, "luacov.runner")
	if ok then
		runner.init({ include = { "lua/fude" } })
		-- Force-save stats on Vim exit: nvim --headless does not always trigger
		-- luacov's atexit handler, so we hook VimLeavePre explicitly.
		vim.api.nvim_create_autocmd("VimLeavePre", {
			callback = function()
				runner.save_stats()
			end,
		})
	else
		print("[coverage] luacov not available; install with `luarocks install --local luacov`")
	end
end

local plenary_path = os.getenv("PLENARY_PATH") or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
if vim.fn.isdirectory(plenary_path) == 1 then
	vim.opt.runtimepath:prepend(plenary_path)
end

vim.o.swapfile = false
vim.bo.swapfile = false

vim.api.nvim_create_user_command("RunTests", function(opts)
	local path = opts.fargs[1] or "tests"
	require("plenary.test_harness").test_directory(path, {
		minimal_init = "./tests/minimal_init.lua",
	})
end, { nargs = "?" })
