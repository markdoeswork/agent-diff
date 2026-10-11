# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "catalog"
require_relative "editor"
require_relative "format"
require_relative "project"

module AgentDiff
  # The viewer: one session's prompts, each with the files it changed nested
  # beneath it, filling the whole terminal. The branch's real commits sit
  # between them in time order, marked local, pushed or merged. Files open into the blocks
  # (def/class) that changed; a prompt zooms open to show its full text.
  #
  # Which session is shown is never guessed from a multiplexer. It starts on
  # the newest session -- in the repo you launched from, else anywhere -- and
  # `s` opens a switcher over every session the hooks have recorded, across
  # every repo, to jump somewhere else.
  class Browser
    KEYS = {
      "j" => :down, "k" => :up, "h" => :left, "l" => :right,
      "g" => :top, "G" => :bottom, "\u0004" => :page_down, "\u0015" => :page_up,
      "\r" => :open, "\n" => :open, "o" => :open,
      "e" => :expand_here, "E" => :expand_all,
      "z" => :zoom, " " => :zoom, "d" => :diff, "f" => :all_files,
      "s" => :switch, "\u0010" => :switch, "\t" => :switch, "/" => :switch,
      "r" => :refresh, "q" => :quit, "\u0003" => :quit
    }.freeze

    # Escape sequences, matched after the leading ESC.
    ESCAPES = {
      "[A" => :up, "[B" => :down, "[C" => :right, "[D" => :left,
      "OA" => :up, "OB" => :down, "OC" => :right, "OD" => :left,
      "[5~" => :page_up, "[6~" => :page_down, "[H" => :top, "[F" => :bottom
    }.freeze

    FOOTER = "j/k move  l/h open/close  e/E expand/all  f all files  z zoom  " \
             "enter edit  d diff  s switch  r refresh  q quit"

    # Files listed per prompt before "… N more"; f lifts it everywhere.
    FILE_CAP = 6

    attr_reader :repo, :session, :switcher

    def initialize(io: $stdout, input: $stdin, catalog: Catalog.new, size: nil,
                   cwd: Dir.pwd)
      @io = io
      @input = input
      @catalog = catalog
      @fixed_size = size
      @cwd = cwd
      @pending = +""
      @cursor = 0
      @offset = 0
      @zoomed = {}
      @open_files = {}
      @all_files = {}
      @all_everywhere = false
      @stats = {}
      @hunks = {}
      @signal = nil
      @repos = @catalog.repos
      start_session
    end

    def run
      return (@io.puts(render.join("\n")) || 0) unless @input.tty?

      require "io/console"
      @io.print "\e[?1049h\e[?25l"
      @input.raw(intr: false) { loop_keys }
    ensure
      @io.print "\e[?25h\e[?1049l" if @input.tty?
    end

    # One key's worth of state change. Public so tests can drive the UI
    # without a terminal. Printable characters arrive as strings while the
    # switcher is open, since there they are typed into its filter.
    def press(key)
      return press_switcher(key) if @switcher

      key = KEYS[key] || key if key.is_a?(String)
      case key
      when :down then move(1)
      when :up then move(-1)
      when :top then @cursor = 0
      when :bottom then @cursor = selectable.size - 1
      when :page_down then move(body_rows / 2)
      when :page_up then move(-(body_rows / 2))
      when :right then expand
      when :left then collapse
      when :zoom then toggle_zoom
      when :open then open_selected
      when :diff then page_diff
      when :all_files then @all_everywhere = !@all_everywhere
      when :expand_here then toggle_here
      when :expand_all then toggle_everywhere
      when :switch then open_switcher
      when :refresh then refresh(sweep: true)
      end
    end

    def selected
      selectable[@cursor]
    end

    # ---- rendering -------------------------------------------------------

    def render
      h, w = size
      lines = [header_line(w), Format.dim("─" * w, tty)]
      rows = build_rows
      sel = selectable_in(rows)
      @cursor = @cursor.clamp(0, [sel.size - 1, 0].max)
      keep_visible(rows, sel[@cursor], body_rows)
      rows[@offset, body_rows].to_a.each do |row|
        lines << draw_row(row, w, row.equal?(sel[@cursor]))
      end
      lines << Format.dim(fit("  #{empty_text}", w), tty) if rows.empty?
      lines << "" while lines.size < h - 1
      lines << footer_line(w)
      @switcher ? overlay(lines, w, h) : lines
    end

    private

    # ---- session ---------------------------------------------------------

    # The newest session in the repo you are standing in, else the newest
    # anywhere. Only the chosen repo is swept: sweeping every repo at start
    # would `git add -A` each worktree just to open the viewer.
    def start_session
      here = Project.canonicalize(@cwd)
      repo = @repos.find { |r| here == r.root || here.start_with?("#{r.root}/") }
      repo ||= @repos.first
      return unless repo

      show(repo, nil, sweep: true)
    end

    def show(repo, session_id, sweep: false)
      @repo = repo
      repo.shadow.sweep! if sweep
      @catalog.reset(repo.shadow)
      @sessions = @catalog.sessions(repo.shadow)
      @session = @sessions.find { |s| s.id == session_id } || @sessions.first
      @cursor = 0
      @offset = 0
      @signal = signal_stamp
    end

    def entries
      @session ? @session.entries : []
    end

    # Prompts and branch commits, newest first. A prompt is placed by when it
    # started, so a commit the agent made during that turn sits just above it
    # -- prompt, then its commit -- rather than below the prompt it came from.
    def timeline
      return [] unless @session

      commits = @catalog.commits(@repo.shadow, @session)
      prompts = entries.each_with_index.map { |e, i| [e, (e[:started] || e[:time]).to_i, 1, i] }
      dated = commits.each_with_index.map { |c, i| [c, c[:time].to_i, 0, i] }
      (prompts + dated).sort_by { |_, at, kind, i| [-at, kind, i] }.map(&:first)
    end

    def commit?(e)
      e[:kind] == "git-commit"
    end

    # ---- rows ------------------------------------------------------------

    Row = Struct.new(:kind, :entry, :file, :hunk, :text, :rest, keyword_init: true) do
      def key
        [kind, entry && entry[:sha], file && file[:path], hunk && hunk[:line], text]
      end
    end

    def build_rows
      rows = []
      timeline.each_with_index do |e, i|
        rows << Row.new(kind: :rule) unless i.zero?
        rows << Row.new(kind: :prompt, entry: e)
        zoom_lines(e).each { |t| rows << Row.new(kind: :text, entry: e, text: t) } if @zoomed[e[:sha]]
        if e[:kind] == "branch-change"
          rows << Row.new(kind: :text, entry: e, text: "branch change -- diff spans a checkout")
          next
        end
        files = stat_for(e)[:files]
        shown = @all_everywhere || @all_files[e[:sha]] ? files : files.first(FILE_CAP)
        shown.each do |f|
          rows << Row.new(kind: :file, entry: e, file: f)
          next unless @open_files[[e[:sha], f[:path]]]

          hunks_for(e, f).each { |hk| rows << Row.new(kind: :hunk, entry: e, file: f, hunk: hk) }
        end
        rest = files.size - shown.size
        rows << Row.new(kind: :more, entry: e, rest: rest) if rest.positive?
      end
      rows
    end

    # Rebuilt on every call: expanding a file or zooming a prompt changes
    # the rows, and a stale list would move the cursor through rows that are
    # no longer on screen. Cheap, since stats and hunks are cached.
    def selectable
      selectable_in(build_rows)
    end

    def selectable_in(rows)
      rows.select { |r| %i[prompt file hunk more].include?(r.kind) }
    end

    def keep_visible(rows, row, height)
      return @offset = 0 unless row

      idx = rows.index { |r| r.equal?(row) } || 0
      @offset = idx if idx < @offset
      @offset = idx - height + 1 if idx >= @offset + height
      @offset = @offset.clamp(0, [rows.size - height, 0].max)
    end

    def body_rows
      size[0] - 3
    end

    def draw_row(row, w, selected)
      segs = row_segments(row, w)
      return Format.paint(fit(segs.map(&:first).join, w), 7, tty) if selected

      segs.map { |t, c| c ? Format.paint(t, c, tty) : t }.join
    end

    # Each row is built as [text, colour] segments sized to exactly `w`, with
    # the counts in one fixed column so every +/- lines up whatever the depth.
    def row_segments(row, w)
      case row.kind
      when :rule then [[fit("  #{"╌" * (w - 4)}", w), 2]]
      when :text then [[fit("       #{row.text}", w), row.text.start_with?("branch") ? 31 : 2]]
      when :more
        [[fit("         … #{row.rest} more file#{"s" unless row.rest == 1}  (l)", w), 2]]
      when :prompt then prompt_segments(row.entry, w)
      when :file then file_segments(row, w)
      when :hunk then hunk_segments(row.hunk, w)
      end
    end

    STATE_COLOR = { "local" => 33, "pushed" => 34, "merged" => 32 }.freeze

    def prompt_segments(e, w)
      return commit_segments(e, w) if commit?(e)

      t = @catalog.totals(@repo.shadow, e)
      mark = @zoomed[e[:sha]] ? "▾" : "▸"
      lead = " #{mark} #{age(e[:time]).rjust(3)}  "
      who = @session&.manual ? "#{Format.who(e).ljust(4)} " : ""
      counts = counts_segments(t[:added], t[:deleted], dim: false)
      room = w - lead.length - who.length - Format::COUNTS_WIDTH - 1
      [[lead, 2], [who, 2], [fit(clean(e[:subject]), room), 1], [" ", nil]] + counts
    end

    # A commit reads differently from a prompt at a glance: a coloured dot
    # and its sha in front, how far it has got (local/pushed/merged) behind.
    def commit_segments(e, w)
      t = @catalog.totals(@repo.shadow, e)
      mark = @zoomed[e[:sha]] ? "▾" : "▸"
      lead = " #{mark} #{age(e[:time]).rjust(3)}  "
      colour = STATE_COLOR[e[:state]] || 2
      state = e[:state].to_s.ljust(7)
      room = w - lead.length - 2 - e[:short].length - 1 - state.length - Format::COUNTS_WIDTH - 1
      [[lead, 2], ["● ", colour], ["#{e[:short]} ", 33], [fit(clean(e[:subject]), room), nil],
       [state, colour], [" ", nil]] + counts_segments(t[:added], t[:deleted], dim: true)
    end

    def file_segments(row, w)
      f = row.file
      label = Format::STATUS_LABEL[f[:status]] || f[:status].to_s.downcase
      colour = Format::STATUS_COLOR[f[:status]] || 37
      open = @open_files[[row.entry[:sha], f[:path]]]
      mark = drillable?(f) ? (open ? "▾" : "▸") : " "
      lead = "     #{mark} "
      room = w - lead.length - 6 - Format::COUNTS_WIDTH - 1
      counts = f[:binary] ? [["bin".rjust(Format::COUNTS_WIDTH), 2]] : counts_segments(f[:added], f[:deleted], dim: open)
      [[lead, 2], [label.ljust(5), colour], [" ", nil], [squeeze(f[:path], room), open ? 2 : nil],
       [" ", nil]] + counts
    end

    def hunk_segments(hk, w)
      label = hk[:symbol].to_s.empty? ? "line #{hk[:line]}" : "#{hk[:symbol]}:#{hk[:line]}"
      lead = "           "
      room = w - lead.length - Format::COUNTS_WIDTH - 1
      [[lead, nil], [fit(label, room), 36], [" ", nil]] + counts_segments(hk[:added], hk[:deleted], dim: false)
    end

    def counts_segments(added, deleted, dim:)
      plus = "+#{added}".rjust(Format::ADDED_CELL)
      minus = "-#{deleted}".ljust(Format::DELETED_CELL)
      [[plus, dim ? 2 : 32], [" ", nil], [minus, dim ? 2 : 31]]
    end

    def header_line(w)
      return fit(" agent diff", w) unless @session

      t = @catalog.session_totals(@repo.shadow, @session)
      left = " #{@repo.name} › #{clean(@session.title)}"
      right = "#{@session.agent} · #{@session.entries.size} prompt#{"s" unless @session.entries.size == 1} · " \
              "#{commit_summary}+#{t[:added]} -#{t[:deleted]}  [s] switch "
      room = w - right.length
      Format.bold(fit(left, room), tty) + Format.dim(right, tty)
    end

    # "3 commits (1 local) · ": what of the session's work is still only on
    # this machine.
    def commit_summary
      commits = @catalog.commits(@repo.shadow, @session)
      return "" if commits.empty?

      local = commits.count { |c| c[:state] == "local" }
      detail = local.positive? ? " (#{local} local)" : ""
      "#{commits.size} commit#{"s" unless commits.size == 1}#{detail} · "
    end

    def footer_line(w)
      text = @flash ? " #{@flash}" : " #{FOOTER}"
      @flash = nil
      Format.dim(fit(text, w), tty)
    end

    def empty_text
      return "no tracked repos yet -- agent-diff init in a repo, or let a hooked agent run" if @repos.empty?

      "no prompts recorded in #{@repo&.name}"
    end

    # ---- expand / collapse -----------------------------------------------

    def drillable?(f)
      %w[M R].include?(f[:status]) && !f[:binary]
    end

    def expand
      row = selected
      return unless row

      case row.kind
      when :prompt then @zoomed[row.entry[:sha]] = true
      when :file
        if drillable?(row.file)
          @open_files[[row.entry[:sha], row.file[:path]]] = true
        else
          open_selected
        end
      when :more then @all_files[row.entry[:sha]] = true
      when :hunk then open_selected
      end
    end

    # h steps out: a block goes back to its file, an open file closes, a file
    # goes back to its prompt, a zoomed prompt un-zooms.
    def collapse
      row = selected
      return unless row

      case row.kind
      when :hunk then select_row(:file, row.entry, row.file)
      when :file
        key = [row.entry[:sha], row.file[:path]]
        @open_files.delete(key) ? nil : select_row(:prompt, row.entry)
      when :more then select_row(:prompt, row.entry)
      when :prompt then @zoomed.delete(row.entry[:sha])
      end
    end

    # e: open or close what the cursor is on. A file opens into its blocks,
    # a block closes back to its file, a prompt opens or closes all its files.
    def toggle_here
      row = selected
      return unless row

      case row.kind
      when :file
        return flash("new and deleted files have no blocks") unless drillable?(row.file)

        key = [row.entry[:sha], row.file[:path]]
        @open_files.delete(key) || (@open_files[key] = true)
      when :hunk
        @open_files.delete([row.entry[:sha], row.file[:path]])
        select_row(:file, row.entry, row.file)
      when :prompt then toggle_files(drillable_keys([row.entry]))
      when :more then @all_files[row.entry[:sha]] = true
      end
    end

    # E: every file in the session open into its blocks, or all closed again.
    def toggle_everywhere
      row = selected
      toggle_files(drillable_keys(timeline))
      # The cursor's block may have gone; land on its file instead.
      select_row(:file, row.entry, row.file) if row&.kind == :hunk
    end

    # Opens them all unless they are all open already, then closes them.
    def toggle_files(keys)
      return if keys.empty?

      if keys.all? { |k| @open_files[k] }
        keys.each { |k| @open_files.delete(k) }
      else
        keys.each { |k| @open_files[k] = true }
      end
    end

    def drillable_keys(list)
      list.reject { |e| e[:kind] == "branch-change" }.flat_map do |e|
        stat_for(e)[:files].select { |f| drillable?(f) }.map { |f| [e[:sha], f[:path]] }
      end
    end

    def toggle_zoom
      row = selected
      return unless row

      sha = row.entry[:sha]
      @zoomed[sha] ? @zoomed.delete(sha) : (@zoomed[sha] = true)
      select_row(:prompt, row.entry)
    end

    def select_row(kind, entry, file = nil)
      idx = selectable.index do |r|
        r.kind == kind && r.entry[:sha] == entry[:sha] && (file.nil? || r.file[:path] == file[:path])
      end
      @cursor = idx if idx
    end

    def move(delta)
      @cursor = (@cursor + delta).clamp(0, [selectable.size - 1, 0].max)
    end

    # The prompt as typed, wrapped, with branch and agent -- the "which chat
    # made this" detail that a one-line label leaves out.
    def zoom_lines(e)
      text = e[:prompt].to_s.strip.empty? ? e[:subject] : e[:prompt]
      width = size[1] - 10
      who = commit?(e) ? e[:author] : (e[:agent] || Format.who(e))
      meta = [who, e[:branch], e[:short], e[:time].strftime("%b %-d %H:%M"), e[:state]]
      wrap(clean(text), width).first(40) + [meta.compact.join(" · ")]
    end

    # ---- actions ---------------------------------------------------------

    def open_selected
      row = selected
      return toggle_zoom if row&.kind == :prompt
      return expand if row&.kind == :more
      return unless row&.file

      path = File.join(@repo.root, row.file[:path])
      return flash("#{row.file[:path]} no longer exists") unless File.exist?(path)

      line = row.hunk ? row.hunk[:line] : (hunks_for(row.entry, row.file).first&.dig(:line) || 1)
      cmd = Editor.command(path, line)
      return flash("no editor found: set $EDITOR (or AGENT_DIFF_EDITOR)") unless cmd

      suspend { system(*cmd) || flash("#{cmd.first} exited with an error") }
    end

    # The real diff, in a pager, for when the counts are not enough.
    def page_diff
      row = selected
      return unless row

      patch = @repo.shadow.patch(row.entry[:sha], path: row.file&.dig(:path))
      return flash("no diff") if patch.strip.empty?

      pager = ENV["AGENT_DIFF_PAGER"] || (Editor.on_path?("less") ? "less -R" : "more")
      suspend do
        IO.popen(Shellwords.split(pager), "w") { |io| io.write(colour_patch(patch)) }
      rescue Errno::EPIPE
        nil
      rescue Errno::ENOENT
        flash("pager not found: #{pager} (set AGENT_DIFF_PAGER)")
      end
    end

    def colour_patch(patch)
      patch.each_line.map do |l|
        code = if l.start_with?("diff --git") then "1;33"
               elsif l.start_with?("+++", "---", "index ") then 2
               elsif l.start_with?("@@") then 36
               elsif l.start_with?("+") then 32
               elsif l.start_with?("-") then 31
               end
        code ? "\e[#{code}m#{l.chomp}\e[0m\n" : l
      end.join
    end

    def suspend
      @io.print "\e[?25h\e[?1049l"
      @input.respond_to?(:cooked) && @input.tty? ? @input.cooked { yield } : yield
      @io.print "\e[?1049h\e[?25l"
    end

    def flash(message)
      @flash = message
    end

    # ---- switcher --------------------------------------------------------

    # Every session in every tracked repo, newest first, filtered by typing.
    # Each repo's "hand edits & commits" is listed too.
    Choice = Struct.new(:repo, :session, :label, keyword_init: true)

    def open_switcher
      choices = @repos.flat_map do |r|
        list = r.equal?(@repo) ? @sessions : @catalog.sessions(r.shadow)
        list.map do |s|
          Choice.new(repo: r, session: s,
                     label: "#{r.name}  #{clean(s.title)}  #{s.agent} #{s.entries.size}p")
        end
      end
      choices.sort_by! { |c| -c.session.last_at.to_i }
      @switcher = { choices: choices, query: +"", cursor: 0 }
      current = choices.index { |c| c.repo.equal?(@repo) && c.session.id == @session&.id }
      @switcher[:cursor] = current || 0
    end

    def switcher_matches
      words = @switcher[:query].downcase.split
      @switcher[:choices].select { |c| words.all? { |w| c.label.downcase.include?(w) } }
    end

    def press_switcher(key)
      sw = @switcher
      case key
      when :escape, :quit, "\u0003" then @switcher = nil
      when :down, "\u000e" then sw[:cursor] += 1
      when :up, "\u0010" then sw[:cursor] -= 1
      when :page_down then sw[:cursor] += 10
      when :page_up then sw[:cursor] -= 10
      when "\r", "\n", :open
        pick = switcher_matches[sw[:cursor]]
        @switcher = nil
        show(pick.repo, pick.session.id, sweep: true) if pick
        return
      when "\u007f", "\b"
        sw[:query] = sw[:query][0...-1]
        sw[:cursor] = 0
      when String
        if key.match?(/\A[[:print:]]\z/)
          sw[:query] << key
          sw[:cursor] = 0
        end
      end
      sw[:cursor] = sw[:cursor].clamp(0, [switcher_matches.size - 1, 0].max) if @switcher
    end

    def overlay(lines, w, h)
      bw = [(w * 0.8).round, 50].max.clamp(0, w)
      bh = [(h * 0.7).round, 8].max.clamp(0, h - 1)
      x = (w - bw) / 2
      y = [(h - bh) / 2, 0].max
      matches = switcher_matches
      rows = bh - 4
      cur = @switcher[:cursor]
      off = (cur - rows + 1).clamp(0, [matches.size - rows, 0].max)
      inner = bw - 2
      box = []
      title = "─ switch session "
      box << Format.paint("╭#{title}#{"─" * [inner - title.length, 0].max}╮", "1;32", tty)
      box << "#{edge}#{fit(" > #{@switcher[:query]}▏", inner)}#{edge}"
      box << "#{edge}#{Format.dim("─" * inner, tty)}#{edge}"
      rows.times do |i|
        c = matches[off + i]
        text = c ? choice_line(c, inner) : " " * inner
        text = Format.paint(text, 7, tty) if c && off + i == cur
        box << "#{edge}#{text}#{edge}"
      end
      count = " #{matches.size}/#{@switcher[:choices].size} · enter go · esc close "
      box << Format.paint("╰#{"─" * [inner - count.length, 0].max}#{count}╯", "1;32", tty)
      box.each_with_index do |b, i|
        # The frame underneath is replaced line by line rather than spliced:
        # cutting a coloured line at a column would split escape sequences.
        lines[y + i] = "#{" " * x}#{b}"
      end
      lines
    end

    def choice_line(c, width)
      s = c.session
      age_s = age(s.last_at).rjust(4)
      repo = c.repo.name[0, 14].ljust(14)
      tail = " #{s.agent} #{s.entries.size.to_s.rjust(3)}p "
      room = width - age_s.length - repo.length - tail.length - 4
      "#{age_s}  #{repo}  #{fit(clean(s.title), room)}#{tail}"
    end

    def edge
      Format.paint("│", "1;32", tty)
    end

    # ---- live updates ----------------------------------------------------

    # A snapshot touches the repo's signal file; a commit, push, fetch or
    # merge in the real repo writes its reflogs and refs. Either re-reads the
    # session.
    def signal_stamp
      return nil unless @repo

      paths = [Project.signal_path(@repo.root)] + real_git_paths
      paths.map { |p| File.exist?(p) ? File.mtime(p) : nil }
    end

    def real_git_paths
      @git_dirs ||= {}
      dirs = @git_dirs[@repo.root] ||= begin
        out, _, ok = Open3.capture3("git", "-C", @repo.root, "rev-parse", "--path-format=absolute",
                                    "--git-dir", "--git-common-dir")
        ok.success? ? out.lines.map(&:strip) : []
      end
      return [] unless dirs.size == 2

      git_dir, common = dirs
      [File.join(git_dir, "logs", "HEAD"), File.join(common, "packed-refs"),
       File.join(common, "FETCH_HEAD")] +
        Dir.glob(File.join(common, "logs", "refs", "{heads,remotes}", "**", "*"))
    end

    # Re-read the session in place, keeping the cursor on the same row.
    def repo_changed?
      stamp = signal_stamp
      return false if stamp == @signal

      refresh
      true
    end

    def refresh(sweep: false)
      return unless @repo

      keep = selected&.key
      @stats.clear
      @hunks.clear
      id = @session&.id
      cursor_before = @cursor
      show(@repo, id, sweep: sweep)
      @cursor = selectable.index { |r| r.key == keep } || cursor_before
    end

    def stat_for(e)
      @stats[e[:sha]] ||= @repo.shadow.stat(e[:sha])
    end

    def hunks_for(e, f)
      @hunks[[e[:sha], f[:path]]] ||= @repo.shadow.hunks(e[:sha], f[:path])
    end

    # ---- terminal --------------------------------------------------------

    def loop_keys
      paint
      loop do
        key = read_key(0.5)
        if key.nil?
          paint if size_changed? | (!@switcher && repo_changed?)
          next
        end
        break if (key == :quit || key == "q" || key == "\u0003") && !@switcher

        press(key)
        paint
      end
    end

    def paint
      @last_size = size
      @io.print("\e[H#{render.map { |l| "#{l}\e[K" }.join("\r\n")}\e[J")
      @io.flush
    end

    def size
      return @fixed_size if @fixed_size

      rows, cols = @io.winsize
      [[rows, 8].max, [cols, 40].max]
    rescue StandardError
      [(ENV["LINES"] || 24).to_i, (ENV["COLUMNS"] || 80).to_i]
    end

    def size_changed?
      size != @last_size
    end

    # Decodes one key from whatever has arrived, keeping the rest for the
    # next call -- a held arrow key delivers several sequences in one read.
    # Escape sequences become symbols; everything else stays a character,
    # since the switcher's filter needs the letter itself.
    def read_key(timeout)
      if @pending.empty?
        return nil unless IO.select([@input], nil, nil, timeout)

        @pending << read_available
      end
      if @pending.start_with?("\e")
        @pending << read_available if @pending.size == 1 && IO.select([@input], nil, nil, 0.03)
        ESCAPES.each do |seq, key|
          next unless @pending[1, seq.size] == seq

          @pending = @pending[(1 + seq.size)..]
          return key
        end
        @pending = @pending[1..]
        return :escape
      end
      ch = @pending[0]
      @pending = @pending[1..]
      ch
    end

    def read_available
      @input.read_nonblock(64).force_encoding("UTF-8")
    rescue StandardError
      +""
    end

    def tty
      @io
    end

    # ---- text ------------------------------------------------------------

    def fit(text, width)
      return "" if width <= 0

      text = text.to_s
      text.length > width ? "#{text[0, width - 1]}…" : text.ljust(width)
    end

    # A path keeps its end: the filename is the part worth reading.
    def squeeze(path, width)
      return "" if width <= 0
      return path.ljust(width) if path.length <= width

      "…#{path[-(width - 1)..]}"
    end

    # Prompts arrive with pasted terminal output in them: escape codes, tabs,
    # newlines. None of it belongs on one line.
    def clean(text)
      text.to_s.gsub(/\e\[[0-9;?]*[A-Za-z]/, "").gsub(/[[:cntrl:]]+/, " ").squeeze(" ").strip
    end

    def wrap(text, width)
      width = [width, 20].max
      text.scan(/\S.{0,#{width - 2}}(?=\s|\z)|\S+/)
    end

    def age(time)
      time ? Format.age(time) : "-"
    end
  end
end
