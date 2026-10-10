# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/project"
require "agent_diff/claude_hook"
require "agent_diff/cli"
require "agent_diff/format"
require "agent_diff/shadow"

class ProjectTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("agent_diff_project")
    ENV["AGENT_DIFF_HOME"] = File.join(@tmp, "home")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete("AGENT_DIFF_HOME")
  end

  def test_resolves_to_enclosing_git_root
    work = File.join(@tmp, "repo")
    nested = File.join(work, "deep", "nested")
    FileUtils.mkdir_p(nested)
    Open3.capture3("git", "-C", work, "init", "--quiet")

    assert_equal File.realpath(work), File.realpath(AgentDiff::Project.root_for(nested))
  end

  def test_falls_back_to_directory_when_not_a_repo
    plain = File.join(@tmp, "plain")
    FileUtils.mkdir_p(plain)
    assert_equal File.realpath(plain), AgentDiff::Project.root_for(plain)
  end

  # Same-named checkouts in different places must not collide.
  def test_shadow_paths_are_unique_per_path
    a = AgentDiff::Project.shadow_dir("/home/x/proj")
    b = AgentDiff::Project.shadow_dir("/work/y/proj")
    refute_equal a, b
    assert_includes a, "proj-"
  end

  def test_shadow_path_is_stable
    assert_equal AgentDiff::Project.shadow_dir("/home/x/p"),
                 AgentDiff::Project.shadow_dir("/home/x/p")
  end

  def test_symlinked_and_real_paths_share_a_shadow
    work = File.join(@tmp, "repo")
    FileUtils.mkdir_p(work)
    Open3.capture3("git", "-C", work, "init", "--quiet")
    real = File.realpath(work)
    skip "paths already match" if real == work

    assert_equal AgentDiff::Project.shadow_dir(real),
                 AgentDiff::Project.shadow_dir(work)
  end
end

class ClaudeHookTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("agent_diff_hook")
    ENV["AGENT_DIFF_HOME"] = @tmp
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete("AGENT_DIFF_HOME")
  end

  def test_malformed_payloads_never_raise
    ["not json", "", "   ", "[1,2,3]"].each do |raw|
      assert_kind_of Object, AgentDiff::ClaudeHook.read(StringIO.new(raw))
    end
  end

  def test_prompt_round_trips_between_events
    submit = { "hook_event_name" => "UserPromptSubmit", "session_id" => "s1",
               "user_input" => "make the pane wider" }
    AgentDiff::ClaudeHook.remember_prompt(submit)

    assert_equal "make the pane wider",
                 AgentDiff::ClaudeHook.recall_prompt({ "session_id" => "s1" })
  end

  def test_missing_prompt_recalls_nil
    assert_nil AgentDiff::ClaudeHook.recall_prompt({ "session_id" => "never-seen" })
  end

  # Session ids reach the filesystem as names; they must not escape the dir.
  def test_session_id_is_sanitised
    path = AgentDiff::ClaudeHook.cache_path("../../etc/passwd")
    refute_includes File.basename(path), "/"
  end

  def test_meta_uses_herdr_pane_from_env
    ENV["HERDR_PANE_ID"] = "wD:p8"
    meta = AgentDiff::ClaudeHook.meta({ "session_id" => "s1" }, "hi")
    assert_equal "wD:p8", meta[:pane]
    assert_equal "claude", meta[:agent]
  ensure
    ENV.delete("HERDR_PANE_ID")
  end

  def test_cursor_prompt_round_trips_on_conversation_id
    submit = { "hook_event_name" => "beforeSubmitPrompt",
               "conversation_id" => "conv-1",
               "prompt" => "make cursor record diffs",
               "workspace_roots" => ["/tmp/proj"] }
    AgentDiff::ClaudeHook.remember_prompt(submit)

    assert_equal "make cursor record diffs",
                 AgentDiff::ClaudeHook.recall_prompt("conversation_id" => "conv-1")
  end

  def test_cwd_prefers_workspace_roots
    payload = { "workspace_roots" => ["/work/nitro-web"] }
    assert_equal "/work/nitro-web", AgentDiff::ClaudeHook.cwd(payload)
  end

  def test_only_submit_and_stop_are_hook_events
    assert AgentDiff::ClaudeHook.cache_event?("beforeSubmitPrompt")
    assert AgentDiff::ClaudeHook.cache_event?("UserPromptSubmit")
    assert AgentDiff::ClaudeHook.snap_event?("stop")
    assert AgentDiff::ClaudeHook.snap_event?("Stop")
    refute AgentDiff::ClaudeHook.snap_event?("sessionStart")
    refute AgentDiff::ClaudeHook.cache_event?("afterFileEdit")
  end

  def test_cursor_events_label_agent_cursor
    ENV.delete("AGENT_DIFF_AGENT")
    ENV.delete("HERDR_PANE_ID")
    meta = AgentDiff::ClaudeHook.meta({ "hook_event_name" => "stop",
                                        "conversation_id" => "c1" }, "hi")
    assert_equal "cursor", meta[:agent]
    assert_equal "c1", meta[:session]
  end
