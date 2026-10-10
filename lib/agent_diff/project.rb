# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

module AgentDiff
  # Maps a working directory to its project root and that project's shadow repo.
  #
  # Shadow repos live outside the project entirely (default
  # ~/.local/share/agent_diff/repos) so nothing is ever written into the tree
  # being watched. The directory name is "<basename>-<hash of real path>" so it
  # is recognizable by eye but still unique across same-named checkouts.
  module Project
    module_function

    def home
      File.expand_path(ENV["AGENT_DIFF_HOME"] || "~/.local/share/agent_diff")
    end

    # macOS hides /var behind /private/var; git show-toplevel returns the
    # real path. Hashing the two spellings separately would split one repo
    # into two shadows.
    def canonicalize(dir)
      dir = File.expand_path(dir.to_s)
      File.exist?(dir) ? File.realpath(dir) : dir
    end

    # Nearest enclosing git worktree, falling back to the directory itself so
    # non-git projects still get per-prompt history.
    def root_for(dir)
      dir = canonicalize(dir)
      out, _, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
      return canonicalize(out.strip) if status.success? && !out.strip.empty?

      dir
    end

    def slug(root)
      root = canonicalize(root)
      "#{File.basename(root)}-#{Digest::SHA256.hexdigest(root)[0, 12]}"
    end

    def shadow_dir(root)
      File.join(home, "repos", "#{slug(root)}.git")
    end

    def initialized?(root)
      File.directory?(shadow_dir(root))
    end

    def log_path
      FileUtils.mkdir_p(home)
      File.join(home, "agent_diff.log")
    end

    # Touched after every successful snap so the pane can redraw immediately
    # instead of waiting for its next poll.
    # Marks a project as having an agent turn in flight: written when a prompt
    # is submitted, removed when that turn stops.
    #
    # sweep! consults this so edits an agent is making right now are not
    # attributed to "you". Without it, opening the browser mid-turn captured the
    # agent's own work-in-progress as a manual edit.
    def inflight_path(root)
      dir = File.join(home, "inflight")
      FileUtils.mkdir_p(dir)
      File.join(dir, slug(root))
    end

    # True while an agent turn is running for this project. Stale markers are
    # ignored: a crashed or killed agent never fires Stop, and a project must
    # not be stuck as "an agent owns this" forever.
    def inflight?(root, stale_after: 900)
      path = inflight_path(root)
      return false unless File.exist?(path)

      Time.now - File.mtime(path) < stale_after
    rescue StandardError
      false
    end

    def signal_path(root)
      dir = File.join(home, "signals")
      FileUtils.mkdir_p(dir)
      File.join(dir, slug(root))
    end
  end
end
