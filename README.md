# agent-diff

**What did that prompt actually change?**

When a few coding agents are working at once and each turn runs for a minute
or two, the codebase gets away from you. `agent-diff` records what every
prompt changed, files added, removed and edited, with line counts, and gives
you a terminal browser that maps those changes back to the agent session and
prompt that made them.

```
 my-app › Add rate limiting to the API              claude · 3 prompts · +212 -41  [s] switch
────────────────────────────────────────────────────────────────────────────────────────────
 ▸  4m  add a per-user limit, 100 requests a minute                              +164 -12
       ▾ mod   src/middleware/rate_limit.rb                                      +98 -0
             class RateLimiter:12                                                +61 -0
             def call:40                                                         +37 -0
         new   test/middleware/rate_limit_test.rb                                +66 -0
       ▸ mod   config/routes.rb                                                   +0 -12
   ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 ▾ 11m  the limiter should return 429 with a Retry-After header                  +48 -29
        the limiter should return 429 with a Retry-After header, not 503, and the
        tests need to cover the header value
        claude · feature/rate-limit · 3f9c2e1 · Mar 4 14:02
       ▸ mod   src/middleware/rate_limit.rb                                      +31 -22
       ▸ mod   test/middleware/rate_limit_test.rb                                +17 -7
```

It works with **Claude Code**, **Codex** and **Cursor** through their hooks,
and catches everything else (other agents, your own edits, commits) by
looking at the working tree.

## Install

Needs Ruby 3.0+ and git. No gems.

```bash
git clone https://github.com/markdoeswork/agent-diff.git
cd agent-diff
./install.sh
```

`install.sh` links `agent-diff` into `~/.local/bin` (`BIN_DIR` overrides) and
adds hooks to `~/.claude/settings.json` and, if they are installed, Codex's
`~/.codex/hooks.json` (`CODEX_HOME` overrides) and Cursor's
`~/.cursor/hooks.json`. Your other hooks are left alone. It is safe to re-run,
and re-running after moving the checkout re-points everything.
`./install.sh --no-hooks` links only; `./install.sh --uninstall` removes the
link and the hooks but keeps recorded history.

Codex runs a new hook only after you trust it, so the first Codex session after
installing asks you to review the two agent-diff hooks. Approve them once and
Codex runs them from then on.

From then on, every prompt you give Claude Code, Codex or Cursor inside a git
repo is recorded. Run `agent-diff` to look.

## The browser

`agent-diff` with no arguments opens one session, its prompts newest first,
each with the files it changed nested underneath. It starts on the newest
session in the repo you run it from, or the newest anywhere.

| Key | |
|---|---|
| `j` / `k`, arrows, `g` / `G`, `Ctrl-D` / `Ctrl-U` | move |
| `l` / `→` | open a file into the blocks that changed; on `… N more`, list the rest |
| `h` / `←` | step back out: block → file → prompt; un-zoom a prompt |
| `z`, `Space` | zoom a prompt: its full text, agent, branch and time |
| `e` | open or close what the cursor is on: a file into its blocks, or every file under a prompt |
| `E` | open every file in the session into its blocks; again to close them all |
| `Enter`, `o` | open the file in your editor at that block (see below) |
| `d` | the real diff of the file (or the whole prompt) in a pager |
| `f` | list every file under every prompt, not just the first six |
| `s`, `/`, `Tab`, `Ctrl-P` | switch session |
| `r` | refresh |
| `q`, `Ctrl-C` | quit |

**The switcher** (`s`) lists every session in every tracked repo, newest
first. Type to filter; words match anywhere in the repo name, session title
and agent. `Enter` jumps there, `Esc` closes it. Work no hook claimed sits
under each repo's "hand edits & commits".

**Session titles** are the ones the agent gave the session: Claude Code's, read
from its transcripts in `~/.claude/projects`, and Codex's thread names, read
from `~/.codex/session_index.jsonl`. Cursor sessions are titled by their first
prompt.

**Blocks** are the enclosing `def`, `class`, `func` and so on. They come from
git's own hunk headers: git ships function-name patterns for Ruby, Python,
Rust, Go, Java, C# and more, and agent-diff turns them on by file extension
from its own attributes file, so nothing is written into your projects. Edits
in several places inside one method fold into a single row, and `Enter` lands
on the method's declaration. New and deleted files don't open into blocks,
since their single hunk would only repeat the row's counts.

The view updates on its own when the repo on screen records a prompt.

**Editor.** `Enter` uses `AGENT_DIFF_EDITOR`, else `$VISUAL`, else `$EDITOR`,
else the first of `nvim`, `vim`, `vi`, `nano`, `hx`, `micro`, `kak` and `emacs`
that is installed. Each is opened at the right line in its own syntax: `+N file`
for the vi family, nano, emacs and kakoune; `file:N` for helix, micro, zed and
Sublime; `--wait -g file:N` for VS Code, Cursor and VSCodium, so the browser
waits for you to close the file. Anything else gets `+N file`.

**Pager.** `d` uses `AGENT_DIFF_PAGER`, else `less -R`, else `more`.

## How it works

Each project gets a **shadow git repository**: a separate `GIT_DIR` pointed at
the real working tree, the same `--git-dir` / `--work-tree` split people use to
keep their dotfiles in a bare repo.

