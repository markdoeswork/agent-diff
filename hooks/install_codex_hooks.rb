#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge agent-diff into ~/.codex/hooks.json without touching other hooks.
# Codex takes Claude Code's hook format and event names: UserPromptSubmit
# caches the prompt text; Stop records the snapshot. The command sets
# AGENT_DIFF_AGENT so the payloads, which look like Claude's, are labelled
# codex.
#
# Codex runs a new or changed hook only after you trust it, so the first
# Codex session after installing asks you to review these two.
#
# Safe to re-run. An existing agent-diff entry is replaced rather than kept,
# so moving the checkout and re-running points the hooks at the new path.
#
#   ruby hooks/install_codex_hooks.rb              install / update
#   ruby hooks/install_codex_hooks.rb --uninstall  remove

require "json"
require "fileutils"

CODEX = File.expand_path(ENV.fetch("CODEX_HOME", "~/.codex"))
HOOKS_JSON = File.join(CODEX, "hooks.json")
SCRIPT = File.expand_path("agent_diff.sh", __dir__)
EVENTS = %w[UserPromptSubmit Stop].freeze
ENTRY = {
  "hooks" => [{ "type" => "command", "command" => "AGENT_DIFF_AGENT=codex bash '#{SCRIPT}'",
                "timeout" => 30 }]
}.freeze
UNINSTALL = ARGV.include?("--uninstall")

def load_config
  return {} unless File.exist?(HOOKS_JSON)

  JSON.parse(File.read(HOOKS_JSON))
rescue JSON::ParserError
  warn "install_codex_hooks: #{HOOKS_JSON} is not valid JSON; leaving it alone"
  exit 1
end

def ours?(group)
  Array(group["hooks"]).any? do |h|
    cmd = h["command"].to_s
    cmd.include?("agent_diff") || cmd.include?("agent-diff")
  end
end

data = load_config
data["hooks"] ||= {}
before = JSON.generate(data)

EVENTS.each do |event|
  groups = Array(data["hooks"][event]).reject { |g| ours?(g) }
  groups << JSON.parse(JSON.generate(ENTRY)) unless UNINSTALL
  if groups.empty?
    data["hooks"].delete(event)
  else
    data["hooks"][event] = groups
  end
end

if JSON.generate(data) == before
  puts "  #{HOOKS_JSON}: already up to date"
else
  FileUtils.mkdir_p(File.dirname(HOOKS_JSON))
  File.write(HOOKS_JSON, "#{JSON.pretty_generate(data)}\n")
  puts "  #{HOOKS_JSON}: #{UNINSTALL ? "removed" : "installed"} #{EVENTS.join(" + ")}"
  puts "  (Codex asks you to trust new hooks the next time it starts)" unless UNINSTALL
end
