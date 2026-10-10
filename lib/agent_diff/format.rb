# frozen_string_literal: true

module AgentDiff
  # Rendering for the terminal. Colour is emitted only when attached to a tty,
  # so piping to a file or another tool stays clean.
  module Format
    # Who is responsible for a row, in the width a row has: the agent name
    # for a hooked prompt ("claude", "cursor"), "you" for a hand edit, "git"
    # for a commit. Falls back to the pane id for rows written before source
    # was recorded.
    def self.who(entry)
      src = entry[:source].to_s
      return src[0, 7] unless src.empty?

      (entry[:pane_id] || "-")[0, 7]
    end

    module_function

    STATUS_LABEL = { "A" => "new", "D" => "gone", "M" => "mod", "R" => "moved", "C" => "copy" }.freeze
    STATUS_COLOR = { "A" => 32, "D" => 31, "M" => 33, "R" => 36, "C" => 36 }.freeze

    def color?(io = $stdout)
      return false if ENV["NO_COLOR"]

      io.tty?
    end

    def paint(text, code, io = $stdout)
      color?(io) ? "\e[#{code}m#{text}\e[0m" : text
    end

    def dim(text, io = $stdout)
      paint(text, 2, io)
    end

    def bold(text, io = $stdout)
      paint(text, 1, io)
    end

    def age(time, now = Time.now)
      secs = (now - time).to_i
      return "now" if secs < 5
      return "#{secs}s" if secs < 60
      return "#{secs / 60}m" if secs < 3600
      return "#{secs / 3600}h" if secs < 86_400

      "#{secs / 86_400}d"
    end

    def counts(added, deleted, io = $stdout)
      "#{paint("+#{added}", 32, io)} #{paint("-#{deleted}", 31, io)}"
    end

    # The same counts, padded to a fixed cell so every row's "+" lands on one
    # column and the numbers right-align within it. Padding has to be applied
    # to the plain text and the colour wrapped around it: escape codes have no
    # width on screen but do count toward String#rjust, which would shift each
    # coloured column out of line with the others.
    #
    # Sized for the widest plausible diff (+99999 -9999); anything larger just
    # overflows its cell rather than being truncated into a wrong number.
    ADDED_CELL = 6
    DELETED_CELL = 5
    COUNTS_WIDTH = ADDED_CELL + 1 + DELETED_CELL
    #
    # `muted` drops the green/red for plain dim, the same grey the filename
    # beside it uses, so an expanded file's row reads as one uniform summary
    # line and the coloured per-method counts below it carry all the weight.
    # Keeping any colour here left the total competing with the detail.
    def counts_column(added, deleted, io = $stdout, muted: false)
      add_code = muted ? 2 : 32
      del_code = muted ? 2 : 31
      plus = paint("+#{added}".rjust(ADDED_CELL), add_code, io)
      minus = paint("-#{deleted}".ljust(DELETED_CELL), del_code, io)
      "#{plus} #{minus}"
    end

    # One prompt, with its files indented beneath it.
    def entry(entry, stat, io: $stdout, show_files: true, width: 80)
      lines = []
      head = +""
      head << dim(entry[:short], io) << " "
      head << dim(age(entry[:time]).rjust(4), io) << "  "
      head << bold(truncate(entry[:subject], width - 24), io)
      lines << head

      if entry[:kind] == "branch-change"
        lines << "  #{dim("branch change -- diff spans a checkout", io)}"
        return lines
      end

      if show_files
        stat[:files].each do |f|
          label = STATUS_LABEL[f[:status]] || f[:status].to_s.downcase
          colour = STATUS_COLOR[f[:status]] || 37
          delta = f[:binary] ? dim("bin", io) : counts(f[:added], f[:deleted], io)
          path = truncate(f[:path], width - 24)
          lines << "  #{paint(label.ljust(5), colour, io)} #{path.ljust(width - 24)} #{delta}"
        end
      end

      plural = stat[:files].length == 1 ? "" : "s"
      lines << "  #{dim("#{stat[:files].length} file#{plural}", io)}  #{counts(stat[:added], stat[:deleted], io)}"
      lines
    end

    def truncate(text, max)
      text = text.to_s
      return text if max <= 0 || text.length <= max

      "#{text[0, max - 1]}…"
    end
  end
end
