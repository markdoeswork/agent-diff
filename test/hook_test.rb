# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "agent_diff/claude_hook"

# Which agent a hook payload is labelled with. Codex shares Claude Code's
# event names, so the label can't come from the event alone.
class HookTest < Minitest::Test
  Hook = AgentDiff::ClaudeHook

  def setup
    @saved = ENV.to_h.slice("AGENT_DIFF_AGENT", "CODEX_HOME")
    ENV.delete("AGENT_DIFF_AGENT")
    ENV.delete("CODEX_HOME")
  end

  def teardown
    %w[AGENT_DIFF_AGENT CODEX_HOME].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  def test_claude_events_are_claude
    payload = { "hook_event_name" => "Stop",
                "transcript_path" => "/home/u/.claude/projects/-x/abc.jsonl" }
    assert_equal "claude", Hook.agent_name(payload)
  end

  def test_cursor_events_are_cursor
    assert_equal "cursor", Hook.agent_name({ "hook_event_name" => "stop" })
  end

  def test_the_installed_codex_hook_names_itself
    ENV["AGENT_DIFF_AGENT"] = "codex"
    assert_equal "codex", Hook.agent_name({ "hook_event_name" => "Stop" })
  end

  def test_codex_is_recognised_by_its_transcript_path
    payload = { "hook_event_name" => "Stop",
                "transcript_path" => "/home/u/.codex/sessions/2026/10/09/rollout-1.jsonl" }
    assert_equal "codex", Hook.agent_name(payload)

    ENV["CODEX_HOME"] = "/opt/codex"
    payload["transcript_path"] = "/opt/codex/sessions/rollout-1.jsonl"
    assert_equal "codex", Hook.agent_name(payload)
  end

  def test_codex_prompt_and_session_are_read_like_claudes
    payload = { "hook_event_name" => "UserPromptSubmit", "session_id" => "01a1", "prompt" => "hi",
                "cwd" => "/w" }
    assert Hook.cache_event?(payload["hook_event_name"])
    assert_equal "01a1", Hook.session_id(payload)
    assert_equal "/w", Hook.cwd(payload)
  end
end
