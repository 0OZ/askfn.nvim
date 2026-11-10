-- Run from the plugin root: nvim --headless -u NONE -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local SymbolKind = vim.lsp.protocol.SymbolKind
local WAIT_MS = 2000

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\n  expected: %s\n  actual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function contains(haystack, needle, message)
  if not haystack:find(needle, 1, true) then
    error(("%s\n  missing: %s\n  in: %s"):format(message, needle, haystack), 2)
  end
end

local function sym(name, kind, first, last, children)
  local range = { start = { line = first, character = 0 }, ["end"] = { line = last, character = 0 } }
  return { name = name, kind = kind, range = range, children = children }
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

-- Types into the question popup. Headless feedkeys runs before the popup's pending
-- startinsert takes effect, so insert mode is entered explicitly.
local function submit(question)
  feed("i" .. question .. "<CR>")
end

-- ── symbol: pure lookup ─────────────────────────────────────────────────────

local symbol = require("askfn.symbol")
local ADD = sym("add", SymbolKind.Function, 2, 4)
local ADD_TARGET = { name = "add", start_line = 3, end_line = 5 }

test("cursor inside a function finds it", function()
  eq(ADD_TARGET, symbol.innermost_callable({ ADD }, 4), "line 4 is the body of add")
end)

test("first and last line of a function belong to it", function()
  eq(ADD_TARGET, symbol.innermost_callable({ ADD }, 3), "signature line")
  eq(ADD_TARGET, symbol.innermost_callable({ ADD }, 5), "closing line")
end)

test("lines just outside a function find nothing", function()
  eq(nil, symbol.innermost_callable({ ADD }, 2), "line before the signature")
  eq(nil, symbol.innermost_callable({ ADD }, 6), "line after the end")
end)

test("method inside a class wins over the class", function()
  local class = sym("Calc", SymbolKind.Class, 0, 9, { sym("sum", SymbolKind.Method, 2, 4) })
  eq({ name = "sum", start_line = 3, end_line = 5 }, symbol.innermost_callable({ class }, 4), "cursor in method")
end)

test("class body outside any method finds nothing", function()
  local class = sym("Calc", SymbolKind.Class, 0, 9, { sym("sum", SymbolKind.Method, 2, 4) })
  eq(nil, symbol.innermost_callable({ class }, 8), "a class is not a callable")
end)

test("closure inside a function wins over the outer function", function()
  local outer = sym("outer", SymbolKind.Function, 0, 9, { sym("inner", SymbolKind.Function, 3, 5) })
  eq({ name = "inner", start_line = 4, end_line = 6 }, symbol.innermost_callable({ outer }, 5), "cursor in closure")
end)

test("flat symbol list picks the innermost function in either order", function()
  local function flat(name, first, last)
    local nested = sym(name, SymbolKind.Function, first, last)
    return { name = name, kind = nested.kind, location = { uri = "file:///x", range = nested.range } }
  end
  local inner = { name = "inner", start_line = 4, end_line = 6 }
  eq(inner, symbol.innermost_callable({ flat("outer", 0, 9), flat("inner", 3, 5) }, 5), "outer listed first")
  eq(inner, symbol.innermost_callable({ flat("inner", 3, 5), flat("outer", 0, 9) }, 5), "inner listed first")
end)

-- ── request: prompt and argv ────────────────────────────────────────────────

local request = require("askfn.request")

test("prompt names file, line range and function", function()
  local prompt = request.prompt({
    path = "lua/math.lua",
    filetype = "lua",
    target = ADD_TARGET,
    code = { "local function add(a, b)", "  return a + b", "end" },
    question = "why?",
  })
  contains(prompt, "File: lua/math.lua:3-5", "location header")
  contains(prompt, "Function: add", "function name")
  contains(prompt, "```lua\nlocal function add(a, b)\n  return a + b\nend\n```", "fenced code")
  contains(prompt, "Question: why?", "question")
end)

test("prompt for a plain selection has no function line", function()
  local prompt = request.prompt({
    path = "a.lua",
    filetype = "lua",
    target = { start_line = 1, end_line = 1 },
    code = { "x = 1" },
    question = "why?",
  })
  eq(nil, prompt:find("Function:", 1, true), "selection has no name")
end)

