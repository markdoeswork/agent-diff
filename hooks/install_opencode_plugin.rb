#!/usr/bin/env ruby
# frozen_string_literal: true

# Install the agent-diff plugin into OpenCode's global plugin directory,
# ~/.config/opencode/plugin/agent-diff.js. OpenCode loads every .js/.ts file
# there at startup, so no config file is edited.
#
# The plugin is a copy with this checkout's hook path written in, so
# re-running after moving the checkout re-points it.
#
#   ruby hooks/install_opencode_plugin.rb              install / update
#   ruby hooks/install_opencode_plugin.rb --uninstall  remove

require "fileutils"
require "json"

CONFIG = File.expand_path(
  ENV["OPENCODE_CONFIG_DIR"] || File.join(ENV["XDG_CONFIG_HOME"] || "~/.config", "opencode")
)
TARGET = File.join(CONFIG, "plugin", "agent-diff.js")
TEMPLATE = File.expand_path("opencode_plugin.js", __dir__)
SCRIPT = File.expand_path("agent_diff.sh", __dir__)
UNINSTALL = ARGV.include?("--uninstall")

if UNINSTALL
  if File.exist?(TARGET)
    File.delete(TARGET)
    puts "  #{TARGET}: removed"
  end
  exit 0
end

body = File.read(TEMPLATE).sub('const HOOK = "__AGENT_DIFF_HOOK__"') { "const HOOK = #{SCRIPT.to_json}" }
if File.exist?(TARGET) && File.read(TARGET) == body
  puts "  #{TARGET}: already up to date"
else
  FileUtils.mkdir_p(File.dirname(TARGET))
  File.write(TARGET, body)
  puts "  #{TARGET}: installed (restart OpenCode to load it)"
end
