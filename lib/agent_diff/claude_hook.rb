# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "project"

module AgentDiff
  # Reads a vendor hook payload from stdin and maps it onto one remember/snap
  # pair. Claude Code and Codex use UserPromptSubmit + Stop; Cursor uses
  # beforeSubmitPrompt + stop. All cache the prompt on submit because the
  # stop event does not carry it.
  #
  # Stop fires when a turn ends, so by the time this runs the turn's file
  # changes are complete. If the cache is missing we still record the
  # snapshot, just with a timestamp for a label -- a diff with a weak label
  # beats no diff.
  module ClaudeHook
    CACHE_EVENTS = %w[UserPromptSubmit beforeSubmitPrompt].freeze
    SNAP_EVENTS = %w[Stop stop].freeze

    module_function

    def read(io = $stdin)
      raw = begin
        io.read
      rescue StandardError
        nil
      end
      return {} if raw.nil? || raw.strip.empty?

      parsed = JSON.parse(raw.sub(/\A\uFEFF/, ""))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def cache_event?(event)
      CACHE_EVENTS.include?(event.to_s)
    end

    def snap_event?(event)
      SNAP_EVENTS.include?(event.to_s)
    end

    def session_id(payload)
      payload["session_id"] || payload["conversation_id"]
    end

    def cwd(payload)
      explicit = payload["cwd"].to_s
      return explicit unless explicit.empty?

      roots = payload["workspace_roots"]
      first = roots.is_a?(Array) ? roots.find { |r| r.to_s.strip != "" } : nil
      first.to_s.empty? ? Dir.pwd : first.to_s
    end

    def cache_path(session_id)
      dir = File.join(Project.home, "prompts")
      FileUtils.mkdir_p(dir)
      File.join(dir, "#{session_id.to_s.gsub(/[^A-Za-z0-9_-]/, "_")}.txt")
    end

    def remember_prompt(payload)
      text = payload["user_input"] || payload["prompt"]
      session = session_id(payload)
      return if text.nil? || text.to_s.strip.empty? || session.nil?

      File.write(cache_path(session), text.to_s)
    end

    def recall_prompt(payload)
      session = session_id(payload)
      return nil if session.nil?

      path = cache_path(session)
      File.exist?(path) ? File.read(path) : nil
    end

    def agent_name(payload)
      return ENV["AGENT_DIFF_AGENT"] if ENV["AGENT_DIFF_AGENT"] && !ENV["AGENT_DIFF_AGENT"].empty?

      event = payload["hook_event_name"].to_s
      return "cursor" if %w[beforeSubmitPrompt stop afterAgentResponse].include?(event)
      # Codex reuses Claude's event names. Its installed hook sets
      # AGENT_DIFF_AGENT; failing that, its transcripts live under ~/.codex.
      return "codex" if codex_payload?(payload)
      return "claude" if %w[UserPromptSubmit Stop].include?(event)

      "claude"
    end

    def codex_payload?(payload)
      path = payload["transcript_path"].to_s
      codex_home = ENV["CODEX_HOME"].to_s
      path.include?("/.codex/") || (!codex_home.empty? && path.start_with?(codex_home))
    end

    # The herdr pane the agent ran in, when there is one. Recorded only as a
    # label -- the viewer never looks panes up.
    def pane_id(_payload)
      env = ENV["HERDR_PANE_ID"]
      env.nil? || env.empty? ? nil : env
    end

    def meta(payload, prompt)
      {
        prompt: prompt,
        pane: pane_id(payload),
        session: session_id(payload),
        agent: agent_name(payload)
      }
    end
  end

  Hook = ClaudeHook
end
