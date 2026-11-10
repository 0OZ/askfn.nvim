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
-- The prompt is one command-line argument and Linux refuses arguments over 128 KB, so the asked code
-- and the whole file sent beside it may not add up to more than this.
local MAX_CONTEXT_BYTES = 100000

---Filetypes whose language server has no useful function symbols; the unit is found in the text.
---@type table<string, fun(lines: string[], cursor_line: integer): askfn.Target?>
local TEXT_SCOPES = { dockerfile = docker.stage_at }

---@class askfn.Keys
---@field ask string|false normal: ask about the function under the cursor; visual: about the selection
---@field ask_file string|false like `ask`, and send the whole file along as context
---@field ask_type string|false normal: ask about the class, struct, enum or impl around the cursor
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
    ask_file = "<leader>aQ",
    ask_type = "<leader>at",
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

---Why nothing was found, so the notice names the real cause. `%s` is the scope's noun.
---@enum askfn.Miss
local MISS = { NO_SERVER = "no_server", NOT_READY = "not_ready", OUTSIDE = "outside" }

---@type table<askfn.Miss, string>
local MISS_NOTICES = {
  [MISS.NO_SERVER] = "askfn: no language server is attached to this buffer",
  [MISS.NOT_READY] = "askfn: the language server has not answered yet, try again in a moment",
  [MISS.OUTSIDE] = "askfn: the cursor is not inside a %s",
}

---@param cursor_line integer
---@param scope askfn.Scope
---@return askfn.Target? target
---@return askfn.Miss? miss set when there is no target
local function target_from_server(cursor_line, scope)
  if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
    return nil, MISS.NO_SERVER
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  local responses = vim.lsp.buf_request_sync(0, DOCUMENT_SYMBOL, params, SYMBOL_TIMEOUT_MS)
  -- A server that is still starting answers with null, an error, or not at all.
  -- Responses are keyed by client id; vim.iter reads a table keyed 1.. as a list, so flatten first.
  local symbol_lists = vim
    .iter(vim.tbl_values(responses or {}))
    :map(function(response)
      return type(response.result) == "table" and response.result or nil
    end)
    :totable()
  if #symbol_lists == 0 then
    return nil, MISS.NOT_READY
  end
  for _, symbols in ipairs(symbol_lists) do
    local found = symbol.innermost(symbols, cursor_line, scope)
    if found then
      return found
    end
  end
  return nil, MISS.OUTSIDE
end

---@param scope askfn.Scope
---@return askfn.Target? target
---@return askfn.Miss? miss set when there is no target
local function target_at_cursor(scope)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local text_scope = scope == symbol.FUNCTION and TEXT_SCOPES[vim.bo.filetype]
  if not text_scope then
    return target_from_server(cursor_line, scope)
  end
  local stage = text_scope(vim.api.nvim_buf_get_lines(0, 0, -1, false), cursor_line)
  return stage, not stage and MISS.OUTSIDE or nil
end

---@return askfn.Target
local function visual_selection()
  local from, to = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd.normal({ ESC, bang = true })
  return { start_line = math.min(from, to), end_line = math.max(from, to) }
end

local function select_function()
  local target = target_at_cursor(symbol.FUNCTION)
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

---The whole buffer, when it fits in one argument next to the asked code, which is sent as well.
---@param bufnr integer
---@param code string[] the lines being asked about
---@return string[]?
local function file_context(bufnr, code)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #table.concat(lines, "\n") + #table.concat(code, "\n") > MAX_CONTEXT_BYTES then
    local notice = "askfn: the file is too large to send along (over %d KB with the code), sending the code only"
    vim.notify(notice:format(MAX_CONTEXT_BYTES / 1000), vim.log.levels.INFO)
    return nil
  end
  return lines
end

---@param target askfn.Target
---@param with_file boolean send the whole file along as context
---@param noun string? what the named target is, for the prompt; unused for a plain selection
local function ask(target, with_file, noun)
  local executable = config.backends[config.backend].cmd[1]
  if vim.fn.executable(executable) ~= 1 then
    vim.notify(("askfn: %q is not executable"):format(executable), vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local code = vim.api.nvim_buf_get_lines(bufnr, target.start_line - 1, target.end_line, false)
  if #table.concat(code, "\n") > MAX_CONTEXT_BYTES then
    local notice = "askfn: that code is too large to send (over %d KB), ask about a smaller part"
    vim.notify(notice:format(MAX_CONTEXT_BYTES / 1000), vim.log.levels.WARN)
    return
  end
  local file = with_file and file_context(bufnr, code) or nil
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
          noun = noun,
          code = code,
          file = file,
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

---@param scope askfn.Scope
---@param with_file boolean
local function ask_at_cursor(scope, with_file)
  local target, miss = target_at_cursor(scope)
  if not target then
    vim.notify(MISS_NOTICES[miss]:format(scope.noun), vim.log.levels.WARN)
    return
  end
  ask(target, with_file, scope.noun)
end

---@param key string
---@param with_file boolean
local function map_ask(key, with_file)
  local suffix = with_file and " (with the whole file)" or ""
  vim.keymap.set("n", key, function()
    ask_at_cursor(symbol.FUNCTION, with_file)
  end, { desc = "Ask agent about this function" .. suffix })
  vim.keymap.set("x", key, function()
    ask(visual_selection(), with_file)
  end, { desc = "Ask agent about the selection" .. suffix })
end

---@param opts askfn.Config? partial config, merged over the defaults
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", defaults, opts or {})
  validate(merged)
  config = merged
  vim.api.nvim_set_hl(0, TARGET_HIGHLIGHT, { default = true, link = "Visual" })

  local keys = merged.keys
  if keys.ask then
    map_ask(keys.ask, false)
  end
  if keys.ask_file then
    map_ask(keys.ask_file, true)
  end
  if keys.ask_type then
    vim.keymap.set("n", keys.ask_type, function()
      ask_at_cursor(symbol.TYPE, false)
    end, { desc = "Ask agent about the class, struct or enum around the cursor" })
  end
  if keys.textobject then
    vim.keymap.set({ "x", "o" }, keys.textobject, select_function, { desc = "Function including signature" })
  end
end

return M
