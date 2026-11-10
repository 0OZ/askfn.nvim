local request = require("askfn.request")
local symbol = require("askfn.symbol")
local ui = require("askfn.ui")

local M = {}

local DOCUMENT_SYMBOL = "textDocument/documentSymbol"
local SYMBOL_TIMEOUT_MS = 1000
local ESC = "\27"
local FOOTER_CLOSE = " q close "
local FOOTER_HANDOFF = " q close · %s continue in terminal "

---@class askfn.Keys
---@field ask string|false normal: ask about the function under the cursor; visual: about the selection
---@field textobject string|false visual/operator-pending: the whole function including its signature
---@field handoff string|false inside the answer window: continue the conversation interactively

---@class askfn.Config
---@field backend string key into `backends`
---@field backends table<string, askfn.Backend>
---@field keys askfn.Keys
---@field handoff fun(argv: string[]) opens the interactive agent; `argv` resumes the asked session
local defaults = {
  backend = "claude",
  backends = {
    claude = {
      cmd = { "claude", "-p", "--model", "claude-sonnet-5-5", "--effort", "xhigh" },
      session = { flag = "--session-id", resume = { "claude", "--resume" } },
    },
    pi = { cmd = { "pi", "-p", "--thinking", "xhigh" } },
  },
  keys = { ask = "<leader>aq", textobject = "af", handoff = "o" },
  handoff = function(argv)
    vim.cmd("botright vnew")
    vim.fn.jobstart(argv, { term = true })
    vim.cmd.startinsert()
  end,
}

local config = defaults

---@return askfn.Target?
local function function_at_cursor()
  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  local responses = vim.lsp.buf_request_sync(0, DOCUMENT_SYMBOL, params, SYMBOL_TIMEOUT_MS)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, response in pairs(responses or {}) do
    local found = type(response.result) == "table" and symbol.innermost_callable(response.result, cursor_line)
    if found then
      return found
    end
  end
end

---@return askfn.Target
local function visual_selection()
  local from, to = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd.normal({ ESC, bang = true })
  return { start_line = math.min(from, to), end_line = math.max(from, to) }
end

local function select_function()
  local target = function_at_cursor()
  if not target then
    return
  end
  -- `V` toggles linewise visual off when it is already on, so always start from normal mode.
  local in_visual_mode = vim.fn.mode():match("^[vV\22]") ~= nil
  if in_visual_mode then
    vim.cmd.normal({ ESC, bang = true })
  end
  vim.cmd.normal({ ("%dGV%dG"):format(target.start_line, target.end_line), bang = true })
end

---Runs the agent on `prompt` and shows its answer in a float.
---@param backend askfn.Backend
---@param title string
---@param prompt string
local function answer(backend, title, prompt)
  local session = backend.session
  local handoff_key = session and config.keys.handoff
  local session_id = session and request.session_id()
  local footer = handoff_key and FOOTER_HANDOFF:format(handoff_key) or FOOTER_CLOSE
  local view = ui.answer(title, { ("Asking %s…"):format(config.backend) }, footer)

  local answered = false
  local job = vim.system(
    request.argv(backend, prompt, session_id),
    { text = true },
    vim.schedule_wrap(function(result)
      answered = true
      view.set(request.answer_lines(result))
    end)
  )
  view.on_close(function()
    if not job:is_closing() then
      job:kill("sigterm")
    end
  end)

  if handoff_key then
    view.map(handoff_key, function()
      if not answered then
        vim.notify("askfn: still answering, the session can be continued once the answer is in", vim.log.levels.WARN)
        return
      end
      view.close()
      config.handoff(request.resume_argv(session, session_id))
    end)
  end
end

---@param target askfn.Target?
local function ask(target)
  if not target then
    vim.notify("askfn: no function under the cursor (is a language server attached?)", vim.log.levels.WARN)
    return
  end
  local backend = config.backends[config.backend]
  if vim.fn.executable(backend.cmd[1]) ~= 1 then
    vim.notify(("askfn: %q is not executable"):format(backend.cmd[1]), vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local code = vim.api.nvim_buf_get_lines(bufnr, target.start_line - 1, target.end_line, false)
  local title = (" %s · %s "):format(config.backend, target.name or "selection")

  ui.input(title, function(question)
    local prompt = request.prompt({
      path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":."),
      filetype = vim.bo[bufnr].filetype,
      target = target,
      code = code,
      question = question,
    })
    answer(backend, title, prompt)
  end)
end

---@param opts askfn.Config? partial config, merged over the defaults
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", defaults, opts or {})
  if not merged.backends[merged.backend] then
    error(("askfn: unknown backend %q"):format(merged.backend))
  end
  config = merged

  local keys = merged.keys
  if keys.ask then
    vim.keymap.set("n", keys.ask, function()
      ask(function_at_cursor())
    end, { desc = "Ask agent about this function" })
    vim.keymap.set("x", keys.ask, function()
      ask(visual_selection())
    end, { desc = "Ask agent about the selection" })
  end
  if keys.textobject then
    vim.keymap.set({ "x", "o" }, keys.textobject, select_function, { desc = "Function including signature" })
  end
end

return M
