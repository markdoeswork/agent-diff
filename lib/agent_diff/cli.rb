#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "open3"
require "shellwords"

require_relative "project"
require_relative "shadow"
require_relative "format"
require_relative "claude_hook"

module AgentDiff
  # Subcommand dispatch. Every command takes an optional path; it defaults to
  # the working directory and resolves up to the enclosing git root.
  class CLI
    USAGE = <<~TEXT
      agent-diff — per-prompt diffs for multi-agent coding sessions

      usage: agent-diff                       browse repos, sessions, prompts
             agent-diff <command> [options] [path]

      commands:
        init [path]              create the shadow repo for a project
        snap [path]              record a snapshot now (-m to label it)
        list [path]              recent prompts and what they changed
        show <ref> [path]        one prompt in detail (--patch for the diff)
        status [path]            work done since the last snapshot
        diffcmd <ref> [path]     print the git command to diff that prompt
        hook                     read an agent hook payload on stdin
        paths [path]             where this project's shadow repo lives

      common options:
        -n, --limit N            how many prompts to show (default 10)
            --pane ID            only prompts recorded from this pane ($HERDR_PANE_ID)
            --json               machine-readable output
        -m, --message TEXT       label for snap
    TEXT

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      command = argv.shift
      return cmd_browse if command.nil? || command == "ui"
      return usage(0) if %w[-h --help help].include?(command)

      opts = parse(argv)
      case command
      when "init"    then cmd_init(opts)
      when "snap"    then cmd_snap(opts)
      when "list"    then cmd_list(opts)
      when "show"    then cmd_show(opts)
      when "status"  then cmd_status(opts)
      when "diffcmd" then cmd_diffcmd(opts)
      when "hook"    then cmd_hook(opts)
      when "paths"   then cmd_paths(opts)
      else
        warn "agent-diff: unknown command #{command.inspect}"
        usage(2)
      end
    rescue Interrupt
      0
    rescue StandardError => e
      warn "agent-diff: #{e.message}"
      1
    end

    def usage(code)
      puts USAGE
      code
    end

    def parse(argv)
      opts = { limit: 10, json: false, files: true }
      parser = OptionParser.new do |o|
        o.on("-nN", "--limit N", Integer) { |v| opts[:limit] = v }
        o.on("--pane ID") { |v| opts[:pane] = v }
        o.on("--json") { opts[:json] = true }
        o.on("--patch") { opts[:patch] = true }
        o.on("--no-files") { opts[:files] = false }
        o.on("-mTEXT", "--message TEXT") { |v| opts[:message] = v }
        o.on("--kind KIND") { |v| opts[:kind] = v }
      end
      opts[:rest] = parser.parse(argv)
      opts
    end

    # `show`/`diffcmd` take a ref before the optional path; everything else
    # treats the first bare argument as the path.
    def target(opts, expect_ref: false)
      rest = opts[:rest].dup
      ref = expect_ref ? rest.shift : nil
      root = Project.root_for(rest.shift || Dir.pwd)
      [root, ref]
    end

    def cmd_init(opts)
      root, = target(opts)
      shadow = Shadow.new(root).init!
      seed(shadow)
      puts "shadow repo: #{shadow.git_dir}"
      puts "watching:    #{root}"
      0
    end

    # The first snapshot is a baseline, not a prompt -- otherwise an existing
    # dirty tree would be reported as one enormous change.
    def seed(shadow)
      return unless shadow.empty?

      # allow_empty: a brand-new repo has no files yet, and without a baseline
      # commit the first prompt's work would be swallowed into it.
      shadow.snap!(message: "baseline", meta: { kind: "seed" }.merge(shadow.real_head),
                   allow_empty: true)
    end

    def cmd_snap(opts)
      root, = target(opts)
      shadow = Shadow.new(root)
      shadow.init!
      seed(shadow)
      meta = { pane: opts[:pane] || ENV["HERDR_PANE_ID"], kind: opts[:kind] }
      sha = record(shadow, opts[:message] || "manual snapshot", meta)
      if sha
        puts sha[0, 7]
        0
      else
        puts "no changes"
        0
      end
    end

    # Detects a real-repo checkout between prompts: the diff then reflects a
    # branch switch rather than anything an agent typed, and should be labelled
    # as such instead of reported as a huge prompt. Commits made during the
    # turn also move HEAD but leave the diff intact, so they do not count.
    def record(shadow, message, meta)
      head = shadow.real_head
      previous = shadow.entries(limit: 1).first
      kind = meta[:kind]
      if kind.nil? && previous && shadow.head_moved_by_checkout?(previous[:head], head[:head])
        kind = "branch-change"
      end
      shadow.snap!(message: message, meta: meta.merge(head).merge(kind: kind))
    end

    def cmd_list(opts)
      root, = target(opts)
      shadow = Shadow.new(root)
      unless shadow.initialized?
        warn "agent-diff: not initialised for #{root} (run: agent-diff init)"
        return 1
      end

      shadow.sweep!
      entries = shadow.entries(limit: opts[:limit], pane: opts[:pane])
      rows = entries.map { |e| [e, shadow.stat(e[:sha])] }
      return emit_json(rows) if opts[:json]

      if rows.empty?
        puts Format.dim("no prompts recorded yet")
        return 0
      end

      rows.each_with_index do |(entry, stat), i|
        puts "" unless i.zero?
        puts Format.entry(entry, stat, show_files: opts[:files], width: width)
      end
      0
    end

    def emit_json(rows)
      payload = rows.map do |entry, stat|
        entry.merge(time: entry[:time].iso8601, age: Format.age(entry[:time]),
                    files: stat[:files], added: stat[:added], deleted: stat[:deleted])
      end
      puts JSON.pretty_generate(payload)
      0
    end

    def cmd_show(opts)
      root, ref = target(opts, expect_ref: true)
      return usage(2) unless ref

      shadow = Shadow.new(root)
      return puts(shadow.patch(ref)) || 0 if opts[:patch]

      entry = shadow.entries(limit: 200).find { |e| e[:sha].start_with?(ref) || e[:short] == ref }
      entry ||= { sha: ref, short: ref[0, 7], time: Time.now, subject: ref }
      puts Format.entry(entry, shadow.stat(entry[:sha]), width: width)
      0
    end

    def cmd_status(opts)
      root, = target(opts)
      shadow = Shadow.new(root)
      pending = shadow.pending
      return puts(JSON.pretty_generate(pending)) || 0 if opts[:json]

      if pending[:files].empty?
        puts Format.dim("no uncommitted changes since the last prompt")
        return 0
      end
      entry = { short: "pending", time: Time.now, subject: "since last prompt" }
      puts Format.entry(entry, pending, width: width)
      0
    end

    # Lets nvim (or anything else) drive git itself rather than reimplementing
    # the shadow path logic.
    def cmd_diffcmd(opts)
      root, ref = target(opts, expect_ref: true)
      return usage(2) unless ref

      shadow = Shadow.new(root)
      parent = "#{ref}^"
      _, _, status = Open3.capture3("git", "--git-dir=#{shadow.git_dir}",
                                    "rev-parse", "--verify", "--quiet", parent)
      parent = Shadow::EMPTY_TREE unless status.success?
      puts ["git", "--git-dir=#{shadow.git_dir}", "--work-tree=#{root}",
            "diff", parent, ref].shelljoin
      0
    end

    def cmd_paths(opts)
      root, = target(opts)
      shadow = Shadow.new(root)
      info = { root: root, git_dir: shadow.git_dir,
               initialized: shadow.initialized?, home: Project.home }
      return puts(JSON.pretty_generate(info)) || 0 if opts[:json]

      info.each { |k, v| puts "#{k}: #{v}" }
      0
    end

    # Must never raise and never hang: a Stop hook that fails would stall the
    # agent's turn. Any error is logged and swallowed. Unknown events are
    # ignored so the same script can sit next to other Cursor hooks without
    # snapshotting ~/.cursor on sessionStart.
    def cmd_hook(_opts)
      payload = ClaudeHook.read
      event = payload["hook_event_name"]
      if ClaudeHook.cache_event?(event)
        ClaudeHook.remember_prompt(payload)
        # Seed on submit so the baseline is taken *before* the agent edits.
        # Seeding on Stop would swallow the first turn into the baseline.
        prime_shadow(payload)
        mark_inflight(payload, true)
        return 0
      end
      return 0 unless ClaudeHook.snap_event?(event)

      root = Project.root_for(ClaudeHook.cwd(payload))
      shadow = Shadow.new(root)
      # A non-git directory is an ordinary situation for a hook -- agents run
      # in plenty of them -- so skip quietly. Raising here logged the same
      # error on every prompt in such a directory. `init` still refuses
      # loudly, which is where the explanation belongs.
      return 0 unless trackable?(shadow)

      shadow.init!
      seed(shadow)
      prompt = ClaudeHook.recall_prompt(payload) || "prompt at #{Time.now.strftime("%H:%M:%S")}"
      meta = ClaudeHook.meta(payload, prompt)
      record(shadow, prompt, meta)
      mark_inflight(payload, false)
      0
    rescue StandardError => e
      log("hook error: #{e.class}: #{e.message}")
      0
    end

    # Flag the project while an agent turn is running, so sweep! does not
    # claim the agent's in-progress edits as manual ones.
    def mark_inflight(payload, on)
      root = Project.root_for(ClaudeHook.cwd(payload))
      path = Project.inflight_path(root)
      if on
        File.write(path, Time.now.to_i.to_s)
      else
        File.delete(path) if File.exist?(path)
      end
    rescue StandardError
      nil
    end

    # Tracked only when it is a git worktree, unless explicitly overridden.
    # Mirrors Shadow#ensure_trackable! without raising.
    def trackable?(shadow)
      shadow.git_worktree? || ENV["AGENT_DIFF_ALLOW_NON_GIT"] == "1"
    end

    def prime_shadow(payload)
      root = Project.root_for(ClaudeHook.cwd(payload))
      shadow = Shadow.new(root)
      return unless trackable?(shadow)

      shadow.init!
      seed(shadow)
    rescue StandardError => e
      log("hook prime: #{e.class}: #{e.message}")
    end

    def log(message)
      File.open(Project.log_path, "a") { |f| f.puts("#{Time.now.iso8601} #{message}") }
    rescue StandardError
      nil
    end

    def cmd_browse
      require_relative "browser"
      Browser.new.run
      0
    end

    def width
      w = ENV["COLUMNS"]&.to_i
      w = `tput cols 2>/dev/null`.to_i if w.nil? || w.zero?
      w.zero? ? 80 : [w, 40].max
    end
  end
end

exit(AgentDiff::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
