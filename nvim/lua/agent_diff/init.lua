-- agent_diff — browse per-prompt agent diffs from inside neovim.
--
-- The CLI owns all the git logic; this module only renders. `agent-diff list
-- --json` gives the prompt list, and `agent-diff show --patch` gives a diff
-- that is displayed in a scratch buffer with filetype=diff.

local M = {}

M.config = {
  -- Resolved lazily so the module works from any checkout location.
  bin = nil,
  limit = 30,
}

local function bin()
  if M.config.bin then
    return M.config.bin
  end
  local here = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(here, ":h:h:h:h")
  local candidate = root .. "/bin/agent-diff"
  M.config.bin = vim.fn.executable(candidate) == 1 and candidate or "agent-diff"
  return M.config.bin
end

local function root_dir()
  local buf = vim.api.nvim_buf_get_name(0)
  local dir = buf ~= "" and vim.fn.fnamemodify(buf, ":h") or vim.fn.getcwd()
  return dir
end

local function run(args)
  local cmd = vim.list_extend({ bin() }, args)
  local out = vim.system(cmd, { text = true }):wait()
  if out.code ~= 0 then
    return nil, (out.stderr or ""):gsub("%s+$", "")
  end
  return out.stdout, nil
end

---@return table[]|nil entries, string|nil err
function M.entries(opts)
  opts = opts or {}
  local args = { "list", "--json", "-n", tostring(opts.limit or M.config.limit) }
  if opts.pane then
    vim.list_extend(args, { "--pane", opts.pane })
  end
  table.insert(args, opts.dir or root_dir())

  local out, err = run(args)
  if not out then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not parse agent-diff output"
  end
  return decoded, nil
end

-- A prompt's diff in a throwaway buffer. Uses filetype=diff so whatever
-- highlighting is already configured applies.
function M.open_patch(entry, dir)
  local out, err = run({ "show", "--patch", entry.sha, dir or root_dir() })
  if not out then
    vim.notify("agent_diff: " .. (err or "failed"), vim.log.levels.ERROR)
    return
  end
  if out == "" then
    vim.notify("agent_diff: empty diff", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n", { trimempty = false }))
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "agent-diff://" .. entry.short .. " " .. (entry.subject or ""))

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true })
end

local function label(entry)
  local files = entry.files and #entry.files or 0
  local plural = files == 1 and "" or "s"
  return string.format(
    "%s  %s  (%d file%s +%d -%d)",
    entry.short,
    entry.subject or "",
    files,
    plural,
    entry.added or 0,
    entry.deleted or 0
  )
end

-- snacks.picker when available (it is, via LazyVim), else vim.ui.select.
function M.pick(opts)
  opts = opts or {}
  local dir = opts.dir or root_dir()
  local entries, err = M.entries(vim.tbl_extend("force", opts, { dir = dir }))
  if not entries then
    vim.notify("agent_diff: " .. (err or "no data"), vim.log.levels.ERROR)
    return
  end
  if #entries == 0 then
    vim.notify("agent_diff: no prompts recorded yet", vim.log.levels.INFO)
    return
  end

  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    local items = {}
    for i, entry in ipairs(entries) do
      table.insert(items, { idx = i, text = label(entry), entry = entry, preview = { text = "" } })
    end
    snacks.picker.pick({
      title = "Agent prompts — " .. vim.fn.fnamemodify(dir, ":t"),
      items = items,
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          M.open_patch(item.entry, dir)
        end
      end,
    })
    return
  end

  vim.ui.select(entries, { prompt = "Agent prompts", format_item = label }, function(choice)
    if choice then
      M.open_patch(choice, dir)
    end
  end)
end

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("AgentDiff", function()
    M.pick()
  end, { desc = "Browse per-prompt agent diffs" })

  vim.api.nvim_create_user_command("AgentDiffStatus", function()
    local out, err = run({ "status", root_dir() })
    vim.notify(out or err or "", vim.log.levels.INFO)
  end, { desc = "Changes since the last agent prompt" })

  return M
end

return M