```
Claude / Codex / Cursor hook ──> agent-diff hook ──> one shadow commit per prompt
                                                           │
                                                      agent-diff
                                         (one session at a time; s to switch)
```

Your real repository is never touched: not its `HEAD`, not its index, not its
staging area. `test/shadow_test.rb` asserts that, and it is the first thing to
re-check after changing anything here.

The submit hook (`UserPromptSubmit` / `beforeSubmitPrompt`) caches the prompt
text, because the stop event doesn't carry it. The stop hook (`Stop` / `stop`)
commits the working tree to the shadow with the prompt, session id, agent and
branch as commit trailers, so the history stays queryable with plain git.

### Why not the agents' own checkpoints

Claude Code snapshots files per prompt (that's what `/rewind` restores), but
its docs say changes made by bash commands and by subagents are not tracked,
and agents run a lot of shell. Cursor's checkpoints have no documented layout,
and every other tool has its own format. The one interface they all share is
the filesystem, so agent-diff records the working tree itself. Because the
viewer only reads the shadow repo, supporting another agent is a new hook, not
a viewer change.

### Who changed what

| Source | Row |
|---|---|
| `claude`, `codex`, `cursor` | a hooked prompt: the agent's own turn |
| `you` | changes nobody claimed: hand edits, or an agent with no hook |
| `git` | a real commit in the project |

`you` and `git` rows come from a sweep that runs whenever history is read (the
browser, `list`), so there's no daemon to keep running. It is skipped while an
agent turn is in flight (the submit hook sets a marker, the stop hook clears
it), so an agent's half-finished work isn't claimed as yours. Markers older
than 15 minutes are ignored, so an agent that crashes without firing its stop
hook can't wedge a project. Consecutive hand edits collapse into one growing
row instead of stacking.

A commit moves `HEAD` without touching any file, so commits are found by
comparing the real `HEAD` with the one recorded on the last snapshot, and
their contents are read from the real repo. A checkout between prompts is
labelled `branch change` instead of being reported as an agent writing
thousands of lines.

### Details worth knowing

- **Nothing is written into your project.** Shadow repos live in
  `~/.local/share/agent_diff` (`AGENT_DIFF_HOME` overrides). Each shadow
  stores its project's path in its own git config (`agentdiff.root`).
- **Only git worktrees are tracked.** A plain directory has no `.gitignore` to
  bound what gets captured; pointed at a large data directory, an early build
  produced a 558 MB shadow. Set `AGENT_DIFF_ALLOW_NON_GIT=1` to override.
- `.gitignore` is honoured, `.git/` is always excluded, and binary files count
  as files without line counts.
- **Idle prompts create no commits.** A prompt that changed nothing is a no-op.
- **Two agents in one repo share a shadow** (they share the worktree), and
  their prompts are told apart by session. Commits are serialised with
  `flock`, so concurrent hooks can't race.
- **A hook can never stall a turn.** It exits 0 on every path, logs errors to
  `$AGENT_DIFF_HOME/agent_diff.log`, and takes about 50 ms.
- **Hooks run with a stripped environment.** `bin/agent-diff` picks a real Ruby
  3 binary rather than an asdf/mise shim (`lib/pick_ruby.sh`) and forces UTF-8,
  since with no `LANG` Ruby would read git's output as ASCII. It works under
  `env -i`.

## Commands

| Command | |
|---|---|
| *(none)* | the browser |
| `init [path]` | start tracking a repo by hand (hooks do this for you) |
| `snap [path]` | record a snapshot now (`-m` to label it) |
| `list [path]` | recent prompts and what they changed (`--json`, `-n`) |
| `show <ref> [path]` | one prompt in detail (`--patch` for the diff) |
| `status [path]` | changes since the last prompt |
| `diffcmd <ref> [path]` | print the git command that diffs that prompt |
| `hook` | read a Claude Code, Codex or Cursor hook payload on stdin |
| `paths [path]` | where a project's shadow repo lives |

## Neovim

`nvim/` holds a small picker: `:AgentDiff` lists the current repo's prompts and
opens one's diff in a scratch buffer. With lazy.nvim:

```lua
{
  dir = "~/path/to/agent-diff/nvim",
  name = "agent_diff",
  cmd = { "AgentDiff", "AgentDiffStatus" },
  keys = { { "<leader>ad", "<cmd>AgentDiff<cr>", desc = "Agent diffs (by prompt)" } },
  config = function() require("agent_diff").setup() end,
}
```

## Layout

```
bin/agent-diff          shim: picks a Ruby, runs the CLI
install.sh              link + hooks (--no-hooks, --uninstall)
lib/pick_ruby.sh        find a Ruby 3 that works without a shell profile
lib/agent_diff/
  cli.rb                subcommands
  shadow.rb             the shadow repo (all git logic lives here)
  project.rb            worktree root -> shadow repo path
  claude_hook.rb        Claude Code, Codex + Cursor hook payloads
  catalog.rb            repos, sessions, titles, totals (no rendering)
  browser.rb            the TUI
  editor.rb             which editor, and how it takes a line number
  format.rb             plain terminal output for list/show/status
hooks/
  agent_diff.sh         the hook every agent calls
  install_*_hooks.rb    merge the hooks into each agent's settings
nvim/                   the Neovim picker
test/                   ./test/run.sh
```

## Not done yet

- Retention / garbage collection of old shadow repos, and restoring a single
  prompt.

## License

MIT
