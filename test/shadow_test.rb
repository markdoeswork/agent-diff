# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/shadow"

# The guarantee these tests exist to protect: the shadow repo must never
# perturb the real repository it is watching.
class ShadowTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("agent_diff_test")
    @home = File.join(@tmp, "home")
    ENV["AGENT_DIFF_HOME"] = @home
    @work = File.join(@tmp, "work")
    FileUtils.mkdir_p(@work)
    git("init", "--quiet", ".")
    git("config", "user.email", "t@t")
    git("config", "user.name", "t")
    write("a.txt", "one\n")
    git("add", "a.txt")
    git("commit", "--quiet", "-m", "real")
    @shadow = AgentDiff::Shadow.new(@work)
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

  def write(path, body)
    full = File.join(@work, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def real_state
    {
      status: git("status", "--porcelain"),
      head: git("rev-parse", "HEAD"),
      staged: git("diff", "--cached", "--name-only")
    }
  end

  # The headline guarantee.
  def test_does_not_disturb_real_repo
    write("b.txt", "staged\n")
    git("add", "b.txt")          # something deliberately left staged
    write("a.txt", "one\ntwo\n") # a dirty tracked file
    write("u.txt", "untracked\n")

    before = real_state
    @shadow.snap!(message: "first")
    @shadow.entries
    @shadow.pending
    after = real_state

    assert_equal before[:status], after[:status], "real status changed"
    assert_equal before[:head], after[:head], "real HEAD moved"
    assert_equal before[:staged], after[:staged], "real index changed"
    assert_includes after[:staged], "b.txt"
  end

  def test_never_tracks_real_git_directory
    @shadow.snap!(message: "first")
    tracked = Open3.capture3("git", "--git-dir=#{@shadow.git_dir}",
                             "--work-tree=#{@work}", "ls-files").first
    refute_match(%r{^\.git/}, tracked)
  end

  def test_counts_added_and_deleted_lines
    @shadow.snap!(message: "baseline")
    write("a.txt", "one\ntwo\nthree\n")
    write("new.txt", "x\ny\n")
    sha = @shadow.snap!(message: "edit")

    stat = @shadow.stat(sha)
    assert_equal 4, stat[:added]      # two added to a.txt + two in new.txt
    assert_equal 0, stat[:deleted]
    paths = stat[:files].map { |f| f[:path] }.sort
    assert_equal ["a.txt", "new.txt"], paths
    assert_equal "A", stat[:files].find { |f| f[:path] == "new.txt" }[:status]
    assert_equal "M", stat[:files].find { |f| f[:path] == "a.txt" }[:status]
  end

  def test_records_deletions
    write("gone.txt", "bye\n")
    @shadow.snap!(message: "baseline")
    FileUtils.rm(File.join(@work, "gone.txt"))
    sha = @shadow.snap!(message: "delete")

    stat = @shadow.stat(sha)
    file = stat[:files].find { |f| f[:path] == "gone.txt" }
    assert_equal "D", file[:status]
    assert_equal 1, stat[:deleted]
  end

  # An idle or question-only prompt must not leave an empty commit.
  def test_no_op_snap_returns_nil
    @shadow.snap!(message: "baseline")
    assert_nil @shadow.snap!(message: "nothing changed")
  end

  # Changes made by bash rather than an edit tool are the whole reason this
  # exists -- Claude's own checkpoints do not track them.
  def test_captures_bash_made_changes
    @shadow.snap!(message: "baseline")
    system("touch #{File.join(@work, "made_by_bash.txt")}")
    system("rm -f #{File.join(@work, "a.txt")}")
    sha = @shadow.snap!(message: "bash work")

    paths = @shadow.stat(sha)[:files].map { |f| f[:path] }.sort
    assert_equal ["a.txt", "made_by_bash.txt"], paths
  end

  def test_metadata_round_trips
    sha = @shadow.snap!(message: "make the pane wider",
                        meta: { pane: "wD:p8", session: "abc123", agent: "claude" })
    entry = @shadow.entries.first

    assert_equal sha, entry[:sha]
    assert_equal "make the pane wider", entry[:subject]
    assert_equal "wD:p8", entry[:pane_id]
    assert_equal "claude", entry[:agent]
  end

  def test_filters_by_pane
    @shadow.snap!(message: "from A", meta: { pane: "wA:p1" })
    write("a.txt", "changed\n")
    @shadow.snap!(message: "from B", meta: { pane: "wB:p2" })

    assert_equal ["from B"], @shadow.entries(pane: "wB:p2").map { |e| e[:subject] }
    assert_equal ["from A"], @shadow.entries(pane: "wA:p1").map { |e| e[:subject] }
  end

  def test_seed_entries_are_hidden
    @shadow.snap!(message: "baseline", meta: { kind: "seed" })
    assert_empty @shadow.entries
  end

  def test_pending_shows_uncommitted_work
    @shadow.snap!(message: "baseline")
    write("wip.txt", "in flight\n")

    pending = @shadow.pending
    assert_equal ["wip.txt"], pending[:files].map { |f| f[:path] }
    assert_equal 1, pending[:added]
  end

  def test_long_subject_is_truncated
    sha = @shadow.snap!(message: "x" * 300)
    assert_operator @shadow.entries.first[:subject].length, :<=, 120
    refute_nil sha
  end

  def test_binary_files_count_as_files_but_not_lines
    @shadow.snap!(message: "baseline")
    File.binwrite(File.join(@work, "blob.bin"), [0, 1, 2, 255].pack("C*") * 64)
    sha = @shadow.snap!(message: "binary")

    stat = @shadow.stat(sha)
    file = stat[:files].find { |f| f[:path] == "blob.bin" }
    assert file[:binary], "expected binary flag"
    assert_equal 0, stat[:added]
  end

  # A non-git directory has no .gitignore to bound what is captured, and can
  # sit on top of an enormous tree -- a server data directory produced a 558M
  # shadow before this guard existed.
  def test_refuses_a_non_git_directory
    plain = File.join(@tmp, "not_a_repo")
    FileUtils.mkdir_p(plain)
    shadow = AgentDiff::Shadow.new(plain)

    error = assert_raises(RuntimeError) { shadow.init! }
    assert_match(/not a git repository/, error.message)
    refute File.directory?(shadow.git_dir), "shadow repo should not be created"
  end

  def test_non_git_directory_can_be_opted_into
    plain = File.join(@tmp, "opted_in")
    FileUtils.mkdir_p(plain)
    File.write(File.join(plain, "f.txt"), "hi\n")
    ENV["AGENT_DIFF_ALLOW_NON_GIT"] = "1"
    shadow = AgentDiff::Shadow.new(plain)

    refute_nil shadow.snap!(message: "explicit")
  ensure
    ENV.delete("AGENT_DIFF_ALLOW_NON_GIT")
  end

  # sweep! is what makes this a history of everything rather than only of
  # hooked prompts. These three cover the cases it exists for.

  def test_sweep_records_manual_edits_as_you
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    write("hand.txt", "typed by a person\n")

    assert_equal "manual", @shadow.sweep!
    row = @shadow.entries(limit: 1).first
    assert_equal "you", row[:source]
    assert_equal "manual", row[:kind]
    assert_includes @shadow.stat(row[:sha])[:files].map { |f| f[:path] }, "hand.txt"
  end

  # A commit moves HEAD without touching the worktree, so it has to be noticed
  # by comparing HEAD -- and its contents read from the real repo, since the
  # shadow snapshot for it is necessarily empty.
  def test_sweep_records_a_real_commit_with_its_contents
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    write("committed.txt", "content\n")
    git("add", "committed.txt")
    git("commit", "--quiet", "-m", "a real commit")

    assert_equal "commit", @shadow.sweep!
    row = @shadow.entries(limit: 1).first
    assert_equal "git", row[:source]
    assert_equal "a real commit", row[:subject]
    assert_includes @shadow.stat(row[:sha])[:files].map { |f| f[:path] }, "committed.txt"
  end

  # Hand editing is continuous; one row per sweep would bury the prompt
  # history under repeated "manual edits" every time the browser refreshed.
  def test_consecutive_manual_edits_collapse_into_one_row
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    write("one.txt", "first\n")
    @shadow.sweep!
    before = @shadow.entries(limit: 10).size

    write("two.txt", "second\n")
    assert_equal "manual", @shadow.sweep!

    assert_equal before, @shadow.entries(limit: 10).size, "should amend, not stack"
    paths = @shadow.stat(@shadow.entries(limit: 1).first[:sha])[:files].map { |f| f[:path] }
    assert_includes paths, "one.txt"
    assert_includes paths, "two.txt"
  end

  # ...but a prompt in between separates them, so agent work is never folded
  # into a manual row.
  def test_a_prompt_separates_manual_rows
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    write("one.txt", "first\n")
    @shadow.sweep!
    @shadow.snap!(message: "an agent prompt", meta: { agent: "claude" })
    write("two.txt", "second\n")
    @shadow.sweep!

    kinds = @shadow.entries(limit: 3).map { |e| e[:kind] }
    assert_equal "manual", kinds[0]
    assert_nil kinds[1]
  end

  # The bug this prevents: opening the browser while an agent was mid-turn
  # captured that agent's in-progress edits as "manual edits" by you, and stole
  # the diff from the prompt row that should have carried it.
  def test_sweep_leaves_in_flight_agent_edits_alone
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    File.write(AgentDiff::Project.inflight_path(@work), Time.now.to_i.to_s)
    write("agent_wrote.txt", "mid turn\n")

    assert_nil @shadow.sweep!, "should not claim an agent's in-progress work"
  end

  # A crashed agent never fires Stop, so the marker must not wedge the project
  # as "an agent owns this" forever.
  def test_a_stale_in_flight_marker_is_ignored
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    path = AgentDiff::Project.inflight_path(@work)
    File.write(path, "1")
    File.utime(Time.now - 3600, Time.now - 3600, path)
    write("hand.txt", "mine\n")

    assert_equal "manual", @shadow.sweep!
  end

  def test_sweep_is_a_noop_when_nothing_happened
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })
    before = @shadow.entries(limit: 10).size

    assert_nil @shadow.sweep!
    assert_equal before, @shadow.entries(limit: 10).size
  end

  # A prompt's label should say what the prompt was about. Taking only the
  # first line lost that whenever a prompt opened with a short sentence and
  # continued underneath -- which pasted blocks and images make common.
  def test_subject_spans_more_than_the_first_line
    @shadow.snap!(
      message: "force perch into reach and grab\n\nalso [Pasted text #4 +29 lines]\n\n" \
               "the inputs disappear from the view",
      meta: {}
    )
    subject = @shadow.entries(limit: 1).first[:subject]

    assert_includes subject, "force perch"
    assert_includes subject, "inputs disappear"
    refute_includes subject, "Pasted text", "attachment markers are noise in a label"
  end

  def test_subject_falls_back_when_there_is_no_prose
    @shadow.snap!(message: "[Image #1]", meta: {})
    assert_equal "[Image #1]", @shadow.entries(limit: 1).first[:subject]
  end

  # Block-level detail: which def/class changed, and where to jump to.
  # The symbol comes from git's own xfuncname patterns rather than from
  # parsing source here.
  def test_hunks_report_the_enclosing_symbol_and_line
    write("lib.rb", <<~RUBY)
      class Thing
        def alpha
          1
        end

        def beta
          2
        end
      end
    RUBY
    git("add", "-A")
    git("commit", "--quiet", "-m", "base")
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })

    write("lib.rb", <<~RUBY)
      class Thing
        def alpha
          1
        end

        def beta
          2
          22
        end
      end
    RUBY
    sha = @shadow.snap!(message: "touch beta", meta: {})

    hunks = @shadow.hunks(sha, "lib.rb")
    assert_equal 1, hunks.size
    assert_includes hunks.first[:symbol], "beta"
    assert_operator hunks.first[:line], :>, 0
    assert_equal 1, hunks.first[:added]
  end

  # -U0 splits one method edited in several places into several hunks. They
  # are not several methods, so they collapse to one row whose line points at
  # the `def` itself rather than at whichever edit happened to come first.
  def test_hunks_in_one_method_merge_into_a_single_row
    write("m.py", <<~PY)
      class Thing:
          def live_view(self):
              a = 1
              b = 2
              c = 3
              return a
    PY
    git("add", "-A")
    git("commit", "--quiet", "-m", "base")
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })

    write("m.py", <<~PY)
      class Thing:
          def live_view(self):
              a = 11
              b = 2
              c = 33
              d = 4
              return a
    PY
    sha = @shadow.snap!(message: "three edits, one method", meta: {})

    hunks = @shadow.hunks(sha, "m.py")
    assert_equal 1, hunks.size, "three hunks in one def collapse to one row"
    assert_includes hunks.first[:symbol], "live_view"
    assert_equal 2, hunks.first[:line], "points at the def, not the first edit"
    assert_equal 3, hunks.first[:added]
    assert_equal 2, hunks.first[:deleted]
  end

  # Same-named methods in different classes are genuinely different symbols.
  # Only consecutive runs merge, so the other class's `__init__` breaks the
  # run and stays its own row.
  def test_same_name_methods_in_different_classes_stay_separate
    write("c.py", <<~PY)
      class A:
          def __init__(self):
              self.a = 1


      class B:
          def __init__(self):
              self.z = 9
    PY
    git("add", "-A")
    git("commit", "--quiet", "-m", "base")
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })

    write("c.py", <<~PY)
      class A:
          def __init__(self):
              self.a = 111


      class B:
          def __init__(self):
              self.z = 99
    PY
    sha = @shadow.snap!(message: "both inits", meta: {})

    hunks = @shadow.hunks(sha, "c.py")
    assert_equal 2, hunks.size, "two classes' __init__ do not merge"
    assert_equal [2, 7], hunks.map { |h| h[:line] }, "each points at its own def"
  end

  # Git quotes the declaration as it read BEFORE the change, so once a hunk
  # has edited a signature the header text no longer matches the file being
  # searched. Matching on the cleaned symbol (arguments dropped) still finds
  # the def, so later hunks inside it merge instead of splitting one per hunk.
  def test_hunks_merge_after_their_signature_changed
    write("s.rb", <<~RUBY)
      class Thing
        def parse(raw)
          a = 1
          b = 2
          c = 3
          d = 4
          raw
        end
      end
    RUBY
    git("add", "-A")
    git("commit", "--quiet", "-m", "base")
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })

    # The signature gains an argument AND two separate lines in the body
    # change, so the body hunks must still resolve back to the new `def`.
    write("s.rb", <<~RUBY)
      class Thing
        def parse(raw, &blob)
          a = 11
          b = 2
          c = 33
          d = 4
          raw
        end
      end
    RUBY
    sha = @shadow.snap!(message: "signature plus body", meta: {})

    hunks = @shadow.hunks(sha, "s.rb")
    inside = hunks.select { |h| h[:symbol].to_s.include?("parse") }
    assert_equal 1, inside.size, "both body hunks collapse onto the renamed def"
    assert_equal 2, inside.first[:line], "and point at the def itself"
  end

  # Changes outside any def have no declaration to point at, so they keep the
  # changed line and stay separate rows.
  def test_top_level_changes_keep_their_own_lines
    write("t.py", <<~PY)
      X = 1
      Y = 2
      Z = 3
    PY
    git("add", "-A")
    git("commit", "--quiet", "-m", "base")
    @shadow.snap!(message: "baseline", meta: { head: @shadow.real_head[:head] })

    write("t.py", <<~PY)
      X = 11
      Y = 2
      Z = 33
    PY
    sha = @shadow.snap!(message: "two top-level edits", meta: {})

    hunks = @shadow.hunks(sha, "t.py")
    assert_equal 2, hunks.size, "unnamed hunks do not merge together"
    assert_nil hunks.first[:symbol]
  end

  # A pathspec is resolved relative to the process's directory, so running
  # from inside the project matched nothing and every file looked unchanged.
  def test_hunks_work_regardless_of_the_current_directory
    write("x.rb", "def a\n  1\nend\n")
    @shadow.snap!(message: "baseline", meta: {})
    write("x.rb", "def a\n  1\n  2\nend\n")
    sha = @shadow.snap!(message: "edit", meta: {})

    Dir.chdir(@work) { assert_equal 1, @shadow.hunks(sha, "x.rb").size }
  end

  def test_honors_project_gitignore
    write(".gitignore", "ignored/\n")
    write("ignored/junk.txt", "noise\n")
    sha = @shadow.snap!(message: "with ignore")

    paths = @shadow.stat(sha)[:files].map { |f| f[:path] }
    refute_includes paths, "ignored/junk.txt"
  end

  # An agent committing mid-turn moves HEAD but is not a checkout; the row
  # must keep its diff rather than be hidden as a branch change.
  def test_commits_are_not_a_checkout
    from = git("rev-parse", "HEAD").strip
    write("a.txt", "one\ntwo\n")
    git("commit", "--quiet", "-am", "agent commit")
    git("commit", "--quiet", "--amend", "-m", "agent commit, amended")
    refute @shadow.head_moved_by_checkout?(from, git("rev-parse", "HEAD").strip)
  end

  def test_checkout_is_a_checkout
    from = git("rev-parse", "HEAD").strip
    git("checkout", "--quiet", "-b", "other")
    write("a.txt", "other\n")
    git("commit", "--quiet", "-am", "on other")
    git("checkout", "--quiet", "-")
    git("merge", "--quiet", "other")
    assert @shadow.head_moved_by_checkout?(from, git("rev-parse", "HEAD").strip)
  end

  def test_unknown_previous_head_is_a_checkout
    assert @shadow.head_moved_by_checkout?("0" * 40, git("rev-parse", "HEAD").strip)
  end
end
