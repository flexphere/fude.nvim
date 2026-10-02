if vim.g.loaded_fude then
	return
end
vim.g.loaded_fude = true

-- Every :FudeXxx command is defined in lua/fude/commands.lua. Add new
-- commands there.
require("fude.commands").register_all()
