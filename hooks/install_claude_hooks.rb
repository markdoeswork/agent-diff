#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge agent-diff into ~/.claude/settings.json without touching other hooks.
# UserPromptSubmit caches the prompt text; Stop records the snapshot.
#
# Safe to re-run. An existing agent-diff entry is replaced rather than kept,
# so moving the checkout and re-running points the hooks at the new path.
#
#   ruby hooks/install_claude_hooks.rb              install / update
#   ruby hooks/install_claude_hooks.rb --uninstall  remove

require "json"
require "fileutils"

SETTINGS = File.expand_path(ENV.fetch("CLAUDE_SETTINGS", "~/.claude/settings.json"))
SCRIPT = File.expand_path("agent_diff.sh", __dir__)
EVENTS = %w[UserPromptSubmit Stop].freeze
ENTRY = {
  "hooks" => [{ "type" => "command", "command" => "bash '#{SCRIPT}'", "timeout" => 30 }]
}.freeze
UNINSTALL = ARGV.include?("--uninstall")

def load_settings
  return {} unless File.exist?(SETTINGS)

  JSON.parse(File.read(SETTINGS))
rescue JSON::ParserError
  warn "install_claude_hooks: #{SETTINGS} is not valid JSON; leaving it alone"
  exit 1
end

def ours?(group)
  Array(group["hooks"]).any? do |h|
    cmd = h["command"].to_s
    cmd.include?("agent_diff") || cmd.include?("agent-diff")
  end
end

data = load_settings
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
  puts "  #{SETTINGS}: already up to date"
else
  FileUtils.mkdir_p(File.dirname(SETTINGS))
  File.write(SETTINGS, "#{JSON.pretty_generate(data)}\n")
  puts "  #{SETTINGS}: #{UNINSTALL ? "removed" : "installed"} #{EVENTS.join(" + ")}"
end
