if vim.g.loaded_fude then
	return
end
vim.g.loaded_fude = true

-- Every :FudeXxx command is defined in lua/fude/commands.lua (the registry
-- shared with the :FudeCommandPalette command palette). Add new commands there.
require("fude.commands").register_all()

vim.api.nvim_create_user_command("FudeCommandPalette", function(opts)
	local range = nil
	if opts.range > 0 then
		range = { opts.line1, opts.line2 }
	end
	require("fude.palette").open({ range = range })
end, { desc = "Open the fude command palette", range = true })
