# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/catalog"
require "agent_diff/browser"

# A temp project with a shadow holding two Claude sessions and one hand edit,
# plus a fake ~/.claude/projects transcript directory.
module Fixture
  def setup
    @tmp = Dir.mktmpdir("agent_diff_catalog")
    @home = File.join(@tmp, "home")
    ENV["AGENT_DIFF_HOME"] = @home
    @work = File.realpath(FileUtils.mkdir_p(File.join(@tmp, "work")).first)
    @claude = File.join(@tmp, "claude", "projects")
    git("init", "--quiet", ".")
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    write("a.rb", "def a\n  1\nend\n")
    git("add", ".")
    git("commit", "--quiet", "-m", "real")

    @shadow = AgentDiff::Shadow.new(@work).init!
    @shadow.snap!(message: "baseline", meta: { kind: "seed" })
    write("a.rb", "def a\n  2\nend\n")
    @shadow.snap!(message: "change a", meta: { session: "s-one", agent: "claude", prompt: "change a please" })
    write("b.rb", "b\n")
    @shadow.snap!(message: "add b", meta: { session: "s-two", agent: "claude" })
    write("c.txt", "c\n")
    @shadow.snap!(message: "manual edits", meta: { kind: "manual", source: "you" })
    write("a.rb", "def a\n  3\nend\n")
    @shadow.snap!(message: "again a", meta: { session: "s-one", agent: "claude" })

    transcript("s-one", { "type" => "ai-title", "aiTitle" => "Old title", "sessionId" => "s-one" },
               { "type" => "user", "cwd" => @work },
               { "type" => "ai-title", "aiTitle" => "Tweak a", "sessionId" => "s-one" })
    @codex = File.join(@tmp, "codex")
    @catalog = AgentDiff::Catalog.new(claude_dir: @claude, codex_dir: @codex)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete("AGENT_DIFF_HOME")
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @work, *args)
    raise "git #{args.inspect}: #{err}" unless status.success?

    out
  end

  def write(rel, body)
    File.write(File.join(@work, rel), body)
  end

  def transcript(id, *records)
    dir = File.join(@claude, "-work")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.jsonl"), records.map(&:to_json).join("\n") + "\n")
  end
end

class CatalogTest < Minitest::Test
  include Fixture

  def test_repos_use_the_recorded_root
    repos = @catalog.repos
    assert_equal [@work], repos.map(&:root)
    assert_equal "work", repos.first.name
  end

  def test_repos_backfill_a_root_from_transcript_cwds
    Open3.capture3("git", "--git-dir=#{@shadow.git_dir}", "config", "--unset", "agentdiff.root")
    Dir.chdir(@tmp) { assert_equal [@work], @catalog.repos.map(&:root) }
    out, = Open3.capture3("git", "--git-dir=#{@shadow.git_dir}", "config", "--get", "agentdiff.root")
    assert_equal @work, out.strip, "the backfilled root is written back"
  end

  def test_sessions_group_by_session_with_manual_rows_together
    sessions = @catalog.sessions(@shadow)
    assert_equal ["s-one", AgentDiff::Catalog::MANUAL_ID, "s-two"], sessions.map(&:id)
    assert_equal %w[again\ a change\ a], sessions.first.entries.map { |e| e[:subject] }
    assert sessions[1].manual
  end

  def test_titles_come_from_the_latest_ai_title_else_the_first_prompt
    by_id = @catalog.sessions(@shadow).to_h { |s| [s.id, s.title] }
    assert_equal "Tweak a", by_id["s-one"]
    assert_equal "add b", by_id["s-two"]
  end

  def test_codex_titles_come_from_its_session_index
    FileUtils.mkdir_p(@codex)
    File.write(File.join(@codex, "session_index.jsonl"), [
      { "id" => "s-two", "thread_name" => "First name" },
      { "id" => "s-two", "thread_name" => "Add b file" },
      { "id" => "s-one", "thread_name" => "Ignored, Claude has a title" }
    ].map(&:to_json).join("\n") + "\n")
    by_id = @catalog.sessions(@shadow).to_h { |s| [s.id, s.title] }
    assert_equal "Add b file", by_id["s-two"]
    assert_equal "Tweak a", by_id["s-one"]
  end

  def test_saved_titles_name_sessions_with_no_transcript
    FileUtils.mkdir_p(File.join(@home, "titles"))
    File.write(File.join(@home, "titles", "s-two.txt"), "Add the b file\n")
    by_id = @catalog.sessions(@shadow).to_h { |s| [s.id, s.title] }
    assert_equal "Add the b file", by_id["s-two"]
  end

  def test_totals_match_stat
    @catalog.sessions(@shadow).flat_map(&:entries).each do |e|
      stat = @shadow.stat(e[:sha])
      t = @catalog.totals(@shadow, e)
      assert_equal [stat[:added], stat[:deleted], stat[:files].size],
                   [t[:added], t[:deleted], t[:files]], e[:subject]
    end
  end

  def test_patch_can_be_scoped_to_one_file_from_any_directory
    sha = @catalog.sessions(@shadow).first.entries.last[:sha]
    Dir.chdir(@tmp) do
      patch = @shadow.patch(sha, path: "a.rb")
      assert_includes patch, "+  2"
      refute_includes patch, "b.rb"
    end
  end
