-- scripts/check_doc_lang.lua
--
-- Computational Documentation Language Sensor.
--
-- User-facing documents must be written in English. Reports every line of
-- the target documents that contains a Japanese character:
--   * README.md
--   * doc/fude.txt
--   * CONTRIBUTING.md, up to (not including) the line `# Collaborator guide`
--     (the collaborator guide is internal material and stays in Japanese)
--   * every `*.md` under contrib/ (recursive), except `*.ja.md` translations
--
-- Exception: in a contrib `SKILL.md`, the `description:` line of the leading
-- YAML frontmatter may hold Japanese trigger phrases (they make the skill
-- start when asked in Japanese).
--
-- "Japanese character" means a code point in U+3000–303F (CJK symbols and
-- punctuation), U+3040–309F (hiragana), U+30A0–30FF (katakana), U+4E00–9FFF
-- (CJK unified ideographs; kanji are not told apart from Chinese) or
-- U+FF00–FFEF (full-width forms). Lines are decoded as UTF-8, so other
-- non-ASCII symbols (`·`, `→`, `▶`, `✓`, `●`) are not reported.
--
-- Usage:
--   nvim --headless -l scripts/check_doc_lang.lua [root]
--   (root defaults to the current directory; missing target files are skipped)
--
-- Exit codes:
--   0 = no violations
--   1 = violations found
--   2 = setup / IO error

local M = {}

--- Fixed target files, relative to the root.
M.FIXED_TARGETS = { "README.md", "doc/fude.txt", "CONTRIBUTING.md" }

--- Heading from which CONTRIBUTING.md is no longer checked.
M.COLLABORATOR_GUIDE_HEADING = "# Collaborator guide"

--- Japanese code point ranges (inclusive).
M.JAPANESE_RANGES = {
	{ 0x3000, 0x303F },
	{ 0x3040, 0x309F },
	{ 0x30A0, 0x30FF },
	{ 0x4E00, 0x9FFF },
	{ 0xFF00, 0xFFEF },
}

----------------------------------------------------------------
-- 1. Character classification
----------------------------------------------------------------

--- @param cp integer  Unicode code point
--- @return boolean
function M.is_japanese_codepoint(cp)
	for _, range in ipairs(M.JAPANESE_RANGES) do
		if cp >= range[1] and cp <= range[2] then
			return true
		end
	end
	return false
end

--- Whether a line contains a Japanese character. The line is decoded as
--- UTF-8; malformed bytes are skipped one at a time.
--- @param line string
--- @return boolean
function M.has_japanese(line)
	local i, len = 1, #line
	while i <= len do
		local b = line:byte(i)
		local cp, size
		if b < 0x80 then
			cp, size = b, 1
		elseif b >= 0xC2 and b <= 0xDF then
			cp, size = b - 0xC0, 2
		elseif b >= 0xE0 and b <= 0xEF then
			cp, size = b - 0xE0, 3
		elseif b >= 0xF0 and b <= 0xF4 then
			cp, size = b - 0xF0, 4
		end
		if cp and i + size - 1 <= len then
			for j = i + 1, i + size - 1 do
				local c = line:byte(j)
				if c < 0x80 or c > 0xBF then
					cp = nil
					break
				end
				cp = cp * 0x40 + (c - 0x80)
			end
		else
			cp = nil
		end
		if cp then
			if M.is_japanese_codepoint(cp) then
				return true
			end
			i = i + size
		else
			i = i + 1
		end
	end
	return false
end

----------------------------------------------------------------
-- 2. Target files
----------------------------------------------------------------

--- Build the list of target files from the fixed targets and the files
--- found under contrib/.
--- @param contrib_files string[]  root-relative paths of files under contrib/
--- @return string[]  root-relative target paths (fixed first, then contrib sorted)
function M.build_target_files(contrib_files)
	local targets = {}
	for _, path in ipairs(M.FIXED_TARGETS) do
		table.insert(targets, path)
	end
	local contrib = {}
	for _, path in ipairs(contrib_files) do
		if path:match("%.md$") and not path:match("%.ja%.md$") then
			table.insert(contrib, path)
		end
	end
	table.sort(contrib)
	for _, path in ipairs(contrib) do
		table.insert(targets, path)
	end
	return targets
end

--- @param path string  root-relative path
--- @return boolean
local function is_contrib_skill(path)
	return path:match("^contrib/") ~= nil and path:match("/SKILL%.md$") ~= nil
end

----------------------------------------------------------------
-- 3. Violations
----------------------------------------------------------------

