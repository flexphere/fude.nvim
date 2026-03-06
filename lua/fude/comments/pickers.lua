local M = {}

--- List all PR review comments in a 3-pane comment browser.
function M.list_comments()
	require("fude.ui.comment_browser").open()
end

return M
