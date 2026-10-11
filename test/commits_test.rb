# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/catalog"
require "agent_diff/browser"

# A session on a feature branch whose work is committed, pushed and partly
# merged into main on the remote, with the real commits shown in its timeline.
class CommitsTest < Minitest::Test
  T0 = Time.at(1_790_000_000)

  def setup
    @tmp = Dir.mktmpdir("agent_diff_commits")
    ENV["AGENT_DIFF_HOME"] = File.join(@tmp, "home")
    @work = File.realpath(FileUtils.mkdir_p(File.join(@tmp, "work")).first)
    @remote = File.join(@tmp, "remote.git")
    sh("git", "init", "--quiet", "--bare", "--initial-branch=main", @remote)
    git("init", "--quiet", "--initial-branch=main", ".")
    git("config", "user.email", "t@t")
    git("config", "user.name", "Tess")
    git("remote", "add", "origin", @remote)
    write("a.rb", "def a\n  1\nend\n")
    write("other.rb", "x\n")
    commit_all("initial", at: 0)
    git("push", "--quiet", "-u", "origin", "main")
    git("remote", "set-head", "origin", "main")
    git("checkout", "--quiet", "-b", "feature")

    @shadow = AgentDiff::Shadow.new(@work).init!
    at(10) { @shadow.snap!(message: "baseline", meta: { kind: "seed" }) }

    # Prompt one edits a.rb, then the agent commits it mid-turn; pushed and
    # merged into main on the remote.
    write("a.rb", "def a\n  2\nend\n")
    @merged = commit_all("Change a", at: 100)
    prompt("change a", at: 110)
    git("push", "--quiet", "-u", "origin", "feature")
    git("push", "--quiet", "origin", "feature:main")

    # Prompt two, committed later by hand and only pushed.
    write("a.rb", "def a\n  3\nend\n")
    prompt("again a", at: 200)
    @pushed = commit_all("Again a", at: 300)
    git("push", "--quiet", "origin", "feature")

    # Still local: touches a file the session changed.
    write("a.rb", "def a\n  4\nend\n")
    @local = commit_all("Tidy a", at: 400)

    # Someone else's later commit to a file the session never touched.
    write("other.rb", "y\n")
    @unrelated = commit_all("Unrelated", at: 500)

    @catalog = AgentDiff::Catalog.new(claude_dir: File.join(@tmp, "none"), codex_dir: File.join(@tmp, "none"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete("AGENT_DIFF_HOME")
  end

  def session
    @catalog.sessions(@shadow).find { |s| s.id == "s-one" }
  end

  def test_session_commits_with_their_lifecycle
    commits = @catalog.commits(@shadow, session)
    assert_equal [@local, @pushed, @merged], commits.map { |c| c[:sha] }
    assert_equal %w[local pushed merged], commits.map { |c| c[:state] }
    assert_equal "Tess", commits.first[:author]
  end

  def test_commit_rows_read_their_diff_from_the_real_repo
    c = @catalog.commits(@shadow, session).last
    stat = @shadow.stat(c[:sha])
    assert_equal ["a.rb"], stat[:files].map { |f| f[:path] }
    assert_equal 1, stat[:added]
    assert_includes @shadow.patch(c[:sha]), "+  2"
  end

  def test_recorded_commit_markers_stay_out_of_sessions
    at(600) { @shadow.sweep! }
    rows = @catalog.sessions(@shadow).flat_map(&:entries)
    refute(rows.any? { |e| e[:kind] == "commit" })
  end

  def test_browser_interleaves_commits_with_prompts_newest_first
    b = AgentDiff::Browser.new(io: StringIO.new, input: StringIO.new, catalog: @catalog,
                               size: [40, 120], cwd: @work)
    header, _rule, *body = b.render
    # "Change a" was committed during the "change a" turn, so it sits above it.
    order = ["Tidy a", "Again a", "again a", "Change a", "change a"].map do |label|
      body.index { |l| l.include?(label) } or flunk("#{label} missing:\n#{body.join("\n")}")
    end
    assert_equal order.sort, order
    assert_includes body.find { |l| l.include?("Tidy a") }, "local"
    assert_includes body.find { |l| l.include?("Change a") }, "merged"
    assert_includes header, "3 commits (1 local)"
    refute_includes body.join("\n"), "Unrelated"
  end

  private

  def prompt(text, at:)
    at(at) do
      head = @shadow.real_head
      @shadow.snap!(message: text, meta: { session: "s-one", agent: "claude", prompt: text,
                                           started: (T0 + at - 20).iso8601 }.merge(head))
    end
  end

  def commit_all(message, at:)
    at(at) do
      git("add", "-A")
      git("commit", "--quiet", "-m", message)
      git("rev-parse", "HEAD").strip
    end
  end

  def at(offset)
    stamp = (T0 + offset).iso8601
    saved = ENV.to_h.slice("GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE")
    ENV["GIT_AUTHOR_DATE"] = ENV["GIT_COMMITTER_DATE"] = stamp
    yield
  ensure
    %w[GIT_AUTHOR_DATE GIT_COMMITTER_DATE].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def write(rel, body)
    File.write(File.join(@work, rel), body)
  end

  def git(*args)
    sh("git", "-C", @work, *args)
  end

  def sh(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "#{cmd.join(" ")}: #{err}" unless status.success?

    out
  end
end
