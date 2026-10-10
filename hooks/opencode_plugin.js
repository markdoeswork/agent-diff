// agent-diff for OpenCode. OpenCode has no shell hooks, only plugins, so this
// translates its events into the Claude-style payloads `agent-diff hook`
// already reads: chat.message -> UserPromptSubmit (caches the prompt, seeds
// the baseline), session.idle -> Stop (records the snapshot).
//
// install_opencode_plugin.rb copies this into ~/.config/opencode/plugin/
// with HOOK below pointed at this checkout's hooks/agent_diff.sh.
//
// Like the other hooks it must never break a turn: every failure is
// swallowed, and a hung hook is killed after 30 seconds.

import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const HOOK = "__AGENT_DIFF_HOOK__"

function hook(payload) {
  return new Promise((resolve) => {
    try {
      const child = spawn("bash", [HOOK], {
        env: { ...process.env, AGENT_DIFF_AGENT: "opencode" },
        stdio: ["pipe", "ignore", "ignore"],
      })
      const timer = setTimeout(() => child.kill("SIGKILL"), 30_000)
      child.on("error", () => { clearTimeout(timer); resolve() })
      child.on("close", () => { clearTimeout(timer); resolve() })
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(payload))
    } catch {
      resolve()
    }
  })
}

// OpenCode titles a session after its first exchange. The viewer can't read
// OpenCode's database, so the title is left where it looks for one.
function saveTitle(id, title) {
  try {
    const home = process.env.AGENT_DIFF_HOME || join(homedir(), ".local/share/agent_diff")
    const dir = join(home, "titles")
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, `${id.replace(/[^A-Za-z0-9_-]/g, "_")}.txt`), title)
  } catch {}
}

export const AgentDiff = async ({ directory }) => {
  // Sessions with a prompt in flight. session.idle also fires for sessions
  // that never ran a prompt here, and must not record those.
  const busy = new Set()
  // Subagent sessions share the parent's worktree; recording them would cut
  // the parent's turn in two, so their edits stay with the parent.
  const children = new Set()
  const titles = new Map()

  return {
    "chat.message": async (input, output) => {
      const id = input.sessionID
      if (!id || children.has(id)) return
      const prompt = (output.parts || [])
        .filter((p) => p.type === "text" && !p.synthetic && !p.ignored)
        .map((p) => p.text)
        .join("\n")
        .trim()
      busy.add(id)
      await hook({ hook_event_name: "UserPromptSubmit", session_id: id, prompt, cwd: directory })
    },

    event: async ({ event }) => {
      const props = event.properties || {}
      if (event.type === "session.created" || event.type === "session.updated") {
        const info = props.info || {}
        if (info.parentID) children.add(info.id)
        // Until it names one, a session is "New session - <timestamp>"; the
        // viewer's fallback, the first prompt, says more than that.
        const placeholder = /^(New|Child) session - \d{4}-/.test(info.title || "")
        if (info.id && !info.parentID && info.title && !placeholder && titles.get(info.id) !== info.title) {
          titles.set(info.id, info.title)
          saveTitle(info.id, info.title)
        }
        return
      }
      const idle =
        event.type === "session.idle" ||
        (event.type === "session.status" && props.status?.type === "idle")
      if (!idle || !busy.delete(props.sessionID)) return
      await hook({ hook_event_name: "Stop", session_id: props.sessionID, cwd: directory })
    },
  }
}
