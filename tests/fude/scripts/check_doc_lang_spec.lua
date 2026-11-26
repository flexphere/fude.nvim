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