--- Find the lines of one document that contain Japanese characters,
--- applying the per-file exceptions.
--- @param path string  root-relative path (decides the exceptions)
--- @param text string  file content
--- @return { path: string, line: integer, content: string }[]
function M.find_violations(path, text)
	local violations = {}
	local is_contributing = path == "CONTRIBUTING.md"
	local lines = {}
	-- `text .. "\n"` yields a trailing empty line for a file ending in a
	-- newline; it never contains Japanese, so it is never reported.
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	-- Last frontmatter line of a contrib SKILL.md (0 = none). A frontmatter
	-- opens with `---` on line 1 and counts only once a closing `---` follows,
	-- so an unclosed one does not exempt `description:` lines of the body.
	local frontmatter_end = 0
	if is_contrib_skill(path) and lines[1] == "---" then
		for i = 2, #lines do
			if lines[i] == "---" then
				frontmatter_end = i - 1
				break
			end
		end
	end
	for lnum, line in ipairs(lines) do
		if is_contributing and (line:gsub("%s+$", "")) == M.COLLABORATOR_GUIDE_HEADING then
			break
		end
		local allowed = lnum >= 2 and lnum <= frontmatter_end and line:match("^description:") ~= nil
		if not allowed and M.has_japanese(line) then
			table.insert(violations, { path = path, line = lnum, content = line })
		end
	end
	return violations
end

--- @param violations { path: string, line: integer, content: string }[]
--- @return string  one `<path>:<line>: <content>` line per violation
function M.format_violations(violations)
	local lines = {}
	for _, v in ipairs(violations) do
		table.insert(lines, string.format("%s:%d: %s", v.path, v.line, v.content))
	end
	return table.concat(lines, "\n")
end

----------------------------------------------------------------
-- 4. Main entry
----------------------------------------------------------------

local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text, nil
end

--- Normalize the root argument: nil or "" → ".", trailing slashes removed
--- ("/" stays "/").
--- @param root string|nil
--- @return string
function M.normalize_root(root)
	if root == nil or root == "" then
		return "."
	end
	local stripped = root:gsub("/+$", "")
	if stripped == "" then
		return "/"
	end
	return stripped
end

--- Join a normalized root and a root-relative path.
--- @param root string
--- @param path string
--- @return string
function M.join_path(root, path)
	if root == "/" then
		return "/" .. path
	end
	return root .. "/" .. path
end

--- Root-relative paths of every file under `<root>/contrib` (recursive).
--- @param root string  normalized root
--- @return string[]
function M.list_contrib_files(root)
	local dir = M.join_path(root, "contrib")
	if vim.fn.isdirectory(dir) ~= 1 then
		return {}
	end
	local files = {}
	for name, kind in vim.fs.dir(dir, { depth = math.huge }) do
		if kind == "file" then
			table.insert(files, "contrib/" .. name)
		end
	end
	return files
end

--- @param root string|nil  repository root (defaults to ".")
--- @param streams { stdout: file*, stderr: file* }|nil  output (defaults to io.stdout / io.stderr)
--- @return number  exit code
function M.main(root, streams)
	local stdout = streams and streams.stdout or io.stdout
	local stderr = streams and streams.stderr or io.stderr
	root = M.normalize_root(root)
	if vim.fn.isdirectory(root) ~= 1 then
		stderr:write("Error: root is not a directory: " .. root .. "\n")
		return 2
	end
	-- A single missing target is skipped, but a root holding none of the fixed
	-- targets is the wrong directory: reading nothing must not pass as OK.
	local has_fixed = false
	for _, path in ipairs(M.FIXED_TARGETS) do
		if vim.fn.filereadable(M.join_path(root, path)) == 1 then
			has_fixed = true
			break
		end
	end
	if not has_fixed then
		stderr:write("Error: none of " .. table.concat(M.FIXED_TARGETS, ", ") .. " found under " .. root .. "\n")
		return 2
	end

	local violations = {}
	for _, path in ipairs(M.build_target_files(M.list_contrib_files(root))) do
		local full = M.join_path(root, path)
		if vim.fn.filereadable(full) == 1 then
			local text, err = read_file(full)
			if not text then
				stderr:write("Error: cannot read " .. path .. ": " .. (err or "") .. "\n")
				return 2
			end
			vim.list_extend(violations, M.find_violations(path, text))
		end
	end

	-- write rather than print: under `nvim -l`, print does not end
	-- the output with a newline.
	if #violations == 0 then
		stdout:write("OK: no Japanese characters in user-facing documents.\n")
		return 0
	end
	stdout:write(M.format_violations(violations) .. "\n\n")
	stdout:write(
		string.format(
			"FAIL: %d line(s) with Japanese characters. User-facing documents must be written in English.\n",
			#violations
		)
	)
	return 1
end

if arg and arg[0] and arg[0]:match("check_doc_lang%.lua$") then
	os.exit(M.main(arg[1]))
end

return M
