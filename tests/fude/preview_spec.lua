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

describe("is_preview_current", function()
	it("returns true when preview is valid for the same window and buffer", function()
		assert.is_true(preview.is_preview_current(10, true, 1, 20, 1, 20))
	end)

	it("returns false when preview_win is nil", function()
		assert.is_false(preview.is_preview_current(nil, false, 1, 20, 1, 20))
	end)

	it("returns false when preview window is no longer valid", function()
		assert.is_false(preview.is_preview_current(10, false, 1, 20, 1, 20))
	end)

	it("returns false when entering a different window", function()
		assert.is_false(preview.is_preview_current(10, true, 1, 20, 2, 20))
	end)

	it("returns false when the source window shows a different buffer", function()
		assert.is_false(preview.is_preview_current(10, true, 1, 20, 1, 21))
	end)

	it("returns false when preview_source_buf is unknown", function()
		assert.is_false(preview.is_preview_current(10, true, 1, nil, 1, 20))
	end)
end)

describe("find_base_path", function()
	it("returns the old path for a renamed file", function()
		local files = { { path = "lua/new.lua", previous_path = "lua/old.lua", status = "renamed" } }
		assert.equals("lua/old.lua", preview.find_base_path("lua/new.lua", files))
	end)

	it("returns the path itself for a file without previous_path", function()
		local files = { { path = "lua/a.lua", status = "modified" } }
		assert.equals("lua/a.lua", preview.find_base_path("lua/a.lua", files))
	end)

	it("returns the path itself for a file outside changed_files", function()
		local files = { { path = "lua/new.lua", previous_path = "lua/old.lua", status = "renamed" } }
		assert.equals("lua/other.lua", preview.find_base_path("lua/other.lua", files))
	end)

	it("handles nil changed_files", function()
		assert.equals("lua/a.lua", preview.find_base_path("lua/a.lua", nil))
	end)
end)
