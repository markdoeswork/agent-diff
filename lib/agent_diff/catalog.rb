# frozen_string_literal: true

require "json"
require "open3"
require_relative "project"
require_relative "shadow"

module AgentDiff
  # Everything the browser lists, with no rendering: tracked repos, the agent
  # sessions inside each, and the prompts inside each session.
  #
  # Nothing here asks a terminal or multiplexer what is focused. A repo is
  # anything with a shadow under Project.home; a session is a run of prompts
  # sharing an AD-Session trailer. The only outside source is the agents' own
  # transcripts, read for a session's title.
  class Catalog
    Repo = Struct.new(:root, :name, :shadow, :last_at, keyword_init: true)
    Session = Struct.new(:id, :title, :agent, :entries, :last_at, :manual,
                         keyword_init: true)

    MANUAL_ID = :manual

    def initialize(home: Project.home, claude_dir: nil, codex_dir: nil)
      @home = home
      @claude_dir = claude_dir || File.join(
        File.expand_path(ENV["CLAUDE_CONFIG_DIR"] || "~/.claude"), "projects"
      )
      @codex_dir = codex_dir || File.expand_path(ENV["CODEX_HOME"] || "~/.codex")
      @titles = {}
      @totals = {}
    end

    # Every shadow repo whose worktree is known, most recently active first.
    def repos
      dirs = Dir.glob(File.join(@home, "repos", "*.git")).select { |d| File.directory?(d) }
      roots = dirs.to_h { |d| [d, recorded_root(d)] }
      backfill_roots(roots) if roots.value?(nil)

      roots.filter_map do |dir, root|
        next unless root

        Repo.new(root: root, name: File.basename(root), shadow: Shadow.new(root),
                 last_at: last_commit_time(dir))
      end.sort_by { |r| -(r.last_at || Time.at(0)).to_i }
    end

    # Prompts grouped by session, newest activity first. Rows no hook claimed
    # -- hand edits and real commits -- share one "manual" session so they
    # stay visible without each becoming a session of its own.
    def sessions(shadow, limit: 1000)
      entries = shadow.entries(limit: limit)
      groups = entries.group_by { |e| e[:session_id] || MANUAL_ID }
      list = groups.map do |id, rows|
        manual = id == MANUAL_ID
        Session.new(
          id: id, entries: rows, last_at: rows.first[:time], manual: manual,
          agent: manual ? "you" : (rows.map { |r| r[:agent] }.compact.first || "agent"),
          title: manual ? "hand edits & commits" : (title_for(id) || rows.last[:subject])
        )
      end
      # group_by keeps first-seen order, which is newest first; the index
      # breaks ties so prompts recorded in the same second keep that order.
      list.each_with_index.sort_by { |s, i| [-s.last_at.to_i, i] }.map(&:first)
    end

    # +/- counts for one entry. Read in bulk per repo, then per row only for
    # "commit" rows, whose diff lives in the real repo.
    def totals(shadow, entry)
      cache = (@totals[shadow.git_dir] ||= shadow.totals)
      if entry[:kind] == "commit" || !cache.key?(entry[:sha])
        stat = shadow.stat(entry[:sha])
        cache[entry[:sha]] = { added: stat[:added], deleted: stat[:deleted],
                               files: stat[:files].length }
      end
      cache[entry[:sha]]
    end

    def session_totals(shadow, session)
      session.entries.each_with_object({ added: 0, deleted: 0 }) do |e, acc|
        t = totals(shadow, e)
        acc[:added] += t[:added]
        acc[:deleted] += t[:deleted]
      end
    end

    # Forget cached counts, e.g. after the repo recorded a new prompt.
    def reset(shadow = nil)
      shadow ? @totals.delete(shadow.git_dir) : @totals.clear
    end

    # The title the agent gave the session: Claude Code's "ai-title"
    # transcript record, Codex's thread name, or the title the OpenCode plugin
    # saved. nil when there is none -- Cursor, or a session whose transcript
    # has been cleaned up.
    def title_for(session_id)
      return @titles[session_id] if @titles.key?(session_id)

      path = transcript_index[session_id.to_s]
      @titles[session_id] = (path && last_ai_title(path)) || codex_titles[session_id.to_s] ||
                            saved_title(session_id)
    end

    private

    def recorded_root(dir)
      out, _, ok = Open3.capture3("git", "--git-dir=#{dir}", "config", "--get", "agentdiff.root")
      ok.success? && !out.strip.empty? ? out.strip : nil
    end

    def last_commit_time(dir)
      out, _, ok = Open3.capture3("git", "--git-dir=#{dir}", "log", "-1", "--format=%ct")
      ok.success? && !out.strip.empty? ? Time.at(out.to_i) : nil
    end

    # Shadows made before agentdiff.root was recorded only know a hash of
    # their path. Hash every directory the agents' transcripts say they ran
    # in, plus where we are now, and keep whichever matches -- writing it
    # back so this happens once per repo.
    def backfill_roots(roots)
      wanted = roots.select { |_, r| r.nil? }.keys.to_h { |d| [File.basename(d, ".git"), d] }
      candidate_dirs.each do |cwd|
        break if wanted.empty?
        next unless File.directory?(cwd)

        root = Project.root_for(cwd)
        dir = wanted.delete(Project.slug(root))
        next unless dir

        roots[dir] = root
        Open3.capture3("git", "--git-dir=#{dir}", "config", "agentdiff.root", root)
      end
    end

    def candidate_dirs
      dirs = [Dir.pwd]
      Dir.glob(File.join(@claude_dir, "*")).each do |project|
        newest = Dir.glob(File.join(project, "*.jsonl")).max_by { |f| File.mtime(f) }
        cwd = newest && first_cwd(newest)
        dirs << cwd if cwd
      end
      dirs.uniq
    end

    def first_cwd(path)
      File.foreach(path).first(200).each do |line|
        m = line.match(/"cwd":"((?:[^"\\]|\\.)*)"/)
        return JSON.parse(%("#{m[1]}")) if m
      end
      nil
    rescue StandardError
      nil
    end

    def transcript_index
      @transcript_index ||= Dir.glob(File.join(@claude_dir, "*", "*.jsonl"))
                               .to_h { |f| [File.basename(f, ".jsonl"), f] }
    end

    def saved_title(session_id)
      path = File.join(@home, "titles", "#{session_id.to_s.gsub(/[^A-Za-z0-9_-]/, "_")}.txt")
      title = File.exist?(path) ? File.read(path).strip : ""
      title.empty? ? nil : title
    rescue StandardError
      nil
    end

    # Codex appends a line to session_index.jsonl each time it (re)names a
    # thread, so the last name for an id wins.
    def codex_titles
      @codex_titles ||= begin
        path = File.join(@codex_dir, "session_index.jsonl")
        File.exist?(path) ? parse_codex_index(path) : {}
      end
    end

    def parse_codex_index(path)
      File.foreach(path).each_with_object({}) do |line, acc|
        rec = (JSON.parse(line) rescue nil)
        next unless rec.is_a?(Hash) && rec["id"] && !rec["thread_name"].to_s.strip.empty?

        acc[rec["id"].to_s] = rec["thread_name"]
      end
    rescue StandardError
      {}
    end

    # Transcripts run to megabytes and the title is rewritten as the session
    # goes on, so read from the end: the last ai-title is the current one.
    def last_ai_title(path)
      tail = File.open(path, "rb") do |f|
        f.seek([f.size - 262_144, 0].max)
        f.read.to_s.force_encoding("UTF-8")
      end
      title = ai_title_in(tail.lines)
      title || ai_title_in(File.foreach(path))
    rescue StandardError
      nil
    end

    def ai_title_in(lines)
      lines.select { |l| l.include?('"ai-title"') }.reverse_each do |l|
        title = (JSON.parse(l)["aiTitle"] rescue nil)
        return title unless title.to_s.strip.empty?
      end
      nil
    end
  end
end
