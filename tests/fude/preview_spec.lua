local preview = require("fude.preview")

describe("should_open_preview", function()
	it("returns true when all conditions met", function()
		assert.is_true(preview.should_open_preview(true, false, 1, 2, "", "/path/to/file.lua"))
	end)

	it("returns false when not active", function()
		assert.is_false(preview.should_open_preview(false, false, 1, 2, "", "/path/to/file.lua"))
	end)

	it("returns false when opening (re-entrancy guard)", function()
		assert.is_false(preview.should_open_preview(true, true, 1, 2, "", "/path/to/file.lua"))
	end)

	it("returns false when current window is preview window", function()
		assert.is_false(preview.should_open_preview(true, false, 5, 5, "", "/path/to/file.lua"))
	end)

	it("returns false for special buffer types", function()
		assert.is_false(preview.should_open_preview(true, false, 1, 2, "nofile", "/path/to/file.lua"))
	end)

	it("returns false for empty filepath", function()
		assert.is_false(preview.should_open_preview(true, false, 1, 2, "", ""))
	end)

	it("returns true when preview_win is nil", function()
		assert.is_true(preview.should_open_preview(true, false, 1, nil, "", "/path/to/file.lua"))
	end)

	it("returns false when both not active and opening", function()
		assert.is_false(preview.should_open_preview(false, true, 1, 2, "", "/path/to/file.lua"))
	end)
end)