test("argv names the session before the prompt when the backend supports sessions", function()
  local backend = { cmd = { "agent" }, session = { flag = "--sid", resume = { "agent", "--resume" } } }
  eq({ "agent", "--sid", "abc", "hello" }, request.argv(backend, "hello", "abc"), "session flag then prompt")
end)

test("resume argv appends the session id and leaves the configured command untouched", function()
  local session = { flag = "--sid", resume = { "agent", "--resume" } }
  eq({ "agent", "--resume", "abc" }, request.resume_argv(session, "abc"), "id is the last argument")
  eq({ "agent", "--resume" }, session.resume, "configured command must not grow between asks")
end)

test("session ids are distinct version-4 UUIDs", function()
  local first, second = request.session_id(), request.session_id()
  local uuid_v4 = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
  eq(true, first:match(uuid_v4) ~= nil, "not a v4 UUID: " .. first)
  eq(true, first ~= second, "two asks must not share a session")
end)

test("argv appends the prompt and leaves the backend command untouched", function()
  local backend = { cmd = { "agent", "-p" } }
  eq({ "agent", "-p", "hello" }, request.argv(backend, "hello"), "prompt is the last argument")
  eq({ "agent", "-p" }, backend.cmd, "configured command must not grow between asks")
end)

-- ── plugin: keymaps against a fake language server and a fake agent ─────────

local askfn = require("askfn")
local SOURCE = { "local x = 1", "", "local function add(a, b)", "  return a + b", "end", "", "return add" }
local ECHO_PROMPT = { cmd = { "sh", "-c", 'printf "%s" "$0"' } }

local notifications = {}
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

local function fake_lsp(symbols)
  return {
    name = "fake",
    cmd = function()
      return {
        request = function(method, _, callback)
          local replies = {
            initialize = { capabilities = { documentSymbolProvider = true } },
            ["textDocument/documentSymbol"] = symbols,
          }
          callback(nil, replies[method])
          return true, 1
        end,
        notify = function()
          return true
        end,
        is_closing = function()
          return false
        end,
        terminate = function() end,
      }
    end,
  }
end

local function close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_close(win, true)
    end
  end
end

