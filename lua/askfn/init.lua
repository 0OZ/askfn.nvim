local conversation = require("askfn.conversation")
local docker = require("askfn.docker")
local input = require("askfn.input")
local request = require("askfn.request")
local stream = require("askfn.stream")
local symbol = require("askfn.symbol")

local M = {}

local DOCUMENT_SYMBOL = "textDocument/documentSymbol"
local SYMBOL_TIMEOUT_MS = 1000
local ESC = "\27"
local NAMESPACE = vim.api.nvim_create_namespace("askfn")
local TARGET_HIGHLIGHT = "AskfnTarget"

---Filetypes whose language server has no useful function symbols; the unit is found in the text.
---@type table<string, fun(lines: string[], cursor_line: integer): askfn.Target?>
local TEXT_SCOPES = { dockerfile = docker.stage_at }

---@class askfn.Keys
---@field ask string|false normal: ask about the function under the cursor; visual: about the selection
---@field textobject string|false visual/operator-pending: the whole function including its signature
---@field follow_up string|false answer window: ask another question in the same session
---@field handoff string|false answer window: continue the conversation interactively
---@field yank string|false answer window: copy the last answer
---@field yank_code string|false answer window: copy the first code block of the last answer

---@class askfn.Config
---@field backend string key into `backends`
---@field backends table<string, askfn.Backend>
---@field keys askfn.Keys
---@field animate boolean grow the answer window smoothly
---@field handoff fun(argv: string[]) opens the interactive agent; `argv` resumes the asked session
local defaults = {
  backend = "claude",
  backends = {
    claude = {
      cmd = {
        "claude",
        "-p",
        "--model",
        "claude-sonnet-5-5",
        "--effort",
        "xhigh",
        "--permission-mode",
        "plan",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
      },
      output = "claude-stream-json",
      session = { start = "--session-id", resume = "--resume", interactive = { "claude", "--resume" } },
    },
    pi = { cmd = { "pi", "-p", "--thinking", "xhigh" }, output = "text" },
  },
  keys = {
    ask = "<leader>aq",
    textobject = "af",
    follow_up = "<CR>",
    handoff = "o",
    yank = "gy",
    yank_code = "gY",
  },
  animate = true,
  handoff = function(argv)
    vim.cmd("botright vnew")
    vim.fn.jobstart(argv, { term = true })
    vim.cmd.startinsert()
  end,
}

local config = defaults

---@return askfn.Target?
local function function_at_cursor()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local text_scope = TEXT_SCOPES[vim.bo.filetype]
  if text_scope then
    return text_scope(vim.api.nvim_buf_get_lines(0, 0, -1, false), cursor_line)
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  local responses = vim.lsp.buf_request_sync(0, DOCUMENT_SYMBOL, params, SYMBOL_TIMEOUT_MS)
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

---Marks the lines being asked about.
---@param bufnr integer
---@param target askfn.Target
---@return fun() clear removes the mark again
local function highlight(bufnr, target)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, target.end_line - 1, target.end_line, false)[1]
  local mark = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, target.start_line - 1, 0, {
    end_row = target.end_line - 1,
    end_col = #last_line,
    hl_group = TARGET_HIGHLIGHT,
    hl_eol = true,
  })
  return function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_del_extmark(bufnr, NAMESPACE, mark)
    end
  end
end

---@param target askfn.Target?
local function ask(target)
  if not target then
    vim.notify("askfn: no function under the cursor (is a language server attached?)", vim.log.levels.WARN)
    return
  end
  local executable = config.backends[config.backend].cmd[1]
  if vim.fn.executable(executable) ~= 1 then
    vim.notify(("askfn: %q is not executable"):format(executable), vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local code = vim.api.nvim_buf_get_lines(bufnr, target.start_line - 1, target.end_line, false)
  local label = ("%s · %s"):format(config.backend, target.name or "selection")
  local clear_highlight = highlight(bufnr, target)

  input.open((" %s "):format(label), {
    on_cancel = clear_highlight,
    on_submit = function(question)
      conversation.start({
        config = config,
        label = label,
        question = question,
        prompt = request.prompt({
          path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":."),
          filetype = vim.bo[bufnr].filetype,
          target = target,
          code = code,
          question = question,
        }),
        on_close = clear_highlight,
      })
    end,
  })
end

---@param merged askfn.Config
local function validate(merged)
  if not merged.backends[merged.backend] then
    error(("askfn: unknown backend %q"):format(merged.backend))
  end
  for name, backend in pairs(merged.backends) do
    if not stream.is_format(backend.output) then
      error(("askfn: backend %q has unknown output format %q"):format(name, tostring(backend.output)))
    end
  end
end

---@param opts askfn.Config? partial config, merged over the defaults
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", defaults, opts or {})
  validate(merged)
  config = merged
  vim.api.nvim_set_hl(0, TARGET_HIGHLIGHT, { default = true, link = "Visual" })

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
