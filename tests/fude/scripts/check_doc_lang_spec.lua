local check = require("check_doc_lang")

describe("check_doc_lang.has_japanese", function()
	it("detects hiragana, katakana, kanji, CJK punctuation and full-width forms", function()
		assert.is_true(check.has_japanese("ひらがな"))
		assert.is_true(check.has_japanese("カタカナ"))
		assert.is_true(check.has_japanese("漢字"))
		assert.is_true(check.has_japanese("a、b"))
		assert.is_true(check.has_japanese("（full-width）"))
	end)

	it("does not detect ASCII, symbols, emoji or malformed bytes", function()
		assert.is_false(check.has_japanese("plain ASCII"))
		assert.is_false(check.has_japanese("· → ▶ ✓ ● ○ ✗ ⣾ ━"))
		assert.is_false(check.has_japanese("👍 ❤️"))
		assert.is_false(check.has_japanese("\227\129"))
		assert.is_false(check.has_japanese("\255\254"))
	end)
end)

describe("check_doc_lang.find_violations", function()
	it("reports a line containing Japanese with its path and line number", function()
		local v = check.find_violations("README.md", "# Title\nok line\nこれは日本語\nend\n")
		assert.are.same({ { path = "README.md", line = 3, content = "これは日本語" } }, v)
	end)

	it("does not report lines without Japanese characters, including non-ASCII symbols", function()
		local text = table.concat({
			"plain ASCII line",
			"middle dot · arrow → triangle ▶",
			"check ✓ bullet ● circle ○",
			"emoji 👍 and accents café",
		}, "\n")
		assert.are.same({}, check.find_violations("README.md", text))
		assert.are.same({}, check.find_violations("doc/fude.txt", text))
	end)

	it("ignores CONTRIBUTING.md lines from the Collaborator guide heading on", function()
		local text = "# Contributing\nEnglish only\n# Collaborator guide\n日本語の説明\n## 節\n"
		assert.are.same({}, check.find_violations("CONTRIBUTING.md", text))
	end)

	it("reports CONTRIBUTING.md lines before the Collaborator guide heading", function()
		local text = "# Contributing\n日本語の行\n# Collaborator guide\n日本語の説明\n"
		assert.are.same(
			{ { path = "CONTRIBUTING.md", line = 2, content = "日本語の行" } },
			check.find_violations("CONTRIBUTING.md", text)
		)
	end)

	it("allows Japanese in the frontmatter description line of a contrib SKILL.md", function()
		local text =
			"---\nname: fude-watch\ndescription: Watch reviews. Triggers: 「レビュー待受して」.\n---\n\n# Body\n"
		assert.are.same({}, check.find_violations("contrib/skills/fude-watch/SKILL.md", text))
	end)

	it("reports Japanese in the body of a contrib SKILL.md", function()
		local text = "---\nname: x\ndescription: 起動フレーズ\n---\n\ndescription: 本文の行\n本文\n"
		assert.are.same({
			{ path = "contrib/skills/x/SKILL.md", line = 6, content = "description: 本文の行" },
			{ path = "contrib/skills/x/SKILL.md", line = 7, content = "本文" },
		}, check.find_violations("contrib/skills/x/SKILL.md", text))
	end)

	it("reports a frontmatter description line outside a contrib SKILL.md", function()
		local text = "---\ndescription: 日本語\n---\n"
		assert.are.same(1, #check.find_violations("contrib/skills/x/README.md", text))
		assert.are.same(1, #check.find_violations("README.md", text))
	end)

	it("strips a trailing carriage return from reported content", function()
		local v = check.find_violations("README.md", "ok\r\n日本語\r\n")
		assert.are.same({ { path = "README.md", line = 2, content = "日本語" } }, v)
	end)
end)

describe("check_doc_lang.build_target_files", function()
	it("excludes *.ja.md translation files from the target list", function()
		local targets = check.build_target_files({
			"contrib/skills/fude-watch/SKILL.md",
			"contrib/skills/fude-watch/SKILL.ja.md",
			"contrib/notes.ja.md",
			"contrib/script.sh",
			"contrib/a/README.md",
		})
		assert.are.same({
			"README.md",
			"doc/fude.txt",
			"CONTRIBUTING.md",
			"contrib/a/README.md",
			"contrib/skills/fude-watch/SKILL.md",
		}, targets)
	end)
end)

describe("check_doc_lang.format_violations", function()
	it("formats each violation as <path>:<line>: <content> on its own line", function()
		local violations = {}
		vim.list_extend(violations, check.find_violations("README.md", "ok\n日本語\n"))
		vim.list_extend(violations, check.find_violations("doc/fude.txt", "a\nb\nテスト: x\n"))
		local lines = vim.split(check.format_violations(violations), "\n", { plain = true })
		assert.are.same({ "README.md:2: 日本語", "doc/fude.txt:3: テスト: x" }, lines)
	end)
end)

describe("check_doc_lang frontmatter", function()
	it("does not exempt description lines when the frontmatter is never closed", function()
		local text = "---\nname: x\ndescription: 起動フレーズ\n\n# Body\ndescription: 本文\n"
		assert.are.same({
			{ path = "contrib/skills/x/SKILL.md", line = 3, content = "description: 起動フレーズ" },
			{ path = "contrib/skills/x/SKILL.md", line = 6, content = "description: 本文" },
		}, check.find_violations("contrib/skills/x/SKILL.md", text))
	end)

	it("exempts the description line of a SKILL.md directly under contrib/", function()
		local text = "---\ndescription: 日本語\n---\n"
		assert.are.same({}, check.find_violations("contrib/SKILL.md", text))
	end)
end)

describe("check_doc_lang.normalize_root", function()
	it("defaults nil and the empty string to the current directory", function()
		assert.are.equal(".", check.normalize_root(nil))
		assert.are.equal(".", check.normalize_root(""))
	end)

	it("strips trailing slashes but keeps a lone slash", function()
		assert.are.equal("/tmp/repo", check.normalize_root("/tmp/repo/"))
		assert.are.equal("/tmp/repo", check.normalize_root("/tmp/repo//"))
		assert.are.equal("/", check.normalize_root("/"))
		assert.are.equal("/", check.normalize_root("///"))
		assert.are.equal("rel", check.normalize_root("rel"))
	end)
end)

describe("check_doc_lang.join_path", function()
	it("joins without doubling the slash of the filesystem root", function()
		assert.are.equal("/README.md", check.join_path("/", "README.md"))
		assert.are.equal("./README.md", check.join_path(".", "README.md"))
		assert.are.equal("/a/doc/fude.txt", check.join_path("/a", "doc/fude.txt"))
	end)
end)

describe("check_doc_lang filesystem entry points", function()
	local root
	local out, streams

	local function write(rel, text)
		local full = root .. "/" .. rel
		vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
		local f = assert(io.open(full, "wb"))
		f:write(text)
		f:close()
	end

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		out = {}
		local sink = {
			write = function(_, s)
				table.insert(out, s)
			end,
		}
		streams = { stdout = sink, stderr = sink }
	end)

	after_each(function()
		vim.fn.delete(root, "rf")
	end)

	it("lists contrib files recursively", function()
		write("contrib/skills/a/SKILL.md", "x")
		write("contrib/skills/a/SKILL.ja.md", "x")
		write("contrib/top.md", "x")
		local files = check.list_contrib_files(root)
		table.sort(files)
		assert.are.same({ "contrib/skills/a/SKILL.ja.md", "contrib/skills/a/SKILL.md", "contrib/top.md" }, files)
	end)

	it("lists nothing when contrib/ does not exist", function()
		assert.are.same({}, check.list_contrib_files(root))
	end)

	it("returns 1 and prints the violations when a target has Japanese", function()
		write("README.md", "ok\nテスト\n")
		write("contrib/skills/a/SKILL.md", "---\ndescription: 起動\n---\n本文\n")
		write("contrib/skills/a/SKILL.ja.md", "日本語\n")
		assert.are.equal(1, check.main(root .. "/", streams))
		local printed = table.concat(out)
		assert.is_truthy(printed:find("README.md:2: テスト", 1, true))
		assert.is_truthy(printed:find("contrib/skills/a/SKILL.md:4: 本文", 1, true))
		assert.is_falsy(printed:find("SKILL.ja.md", 1, true))
		assert.is_falsy(printed:find("起動", 1, true))
	end)

	it("returns 0 when the targets have no Japanese and skips missing ones", function()
		write("README.md", "English · →\n")
		write("CONTRIBUTING.md", "# Contributing\n# Collaborator guide\n日本語\n")
		assert.are.equal(0, check.main(root, streams))
	end)

	it("returns 2 when the root is not a directory", function()
		write("README.md", "x\n")
		assert.are.equal(2, check.main(root .. "/README.md", streams))
		assert.are.equal(2, check.main(root .. "/missing", streams))
		assert.is_truthy(table.concat(out):find("root is not a directory", 1, true))
	end)

	it("returns 2 when the root holds none of the fixed targets", function()
		write("contrib/notes.md", "日本語\n")
		assert.are.equal(2, check.main(root, streams))
		assert.is_truthy(table.concat(out):find("none of", 1, true))
	end)
end)