---@param symbols table? document symbols served by a fake language server; nil = no server
local function open_source(symbols)
  close_floats()
  vim.cmd("silent! %bwipeout!")
  notifications = {}
  vim.fn.setreg('"', "")
  vim.api.nvim_buf_set_name(0, vim.fn.getcwd() .. "/math.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, SOURCE)
  vim.bo.filetype = "lua"
  if symbols then
    local id = vim.lsp.start(fake_lsp(symbols))
    vim.wait(WAIT_MS, function()
      return vim.lsp.get_client_by_id(id).initialized
    end)
  end
end

local handed_off = {}
local function use_agent(backend)
  handed_off = {}
  askfn.setup({
    backend = "fake",
    backends = { fake = backend },
    handoff = function(argv)
      handed_off[#handed_off + 1] = argv
    end,
  })
end

local ECHO_ARGS_WITH_SESSION = {
  cmd = { "sh", "-c", 'printf "%s\n" "$@"', "sh" },
  session = { flag = "--sid", resume = { "agent", "--resume" } },
}

local function wait_for_buffer_text(needle)
  local text = ""
  vim.wait(WAIT_MS, function()
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return text:find(needle, 1, true) ~= nil
  end)
  return text
end

test("yaf yanks the whole function including its signature", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  feed("4Gyaf")
  eq("local function add(a, b)\n  return a + b\nend\n", vim.fn.getreg('"'), "linewise function")
end)

test("af from linewise visual mode selects the whole function", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  feed("4GVafy")
  eq("local function add(a, b)\n  return a + b\nend\n", vim.fn.getreg('"'), "selection grows to the function")
end)

test("asking sends function and question to the agent and shows its answer", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  local answer = wait_for_buffer_text("Question: why?")
  contains(answer, "Question: why?", "question reached the agent")
  contains(answer, "local function add(a, b)", "function reached the agent")
  feed("q")
  eq(1, #vim.api.nvim_list_wins(), "q closes the answer")
end)

test("failing agent shows its error output", function()
  use_agent({ cmd = { "sh", "-c", "echo boom >&2; exit 3" } })
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  contains(wait_for_buffer_text("boom"), "boom", "stderr of the failed agent")
end)

test("asking from a visual selection sends the selected lines", function()
  use_agent(ECHO_PROMPT)
  open_source(nil)
  feed("3GVj<leader>aq")
  submit("why?")
  contains(wait_for_buffer_text("Question: why?"), "math.lua:3-4", "selected range")
end)

test("no language server warns instead of opening a popup", function()
  use_agent(ECHO_PROMPT)
  open_source(nil)
  feed("4G<leader>aq")
  eq(1, #vim.api.nvim_list_wins(), "no popup")
  eq(vim.log.levels.WARN, notifications[1].level, "warning shown")
end)

test("missing agent binary reports an error instead of opening a popup", function()
  use_agent({ cmd = { "askfn-no-such-binary" } })
  open_source({ ADD })
  feed("4G<leader>aq")
  eq(1, #vim.api.nvim_list_wins(), "no popup")
  eq(vim.log.levels.ERROR, notifications[1].level, "error shown")
end)

test("empty question does not run the agent", function()
  local marker = vim.fn.tempname()
  use_agent({ cmd = { "sh", "-c", "touch " .. marker } })
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("")
  vim.wait(300)
  eq(1, #vim.api.nvim_list_wins(), "popup closed, no answer window")
  eq(nil, vim.uv.fs_stat(marker), "agent must not have run")
end)

test("closing the answer window stops the running agent", function()
  local marker = vim.fn.tempname()
  use_agent({ cmd = { "sh", "-c", "sleep 1; touch " .. marker } })
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  feed("q")
  vim.wait(1500)
  eq(nil, vim.uv.fs_stat(marker), "agent was killed before it finished")
end)

test("handoff key after the answer resumes the same session and closes the float", function()
  use_agent(ECHO_ARGS_WITH_SESSION)
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  local session_id = wait_for_buffer_text("Question: why?"):match("%-%-sid\n([^\n]+)")
  feed("o")
  eq({ { "agent", "--resume", session_id } }, handed_off, "resume command for the asked session")
  eq(1, #vim.api.nvim_list_wins(), "answer float closed")
end)

test("handoff key while the agent is still answering warns and keeps waiting", function()
  local slow = { cmd = { "sh", "-c", "sleep 1" }, session = ECHO_ARGS_WITH_SESSION.session }
  use_agent(slow)
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  feed("o")
  eq({}, handed_off, "nothing to resume yet")
  eq(vim.log.levels.WARN, notifications[1].level, "warning shown")
  eq(2, #vim.api.nvim_list_wins(), "answer float stays open")
end)

test("backend without session support has no handoff", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  wait_for_buffer_text("Question: why?")
  feed("o")
  eq({}, handed_off, "handoff key is not mapped")
end)

test("default handoff opens the resume command in a terminal split", function()
  local resumable = { cmd = ECHO_PROMPT.cmd, session = { flag = "--sid", resume = { "sh", "-c", "sleep 5" } } }
  askfn.setup({ backend = "fake", backends = { fake = resumable } })
  open_source({ ADD })
  feed("4G<leader>aq")
  submit("why?")
  wait_for_buffer_text("Question: why?")
  feed("o")
  eq("terminal", vim.bo.buftype, "resume command runs in a terminal buffer")
  eq(2, #vim.api.nvim_list_wins(), "terminal sits in a split next to the source")
  vim.cmd("bwipeout!")
end)

test("unknown backend is rejected at setup", function()
  local ok, message = pcall(askfn.setup, { backend = "nope" })
  eq(false, ok, "setup must fail")
  contains(message, "nope", "error names the backend")
end)

-- ── runner ──────────────────────────────────────────────────────────────────

local failed = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(case.fn, debug.traceback)
  if not ok then
    failed = failed + 1
    io.stdout:write(("FAIL %s\n%s\n"):format(case.name, err))
  end
end
io.stdout:write(("%d tests, %d failed\n"):format(#tests, failed))
os.exit(failed == 0 and 0 or 1)
