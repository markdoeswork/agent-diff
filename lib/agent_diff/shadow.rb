# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"
require "tmpdir"
require_relative "project"

module AgentDiff
  # A shadow git repository: a separate GIT_DIR pointed at the real worktree.
  #
  # The project's own .git is never touched -- not its HEAD, not its index, not
  # its staging area. It is the same --git-dir/--work-tree split
  # people use to keep their dotfiles in a bare repo. Verified: after shadow
  # add/commit/log/diff, the real `git status --porcelain`, HEAD, and staged
  # index are byte-identical.
  class Shadow
    # Files that would make the shadow enormous or meaningless. .git/ is the
    # critical one: without it the shadow swallows the real repo's objects.
    ALWAYS_EXCLUDE = [".git/", ".agent_diff/"].freeze

    attr_reader :root, :git_dir

    def initialize(root)
      @root = Project.canonicalize(root)
      @git_dir = Project.shadow_dir(@root)
    end

    def initialized?
      File.directory?(@git_dir)
    end

    # A non-git directory has no .gitignore to bound what gets swallowed, and
    # can sit on top of hundreds of gigabytes (a server data directory did
    # exactly this in testing). Require an explicit opt-in for those.
    def guard!
      return if git_worktree? || ENV["AGENT_DIFF_ALLOW_NON_GIT"] == "1"

      raise "#{@root} is not a git repository. agent_diff tracks git worktrees " \
            "so .gitignore bounds what is captured. Set " \
            "AGENT_DIFF_ALLOW_NON_GIT=1 to override."
    end

    def git_worktree?
      _, _, status = Open3.capture3("git", "-C", @root, "rev-parse", "--git-dir")
      status.success?
    end

    def init!
      return self if initialized?

      guard!
      FileUtils.mkdir_p(File.dirname(@git_dir))
      run!("git", "init", "--quiet", "--bare", @git_dir)
      # Identity is set locally so the shadow never depends on, or is polluted
      # by, the user's global git config.
      git!("config", "user.name", "agent_diff")
      git!("config", "user.email", "agent_diff@localhost")
      # A global core.excludesFile would silently drop files from the shadow.
      git!("config", "core.excludesFile", "/dev/null")
      record_root
      write_excludes
      self
    end

    # The shadow's directory name is a one-way hash of the worktree path, so
    # the path itself is kept in the shadow's config. That is how the browser
    # lists every tracked repo without being told where any of them live.
    def record_root
      git!("config", "agentdiff.root", @root)
    end

    # The shadow honors the project's .gitignore (so node_modules etc. stay out)
    # plus our own always-exclude list.
    def write_excludes
      info = File.join(@git_dir, "info")
      FileUtils.mkdir_p(info)
      File.write(File.join(info, "exclude"), "#{ALWAYS_EXCLUDE.join("\n")}\n")
    end

    def empty?
      !git("rev-parse", "--verify", "--quiet", "HEAD").last.success?
    end

    # Stage everything and commit, unless the tree is unchanged.
    #
    # Returns the new sha, or nil when there was nothing to record -- an idle
    # or question-only prompt must not leave an empty commit behind.
    # allow_empty: record the snapshot even when the worktree is unchanged.
    # A real `git commit` moves HEAD without touching any file, so the row
    # that represents it has nothing staged and would otherwise be dropped.
    def snap!(message:, meta: {}, allow_empty: false)
      guard!
      init!
      lock do
        git!("add", "-A")
        return nil if nothing_staged? && !allow_empty

        args = ["commit", "--quiet", "--no-verify", "--allow-empty-message"]
        args << "--allow-empty" if allow_empty
        git!(*args, "-m", commit_message(message, meta))
        sha = git!("rev-parse", "HEAD").strip
        FileUtils.touch(Project.signal_path(@root))
        sha
      end
    end

    def nothing_staged?
      return false if empty?

      git("diff", "--cached", "--quiet").last.success?
    end

    # Trailers keep metadata queryable with plain git, no sidecar database.
    def commit_message(message, meta)
      subject = summarise(message)

      lines = [subject, ""]
      meta.each do |key, value|
        next if value.nil? || value.to_s.strip.empty?

        lines << "#{trailer_key(key)}: #{value.to_s.strip.gsub("\n", " ")}"
      end
      lines.join("\n")
    end

    # A one-line label for a prompt.
    #
    # Taking only the first line loses the point of a prompt that opens with a
    # short sentence and continues underneath -- and pasted blocks, images and
    # tool output make that common. So lines are joined until there is enough
    # to recognise the prompt by, with the noisy parts skipped.
    # Attachment placeholders carry no meaning in a one-line label. They are
    # stripped wherever they appear, not just at the start of a line, since
    # "also [Pasted text #4 +29 lines]" is otherwise kept as if it were prose.
    NOISE = /\[(?:Pasted text|Image|Request interrupted)[^\]]*\]/
    SKIP_LINE = /\A(?:```|\s*[-*]\s*\z|\s*\z)/
    CONNECTOR = /\A(?:also|and|then|plus|btw|ps|next)\b[[:punct:]]*\z/i
    def summarise(message)
      text = message.to_s.strip
      return "(no prompt text)" if text.empty?

      parts = text.split("\n").map { |l| l.gsub(NOISE, "").strip }
      # A line that was only an attachment plus a connector ("also [Pasted
      # ...]") reduces to the connector; that is not worth a slot in the label.
      parts = parts.reject do |l|
        l.empty? || l.match?(SKIP_LINE) || l.length < 4 || CONNECTOR.match?(l)
      end
      subject = parts.first(3).join(" \u00b7 ")
      subject = text.split("\n").first.to_s.strip if subject.empty?
      subject = "(no prompt text)" if subject.empty?
      subject.length > 120 ? "#{subject[0, 117]}..." : subject
    end

    def trailer_key(key)
      "AD-#{key.to_s.split("_").map(&:capitalize).join("-")}"
    end

    # One entry per prompt, newest first.
    def entries(limit: 50, pane: nil)
      return [] unless initialized? || File.directory?(@git_dir)
      return [] if empty?

      sep = "\x1e"
      rec = "\x1d"
      fmt = ["%H", "%h", "%at", "%s", "%b"].join(sep)
      out = git!("log", "--max-count=#{limit * 3}", "--format=#{fmt}#{rec}")
      rows = out.split(rec).reject { |c| c.strip.empty? }.map do |chunk|
        sha, short, at, subject, body = chunk.sub(/\A\s+/, "").split(sep, 5)
        entry(sha, short, at, subject, body)
      end
      rows = rows.reject { |r| r[:seed] }
      rows = rows.select { |r| r[:pane_id] == pane } if pane
      rows.first(limit)
    end

    def entry(sha, short, at, subject, body)
      meta = parse_trailers(body.to_s)
      {
        sha: sha,
        short: short,
        time: Time.at(at.to_i),
        subject: subject.to_s,
        pane_id: meta["pane"],
        session_id: meta["session"],
        agent: meta["agent"],
        branch: meta["branch"],
        head: meta["head"],
        seed: meta["kind"] == "seed",
        kind: meta["kind"],
        # Who is responsible: an agent name from the hook, "you" for hand
        # edits, "git" for a commit. Older rows predate this and fall back to
        # the agent trailer.
        source: meta["source"] || meta["agent"],
        # The prompt as typed, before summarise() cut it down to a label.
        prompt: meta["prompt"],
        # When the prompt was submitted; the row's own time is when it ended.
        started: (Time.iso8601(meta["started"]) rescue nil)
      }
    end

    # Line counts for many entries at once, keyed by sha: one `git log
    # --numstat` instead of a stat per row, which is what lets a list of a few
    # hundred prompts show its totals without stalling. Shadow history is
    # linear, so each commit's numstat against its parent is exactly what
    # stat() reports -- except "commit" rows, which are empty here and need
    # stat() to read the real repo.
    def totals(limit: 1000)
      return {} if !initialized? || empty?

      out = git!("log", "--max-count=#{limit * 3}", "--format=\x1e%H", "--numstat")
      out.split("\x1e").each_with_object({}) do |chunk, acc|
        lines = chunk.strip.split("\n")
        sha = lines.shift
        next if sha.nil? || sha.empty?

        added = deleted = files = 0
        lines.each do |l|
          a, d, = l.split("\t", 3)
          next if d.nil?

          files += 1
          added += a.to_i
          deleted += d.to_i
        end
        acc[sha] = { added: added, deleted: deleted, files: files }
      end
    end

    def parse_trailers(body)
      body.lines.each_with_object({}) do |line, acc|
        next unless (m = line.strip.match(/\AAD-([A-Za-z-]+):\s*(.*)\z/))

        acc[m[1].downcase.tr("-", "_")] = m[2].strip
      end
    end

    # Added/deleted line counts plus per-file status for one entry, comparing
    # it against its parent. Binary files report "-" in numstat; they are
    # counted as files but contribute no lines.
    #
    # A "commit" row is empty in the shadow -- committing moves HEAD without
    # touching the worktree -- so its contents are read from the real repo
    # instead, which is where that diff actually lives. So are the branch's
    # own commits, which the browser lists by their real sha.
    def stat(sha)
      head = real_commit_for(sha)
      return real_commit_stat(head) if head

      parent = "#{sha}^"
      parent = EMPTY_TREE unless git("rev-parse", "--verify", "--quiet", parent).last.success?
      diff_stat(parent, sha)
    end

    # What a real commit changed, read from the project repo.
    def real_commit_stat(head)
      status, ok = git_plain("-C", @root, "diff", "--name-status", "-z", "#{head}^", head)
      unless ok.success?
        # A root commit has no parent; diff it against the empty tree.
        status, ok = git_plain("-C", @root, "diff", "--name-status", "-z",
                               EMPTY_TREE, head)
      end
      return { files: [], added: 0, deleted: 0 } unless ok.success?

      numstat, = git_plain("-C", @root, "diff", "--numstat", "-z", "#{head}^", head)
      files = parse_name_status(status)
      counts = parse_numstat(numstat)
      files.each { |f| f.merge!(counts[f[:path]] || { added: 0, deleted: 0, binary: false }) }
      { files: files, added: files.sum { |f| f[:added].to_i },
        deleted: files.sum { |f| f[:deleted].to_i } }
    rescue StandardError
      { files: [], added: 0, deleted: 0 }
    end

    # The real-repo commit an entry's diff lives in: a recorded "commit" row's
    # head, or the sha itself when it names a real commit rather than a
    # snapshot. nil for an ordinary snapshot.
    def real_commit_for(sha)
      row = entry_for(sha)
      return row[:head] if row && row[:kind] == "commit" && row[:head]
      return nil if row

      git_plain("-C", @root, "cat-file", "-e", "#{sha}^{commit}").last.success? ? sha : nil
    end

    def entry_for(sha)
      sep = "\x1e"
      fmt = ["%H", "%h", "%at", "%s", "%b"].join(sep)
      out, _err, ok = git("log", "-1", "--format=#{fmt}", sha)
      return nil unless ok.success?

      h, short, at, subject, body = out.split(sep, 5)
      entry(h, short, at, subject, body)
    rescue StandardError
      nil
    end

    EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    def diff_stat(from, to)
      status = git!("diff", "--name-status", "-z", from, to)
      numstat = git!("diff", "--numstat", "-z", from, to)
      files = parse_name_status(status)
      counts = parse_numstat(numstat)
      files.each { |f| f.merge!(counts[f[:path]] || { added: 0, deleted: 0, binary: false }) }
      {
        files: files,
        added: files.sum { |f| f[:added].to_i },
        deleted: files.sum { |f| f[:deleted].to_i }
      }
    end

    # The changed blocks within one file: each hunk's enclosing symbol, the
    # line to jump to, and its own +/- counts.
    #
    # The symbol comes from git's own hunk headers rather than from parsing
    # source here. Git ships xfuncname patterns for ruby, python, rust, go,
    # java and more, and they already answer "the most parent thing" -- the
    # enclosing def/class/module -- which is exactly the label wanted. A
    # temporary attributes file turns them on by extension, since the projects
    # being watched have no reason to configure this themselves.
    FUNC_ATTRS = {
      "rb" => "ruby", "py" => "python", "rs" => "rust", "go" => "golang",
      "java" => "java", "kt" => "kotlin", "cs" => "csharp", "ex" => "elixir",
      "exs" => "elixir", "pl" => "perl", "pm" => "perl", "php" => "php",
      "m" => "objc", "sh" => "bash", "bash" => "bash", "md" => "markdown",
      "tex" => "tex", "scm" => "scheme"
    }.freeze

    def hunks(sha, path)
      # A "commit" row is empty in the shadow -- committing moves HEAD without
      # touching the worktree -- so read its hunks from the real repo, the
      # same split stat() makes.
      head = real_commit_for(sha)
      return real_hunks(head, path) if head

      parent = "#{sha}^"
      parent = EMPTY_TREE unless git("rev-parse", "--verify", "--quiet", parent).last.success?
      parse_hunks(diff_with_funcnames(parent, sha, path)) { blob_lines(sha, path) }
    rescue StandardError
      []
    end

    # For a "commit" row the diff lives in the real repo, not the shadow.
    def real_hunks(head, path)
      from = "#{head}^"
      _, ok = git_plain("-C", @root, "rev-parse", "--verify", "--quiet", from)
      from = EMPTY_TREE unless ok.success?
      out, _err, _ok = Open3.capture3(
        "git", "-C", @root, "-c", "core.attributesFile=#{attrs_file}",
        "diff", "-U0", from, head, "--", path, chdir: @root
      )
      parse_hunks(out) { real_blob_lines(head, path) }
    rescue StandardError
      []
    end

    # `path` is repo-relative, so git must resolve it from the work tree root.
    # Without chdir the pathspec is interpreted relative to wherever the
    # process happens to be -- inside the project itself it silently matches
    # nothing and every file looks like it has no hunks.
    def diff_with_funcnames(from, to, path)
      out, _err, ok = Open3.capture3(
        "git", "--git-dir=#{@git_dir}", "--work-tree=#{@root}",
        "-c", "core.attributesFile=#{attrs_file}",
        "diff", "-U0", from, to, "--", path, chdir: @root
      )
      ok.success? ? out : ""
    end

    # Written once per process, in the agent_diff home rather than in any
    # project, so nothing is added to the repositories being watched.
    def attrs_file
      path = File.join(Project.home, "funcname.attributes")
      return path if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, FUNC_ATTRS.map { |ext, drv| "*.#{ext} diff=#{drv}" }.join("\n") + "\n")
      path
    end

    # @@ -old,n +new,n @@ enclosing symbol
    HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@\s*(.*)\z/
    def parse_hunks(raw, &blob)
      out = []
      current = nil
      raw.to_s.each_line do |l|
        if (m = HUNK.match(l.chomp))
          current = { line: m[3].to_i, symbol: clean_symbol(m[5]), added: 0, deleted: 0 }
          # A pure deletion reports the line *before* the removed block; +0
          # would be an invalid jump target.
          current[:line] = 1 if current[:line].zero?
          out << current
        elsif current
          current[:added] += 1 if l.start_with?("+") && !l.start_with?("+++")
          current[:deleted] += 1 if l.start_with?("-") && !l.start_with?("---")
        end
      end
      merge_by_symbol(out, &blob)
    end

    # -U0 emits one hunk per contiguous run of changed lines, so editing a
    # method in three places gives three rows that all say "def live_view".
    # They are not three methods, so fold them into one row carrying the
    # summed counts, pointing at the `def` itself.
    #
    # Hunks are grouped by the *declaration line*, not by the symbol text:
    # two classes can each hold a `def __init__`, and git labels both hunks
    # identically with nothing in between, so the text alone cannot tell them
    # apart. Resolving each hunk to the line its def sits on does -- same def,
    # same line. Hunks whose symbol git did not name, or whose declaration
    # cannot be found, keep their own changed line and never merge.
    def merge_by_symbol(hunks, &blob)
      resolved = resolve_symbol_lines(hunks, &blob)

      resolved.chunk_while { |a, b| a[:decl] && a[:decl] == b[:decl] }.map do |run|
        row = if run.one?
                run.first
              else
                run.first.merge(
                  added: run.sum { |h| h[:added] },
                  deleted: run.sum { |h| h[:deleted] }
                )
              end
        row.reject { |k, _| k == :decl }
      end
    end

    # The hunk header gives the line that *changed*, not where the enclosing
    # def sits -- so a merged row would point at its first edit rather than at
    # the method. Git's header text is a verbatim copy of the declaration
    # line, so find that line by searching back from the first change.
    #
    # Only rows whose symbol git actually named are moved; "(top level)" rows
    # have no declaration to find and keep the changed line.
    def resolve_symbol_lines(hunks, &blob)
      lines = block_given? && hunks.any? { |h| h[:symbol] } ? blob.call : nil

      hunks.map do |h|
        decl = lines && !lines.empty? && h[:symbol] ? declaration_line(lines, h) : nil
        decl ? h.merge(line: decl, decl: decl) : h
      end
    end

    # Walk up from the first changed line to the nearest line that starts the
    # declaration git named. The search is bounded so a symbol that has since
    # been renamed or deleted falls back to the changed line rather than
    # matching something far above it.
    #
    # Matching is on the *cleaned* symbol (`def foo`), not git's raw header
    # text (`def foo(a, b)`). The header quotes the declaration as it read
    # BEFORE the change, while the blob searched is the file AFTER it -- so a
    # hunk that edits its own signature would never find itself, and would
    # split into one row per hunk. Arguments are exactly the part that moves,
    # and clean_symbol has already dropped them.
    DECL_SEARCH_LIMIT = 400
    def declaration_line(lines, hunk)
      needle = hunk[:symbol].to_s.strip
      return nil if needle.empty?

      start = [hunk[:line] - 1, lines.length - 1].min
      return nil if start.negative?

      stop = [start - DECL_SEARCH_LIMIT, 0].max
      start.downto(stop) do |i|
        return i + 1 if clean_symbol(lines[i]) == needle
      end
      nil
    end

    # The file as it stands *after* the change, which is what the hunk's +line
    # numbers refer to.
    def blob_lines(sha, path)
      out, _err, ok = Open3.capture3(
        "git", "--git-dir=#{@git_dir}", "--work-tree=#{@root}",
        "show", "#{sha}:#{path}", chdir: @root
      )
      ok.success? ? out.lines : nil
    rescue StandardError
      nil
    end

    def real_blob_lines(head, path)
      out, _err, ok = Open3.capture3("git", "-C", @root, "show", "#{head}:#{path}", chdir: @root)
      ok.success? ? out.lines : nil
    rescue StandardError
      nil
    end

    # Hunk context is a raw source line; trim it to the declaration itself.
    def clean_symbol(text)
      t = text.to_s.strip
      return nil if t.empty?

      t = t.sub(/\s*[{(].*\z/, "") if t.match?(/\A(?:def|class|module|fn|func|type)\b/)
      t = t.sub(/\s*(?:->|:)\s*.*\z/, "")
      t.length > 60 ? "#{t[0, 57]}..." : t
    end

    # -z output is NUL-separated; renames emit status, old path, new path.
    def parse_name_status(raw)
      parts = raw.split("\0").reject(&:empty?)
      out = []
      i = 0
      while i < parts.length
        code = parts[i]
        if code.start_with?("R", "C")
          out << { status: code[0], path: parts[i + 2], from: parts[i + 1] }
          i += 3
        else
          out << { status: code[0], path: parts[i + 1] }
          i += 2
        end
      end
      out.compact
    end

    def parse_numstat(raw)
      parts = raw.split("\0").reject(&:empty?)
      acc = {}
      i = 0
      while i < parts.length
        field = parts[i]
        unless (m = field.match(/\A(\d+|-)\t(\d+|-)\t(.*)\z/m))
          i += 1
          next
        end
        added, deleted, path = m[1], m[2], m[3]
        if path.empty? # rename: next two entries are old and new paths
          path = parts[i + 2]
          i += 3
        else
          i += 1
        end
        binary = added == "-" || deleted == "-"
        acc[path] = {
          added: binary ? 0 : added.to_i,
          deleted: binary ? 0 : deleted.to_i,
          binary: binary
        }
      end
      acc
    end

    # The full diff for one entry, or for one file within it. Like stat, a
    # "commit" row is read from the real repo, where its diff actually lives.
    #
    # chdir is pinned to the work tree for the same reason as
    # diff_with_funcnames: a pathspec resolves against the process's cwd.
    def patch(sha, path: nil)
      spec = path ? ["--", path] : []
      head = real_commit_for(sha)
      if head
        from = "#{head}^"
        from = EMPTY_TREE unless git_plain("-C", @root, "rev-parse", "--verify", "--quiet", from).last.success?
        out, = Open3.capture3("git", "-C", @root, "diff", from, head, *spec, chdir: workdir)
        return out
      end

      parent = "#{sha}^"
      parent = EMPTY_TREE unless git("rev-parse", "--verify", "--quiet", parent).last.success?
      out, _err, ok = Open3.capture3("git", "--git-dir=#{@git_dir}", "--work-tree=#{@root}",
                                     "diff", parent, sha, *spec, chdir: workdir)
      ok.success? ? out : ""
    end

    # A shadow can outlive its checkout; git still answers from the shadow
    # alone, so fall back rather than failing to spawn.
    def workdir
      File.directory?(@root) ? @root : Dir.tmpdir
    end

    # Work done since the last snapshot -- the in-flight turn.
    def pending
      return { files: [], added: 0, deleted: 0 } unless initialized? || File.directory?(@git_dir)

      init!
      git!("add", "-A")
      base = empty? ? EMPTY_TREE : "HEAD"
      status = git!("diff", "--name-status", "-z", "--cached", base)
      numstat = git!("diff", "--numstat", "-z", "--cached", base)
      files = parse_name_status(status)
      counts = parse_numstat(numstat)
      files.each { |f| f.merge!(counts[f[:path]] || { added: 0, deleted: 0, binary: false }) }
      { files: files, added: files.sum { |f| f[:added].to_i }, deleted: files.sum { |f| f[:deleted].to_i } }
    end

    # Real-repo HEAD and branch, recorded so a checkout/rebase between prompts
    # can be told apart from an agent writing thousands of lines.
    def real_head
      sha, = git_plain("-C", @root, "rev-parse", "HEAD")
      branch, = git_plain("-C", @root, "rev-parse", "--abbrev-ref", "HEAD")
      { head: sha.strip, branch: branch.strip }
    end

    # Did the real HEAD get from `from` to `to` by something other than
    # committing? A checkout, pull, merge, rebase or reset swaps worktree
    # content nobody typed, so the snapshot diff should not be reported as a
    # prompt's work. Plain commits -- which agents routinely make mid-turn --
    # leave the worktree alone and must not trip this.
    #
    # The HEAD reflog says exactly how HEAD moved. When `from` is not found in
    # it (expired, or a fresh clone), assume the worst.
    COMMIT_REFLOG = /\Acommit(?: \((?:amend|initial|merge)\))?:/
    def head_moved_by_checkout?(from, to)
      return false if from.to_s.empty? || to.to_s.empty? || from == to

      out, ok = git_plain("-C", @root, "reflog", "-n", "200", "--format=%H%x1e%gs", "HEAD")
      return true unless ok.success?

      out.each_line do |line|
        sha, subject = line.chomp.split("\x1e", 2)
        return false if sha == from
        return true unless COMMIT_REFLOG.match?(subject.to_s)
      end
      true
    end

    # ---- the real branch ----------------------------------------------------

    # Every path the given snapshots changed. Snapshots are linear, so each
    # one's own diff against its parent is what `git show` lists.
    def paths_for(shas)
      return [] if shas.empty?

      out, _err, ok = git("show", "--name-only", "--format=", *shas)
      ok.success? ? out.lines.map(&:strip).reject(&:empty?).uniq : []
    end

    # The real commits on `branches` since `since`, newest first, each with
    # the paths it touched and how far it has got: "local", "pushed" (on a
    # remote) or "merged" (in the default branch). First-parent only, so a
    # branch that merged main in does not list all of main's commits as its own.
    def branch_commits(branches, since:, limit: 200)
      refs = branches.compact.uniq.select { |b| local_branch?(b) }
      return [] if refs.empty?

      sep = "\x1e"
      rec = "\x1d"
      fmt = rec + %w[%H %h %ct %an %s %B].join(sep) + sep
      out, ok = git_plain("-C", @root, "log", "--first-parent", "--name-only",
                          "--max-count=#{limit}", "--since=#{since.to_i}",
                          "--format=#{fmt}", *refs, "--")
      return [] unless ok.success?

      states = commit_states(refs, since)
      out.split(rec).reject { |c| c.strip.empty? }.map do |chunk|
        sha, short, at, author, subject, body, files = chunk.split(sep, 7)
        { sha: sha, short: short, time: Time.at(at.to_i), subject: subject.to_s,
          kind: "git-commit", source: "git", author: author, branch: refs.first,
          prompt: body.to_s.strip, paths: files.to_s.lines.map(&:strip).reject(&:empty?),
          state: states.call(sha) }
      end
    end

    # The default branch work is adopted into: origin's HEAD, else the usual
    # names, remote first.
    def default_branch
      out, ok = git_plain("-C", @root, "symbolic-ref", "--quiet", "--short",
                          "refs/remotes/origin/HEAD")
      return out.strip if ok.success? && !out.strip.empty?

      %w[origin/main origin/master main master].find do |r|
        git_plain("-C", @root, "rev-parse", "--verify", "--quiet", "#{r}^{commit}").last.success?
      end
    end

    # Squash merges rewrite the commits, so those read as "pushed", never
    # "merged"; telling them apart would mean comparing patches.
    def commit_states(refs, since)
      remotes, = git_plain("-C", @root, "remote")
      unpushed = remotes.strip.empty? ? nil : rev_list(refs, since, "--remotes")
      default = default_branch
      # On the default branch itself, being pushed is being adopted.
      on_default = default && refs.all? { |r| r == default.sub(%r{\A[^/]+/}, "") }
      unmerged = default && !on_default ? rev_list(refs, since, default) : nil
      lambda do |sha|
        next "local" if unpushed&.include?(sha)
        next "merged" if unmerged && !unmerged.include?(sha)

        unpushed ? "pushed" : nil
      end
    end

    def rev_list(refs, since, exclude)
      not_args = exclude == "--remotes" ? ["--not", "--remotes"] : ["--not", exclude]
      out, ok = git_plain("-C", @root, "rev-list", "--since=#{since.to_i}", *refs, *not_args, "--")
      ok.success? ? out.lines.map(&:strip).to_h { |l| [l, true] } : {}
    end

    def local_branch?(name)
      return false if name.to_s.empty? || name == "HEAD"

      git_plain("-C", @root, "rev-parse", "--verify", "--quiet", "refs/heads/#{name}").last.success?
    end

    # The real HEAD recorded on the newest snapshot, or nil if there is none.
    # Used to notice that the real repo moved (a commit, checkout or rebase)
    # while agent_diff was not looking.
    def last_recorded_head
      row = entries(limit: 1).first
      row && row[:head]
    end

    # Capture anything that happened without a hook: hand edits, an agent with
    # no hook support (codex, opencode), and real git commits.
    #
    # Hooks cover Claude and Cursor prompts. Everything else reaches the
    # worktree with nothing to announce it, so this is called before any read
    # -- list, status, the browser -- and the history is correct whenever it is
    # actually looked at, rather than depending on a daemon being up.
    #
    # Returns a short description of what it recorded, or nil.
    def sweep!
      return nil unless initialized?

      now = real_head
      was = last_recorded_head

      # A commit moves HEAD without touching the worktree, so it must be
      # detected by comparing HEAD rather than by looking for file changes.
      if was && !now[:head].empty? && was != now[:head]
        subject, = git_plain("-C", @root, "log", "-1", "--format=%s", now[:head])
        label = subject.strip
        label = "commit #{now[:head][0, 7]}" if label.empty?
        snap!(message: label, allow_empty: true,
              meta: { kind: "commit", source: "git", branch: now[:branch],
                      head: now[:head] })
        return "commit"
      end

      # Otherwise: uncommitted worktree changes nobody claimed.
      return nil if pending[:files].empty?

      # ...unless an agent is mid-turn, in which case they are its edits, not
      # yours. Its Stop hook will record them under the real prompt a moment
      # later. Claiming them here both mislabels the work and steals the diff
      # from the row that should carry it.
      return nil if Project.inflight?(@root)

      # Amend rather than stack: hand editing is continuous, and one row per
      # sweep would bury the prompt history under "manual edits" every time
      # the browser refreshed. Consecutive manual work collapses into a single
      # growing row until something else (a prompt, a commit) separates it.
      last = entries(limit: 1).first
      if last && last[:kind] == "manual"
        lock do
          git!("add", "-A")
          return nil if nothing_staged?

          git!("commit", "--quiet", "--no-verify", "--amend", "--allow-empty-message",
               "-m", commit_message("manual edits",
                                    { kind: "manual", source: "you",
                                      branch: now[:branch], head: now[:head] }))
          FileUtils.touch(Project.signal_path(@root))
        end
        return "manual"
      end

      snap!(message: "manual edits",
            meta: { kind: "manual", source: "you", branch: now[:branch],
                    head: now[:head] })
      "manual"
    rescue StandardError
      nil
    end

    private

    # Serializes concurrent Stop hooks: two agents working in one repo would
    # otherwise race on the shadow index.
    def lock
      guard!
      FileUtils.mkdir_p(File.dirname(@git_dir))
      File.open("#{@git_dir}.lock", File::CREAT | File::RDWR, 0o600) do |f|
        f.flock(File::LOCK_EX)
        return yield
      end
    end

    def git(*args)
      Open3.capture3("git", "--git-dir=#{@git_dir}", "--work-tree=#{@root}", *args)
    end

    def git!(*args)
      out, err, status = git(*args)
      raise "git #{args.first} failed: #{err.strip}" unless status.success?

      out
    end

    def git_plain(*args)
      out, _, status = Open3.capture3("git", *args)
      [status.success? ? out : "", status]
    end

    def run!(*args)
      out, err, status = Open3.capture3(*args)
      raise "#{args.first} failed: #{err.strip}" unless status.success?

      out
    end
  end
end
