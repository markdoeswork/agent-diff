# frozen_string_literal: true

require "shellwords"

module AgentDiff
  # Builds the command that opens a file at a line, in whichever terminal
  # editor this machine has.
  #
  # The choice is AGENT_DIFF_EDITOR, then $VISUAL, then $EDITOR, then the
  # first of FALLBACKS found on PATH. Editors disagree on how to say "at line
  # N": most take `+N file`, helix, micro, zed and Sublime want `file:N`, VS Code
  # wants `-g file:N`. An editor not listed here gets `+N`, the convention
  # vi started and most followers kept.
  module Editor
    FALLBACKS = %w[nvim vim vi nano hx helix micro kak emacs].freeze

    # Editors that take `file:N` rather than `+N file`.
    COLON_STYLE = %w[hx helix micro zed subl].freeze
    # VS Code and its forks: `-g file:N`, and `--wait`, since without it they
    # return at once and the browser would redraw over a still-opening file.
    VSCODE_STYLE = %w[code code-insiders codium cursor].freeze

    module_function

    def command(path, line, env: ENV)
      words = chosen(env)
      return nil unless words

      prog = File.basename(words.first)
      if COLON_STYLE.include?(prog)
        words + ["#{path}:#{line}"]
      elsif VSCODE_STYLE.include?(prog)
        wait = words.include?("--wait") || words.include?("-w") ? [] : ["--wait"]
        words + wait + ["-g", "#{path}:#{line}"]
      else
        words + ["+#{line}", path]
      end
    end

    # The configured editor as argv words, or the first fallback installed.
    def chosen(env = ENV)
      %w[AGENT_DIFF_EDITOR VISUAL EDITOR].each do |var|
        value = env[var].to_s.strip
        return Shellwords.split(value) unless value.empty?
      end
      found = FALLBACKS.find { |name| on_path?(name, env) }
      found && [found]
    end

    def on_path?(name, env = ENV)
      env["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        file = File.join(dir, name)
        File.file?(file) && File.executable?(file)
      end
    end
  end
end
