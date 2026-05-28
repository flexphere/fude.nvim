vim.cmd([[set runtimepath+=.]])

-- Allow tests to require dev scripts under scripts/ (e.g. scripts/check_state_deps.lua)
package.path = package.path .. ";./scripts/?.lua"

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