end

class BrowserTest < Minitest::Test
  include Fixture

  def browser
    AgentDiff::Browser.new(io: StringIO.new, input: StringIO.new, catalog: @catalog,
                           size: [30, 120], cwd: @work)
  end

  def frame(b)
    b.render.join("\n")
  end

  def test_opens_on_the_newest_session_with_files_nested_under_prompts
    b = browser
    assert_equal @work, b.repo.root
    assert_equal "Tweak a", b.session.title
    lines = b.render
    prompt = lines.index { |l| l.include?("change a") && !l.include?("again") }
    assert prompt, frame(b)
    assert_includes lines[prompt + 1], "a.rb", "a prompt's files sit directly under it"
    refute_includes frame(b), "add b", "other sessions stay out of the main view"
  end

  def test_l_opens_a_file_into_its_changed_blocks_and_h_closes_it
    b = browser
    b.press("j")
    assert_equal :file, b.selected.kind
    b.press("l")
    assert_includes frame(b), "def a:1"
    b.press("j")
    assert_equal :hunk, b.selected.kind
    b.press("h")
    assert_equal :file, b.selected.kind
    b.press("h")
    refute_includes frame(b), "def a:1"
  end

  def test_e_toggles_the_file_under_the_cursor
    b = browser
    b.press("j")
    b.press("e")
    assert_includes frame(b), "def a:1"
    b.press("j")
    assert_equal :hunk, b.selected.kind
    b.press("e")
    assert_equal :file, b.selected.kind
    refute_includes frame(b), "def a:1"
  end

  def test_e_on_a_prompt_opens_all_its_files
    b = browser
    assert_equal :prompt, b.selected.kind
    b.press("e")
    assert_equal 1, frame(b).scan("def a:1").size, "only this prompt's files open"
    b.press("e")
    refute_includes frame(b), "def a:1"
  end

  def test_shift_e_opens_every_file_then_closes_them
    b = browser
    b.press("E")
    assert_equal 2, frame(b).scan("def a:1").size
    b.press("j")
    b.press("j")
    assert_equal :hunk, b.selected.kind
    b.press("E")
    refute_includes frame(b), "def a:1"
    assert_equal :file, b.selected.kind
  end

  def test_zoom_shows_the_full_prompt
    b = browser
    3.times { b.press("j") }
    assert_equal "change a", b.selected.entry[:subject]
    refute_includes frame(b), "change a please"
    b.press("z")
    assert_includes frame(b), "change a please"
  end

  def test_switcher_filters_every_session_and_teleports
    b = browser
    b.press("s")
    assert b.switcher
    "add".each_char { |c| b.press(c) }
    assert_includes frame(b), "add b"
    b.press("\r")
    assert_nil b.switcher
    assert_equal "s-two", b.session.id
    assert_includes frame(b), "b.rb"
  end

  def test_switcher_closes_on_escape_without_moving
    b = browser
    b.press("s")
    b.press(:down)
    b.press(:escape)
    assert_nil b.switcher
    assert_equal "s-one", b.session.id
  end

  def test_enter_opens_the_file_at_its_first_changed_block
    log = File.join(@tmp, "editor.log")
    editor = File.join(@tmp, "editor")
    File.write(editor, "#!/bin/sh\necho \"$@\" > #{log}\n")
    File.chmod(0o755, editor)
    ENV["VISUAL"] = editor
    b = browser
    b.press("j")
    b.press("\r")
    # The enclosing def, not the edited line inside it: hunks resolve there.
    assert_equal "+1 #{File.join(@work, "a.rb")}", File.read(log).strip
  ensure
    ENV.delete("VISUAL")
  end

  def test_frame_fills_the_terminal_exactly
    [browser, browser.tap { |b| b.press("s") }].each do |b|
      lines = b.render
      assert_equal 30, lines.size
      lines.each { |l| assert_operator l.length, :<=, 120, l }
    end
  end
end