end

class HookCommandTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("agent_diff_cmd_hook")
    ENV["AGENT_DIFF_HOME"] = File.join(@tmp, "home")
    ENV.delete("HERDR_PANE_ID")
    ENV.delete("AGENT_DIFF_AGENT")
    @work = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@work)
    Open3.capture3("git", "-C", @work, "init", "--quiet")
    File.write(File.join(@work, "a.txt"), "one\n")
    Open3.capture3("git", "-C", @work, "add", ".")
    Open3.capture3("git", "-C", @work, "commit", "-m", "init", "--quiet")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    ENV.delete("AGENT_DIFF_HOME")
  end

  def run_hook(payload)
    previous = $stdin
    $stdin = StringIO.new(JSON.generate(payload))
    AgentDiff::CLI.new.send(:cmd_hook, {})
  ensure
    $stdin = previous
  end

  def test_unrelated_cursor_events_do_not_touch_the_shadow
    run_hook("hook_event_name" => "sessionStart", "workspace_roots" => [@work])
    refute AgentDiff::Project.initialized?(@work)
  end

  def test_cursor_submit_then_stop_records_the_prompt
    run_hook("hook_event_name" => "beforeSubmitPrompt",
             "conversation_id" => "c9",
             "prompt" => "edit a.txt",
             "workspace_roots" => [@work])
    File.write(File.join(@work, "a.txt"), "two\n")
    run_hook("hook_event_name" => "stop",
             "conversation_id" => "c9",
             "status" => "completed",
             "workspace_roots" => [@work])

    entries = AgentDiff::Shadow.new(@work).entries
    assert_equal ["edit a.txt"], entries.map { |e| e[:subject] }
    assert_equal "cursor", entries.first[:agent]
  end

  # A repo with no files yet: git refuses to commit an empty tree, so the
  # baseline failed and the first prompt's new file was swallowed into it.
  def test_first_prompt_in_an_empty_repo_is_recorded
    empty = File.join(@tmp, "empty")
    FileUtils.mkdir_p(empty)
    Open3.capture3("git", "-C", empty, "init", "--quiet")
    run_hook("hook_event_name" => "UserPromptSubmit", "session_id" => "s1",
             "prompt" => "make a file", "cwd" => empty)
    File.write(File.join(empty, "new.txt"), "hi\n")
    run_hook("hook_event_name" => "Stop", "session_id" => "s1", "cwd" => empty)

    shadow = AgentDiff::Shadow.new(empty)
    entry = shadow.entries.first
    assert_equal "make a file", entry[:subject]
    assert_equal ["new.txt"], shadow.stat(entry[:sha])[:files].map { |f| f[:path] }
  end
end

class FormatTest < Minitest::Test
  def test_age_is_human_readable
    now = Time.now
    assert_equal "now", AgentDiff::Format.age(now, now)
    assert_equal "30s", AgentDiff::Format.age(now - 30, now)
    assert_equal "5m", AgentDiff::Format.age(now - 300, now)
    assert_equal "2h", AgentDiff::Format.age(now - 7200, now)
    assert_equal "3d", AgentDiff::Format.age(now - 259_200, now)
  end

  def test_truncate_respects_width
    assert_equal "abc", AgentDiff::Format.truncate("abc", 10)
    assert_equal 5, AgentDiff::Format.truncate("abcdefghij", 5).length
  end

  # Piped output must stay free of escape codes.
  def test_no_colour_when_not_a_tty
    refute AgentDiff::Format.color?(StringIO.new)
    assert_equal "plain", AgentDiff::Format.paint("plain", 32, StringIO.new)
  end
end
