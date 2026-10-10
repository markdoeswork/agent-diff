#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge agent-diff into ~/.cursor/hooks.json without touching other hooks.
# User-level, so every Cursor workspace (IDE and CLI) records prompts.
#
# Cursor runs hook commands relative to ~/.cursor, so the entry points at
# ~/.cursor/hooks/agent-diff.sh, a symlink to this checkout's adapter.
# Re-running re-points the symlink, so a moved checkout keeps working.
#
#   ruby hooks/install_cursor_hooks.rb              install / update
#   ruby hooks/install_cursor_hooks.rb --uninstall  remove

require "json"
require "fileutils"

CURSOR = File.expand_path(ENV.fetch("CURSOR_HOME", "~/.cursor"))
HOOKS_JSON = File.join(CURSOR, "hooks.json")
LINK = File.join(CURSOR, "hooks", "agent-diff.sh")
SCRIPT = File.expand_path("agent_diff.sh", __dir__)
COMMAND = "./hooks/agent-diff.sh"
EVENTS = %w[beforeSubmitPrompt stop].freeze
ENTRY = { "command" => COMMAND, "timeout" => 120, "failClosed" => false }.freeze
UNINSTALL = ARGV.include?("--uninstall")

def load_config
  return { "version" => 1, "hooks" => {} } unless File.exist?(HOOKS_JSON)

  JSON.parse(File.read(HOOKS_JSON))
rescue JSON::ParserError
  warn "install_cursor_hooks: #{HOOKS_JSON} is not valid JSON; leaving it alone"
  exit 1
end

def ours?(hook)
  cmd = hook["command"].to_s
  cmd.include?("agent-diff") || cmd.include?("agent_diff")
end

data = load_config
data["version"] ||= 1
data["hooks"] ||= {}
before = JSON.generate(data)

EVENTS.each do |event|
  hooks = Array(data["hooks"][event]).map { |h| h.is_a?(Hash) ? h : { "command" => h.to_s } }
  hooks = hooks.reject { |h| ours?(h) }
  hooks << ENTRY.dup unless UNINSTALL
  if hooks.empty?
    data["hooks"].delete(event)
  else
    data["hooks"][event] = hooks
  end
end

if UNINSTALL
  File.delete(LINK) if File.symlink?(LINK)
else
  FileUtils.mkdir_p(File.dirname(LINK))
  FileUtils.ln_sf(SCRIPT, LINK)
end

if JSON.generate(data) == before
  puts "  #{HOOKS_JSON}: already up to date"
else
  FileUtils.mkdir_p(File.dirname(HOOKS_JSON))
  File.write(HOOKS_JSON, "#{JSON.pretty_generate(data)}\n")
  puts "  #{HOOKS_JSON}: #{UNINSTALL ? "removed" : "installed"} #{EVENTS.join(" + ")}"
end
