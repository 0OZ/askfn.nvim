-- Run from the plugin root: nvim --headless -u NONE -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local SymbolKind = vim.lsp.protocol.SymbolKind
local WAIT_MS = 2000
local POLL_MS = 2

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

local function lacks(haystack, needle, message)
  if haystack:find(needle, 1, true) then
    error(("%s\n  unexpected: %s\n  in: %s"):format(message, needle, haystack), 2)
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

-- ── docker: build stage lookup ──────────────────────────────────────────────

local docker = require("askfn.docker")
local DOCKERFILE = {
  "FROM golang:1.26 AS build",
  "WORKDIR /src",
  "RUN go build -o /out/app ./cmd",
  "",
  "FROM alpine:3.20",
  "COPY --from=build /out/app /app",
  'ENTRYPOINT ["/app"]',
  "",
}
local BUILD_STAGE = { name = "build", start_line = 1, end_line = 3 }

test("line inside a build stage finds the stage named by its alias", function()
  eq(BUILD_STAGE, docker.stage_at(DOCKERFILE, 2), "WORKDIR belongs to build")
end)

test("FROM line and last instruction both belong to their stage", function()
  eq(BUILD_STAGE, docker.stage_at(DOCKERFILE, 1), "FROM line")
  eq(BUILD_STAGE, docker.stage_at(DOCKERFILE, 3), "last instruction")
end)

test("stage without alias is named by its image and ends at the last instruction", function()
  eq({ name = "alpine:3.20", start_line = 5, end_line = 7 }, docker.stage_at(DOCKERFILE, 6), "trailing blank line trimmed")
end)

test("blank line between stages belongs to neither", function()
  eq(nil, docker.stage_at(DOCKERFILE, 4), "gap")
end)

test("lowercase from and as are recognised", function()
  eq({ name = "web", start_line = 1, end_line = 2 }, docker.stage_at({ "from node:22 as web", "run npm ci" }, 2), "case-insensitive")
end)

test("FROM flags are not mistaken for the image", function()
  local lines = { "FROM --platform=$BUILDPLATFORM golang:1.26", "RUN go build" }
  eq({ name = "golang:1.26", start_line = 1, end_line = 2 }, docker.stage_at(lines, 2), "flag skipped")
end)

test("line before the first FROM belongs to no stage", function()
  eq(nil, docker.stage_at({ "ARG VERSION=1", "FROM alpine" }, 1), "global ARG")
end)

local request = require("askfn.request")
local SESSION = { start = "--sid", resume = "--continue-sid", interactive = { "agent", "--resume" } }

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
  lacks(prompt, "Function:", "selection has no name")
end)

test("first argv appends the prompt and leaves the backend command untouched", function()
  local backend = { cmd = { "agent", "-p" } }
  eq({ "agent", "-p", "hello" }, request.first_argv(backend, "hello"), "prompt is the last argument")
  eq({ "agent", "-p" }, backend.cmd, "configured command must not grow between asks")
end)

test("first argv starts the session before the prompt", function()
  local backend = { cmd = { "agent" }, session = SESSION }
  eq({ "agent", "--sid", "abc", "hello" }, request.first_argv(backend, "hello", "abc"), "start flag, id, prompt")
end)

test("follow-up argv resumes the session with only the new question", function()
  local backend = { cmd = { "agent" }, session = SESSION }
  eq({ "agent", "--continue-sid", "abc", "more?" }, request.follow_up_argv(backend, "more?", "abc"), "resume flag")
end)

test("interactive argv appends the session id and leaves the configured command untouched", function()
  eq({ "agent", "--resume", "abc" }, request.interactive_argv(SESSION, "abc"), "id is the last argument")
  eq({ "agent", "--resume" }, SESSION.interactive, "configured command must not grow between asks")
end)

test("session ids are distinct version-4 UUIDs", function()
  local first, second = request.session_id(), request.session_id()
  local uuid_v4 = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
  eq(true, first:match(uuid_v4) ~= nil, "not a v4 UUID: " .. first)
  eq(true, first ~= second, "two asks must not share a session")
end)

-- ── stream: agent output → answer text ──────────────────────────────────────

local stream = require("askfn.stream")

local function delta(text, parent)
  local event = { type = "content_block_delta", delta = { type = "text_delta", text = text } }
  return vim.json.encode({ type = "stream_event", event = event, parent_tool_use_id = parent }) .. "\n"
end

local function block_start(kind)
  local event = { type = "content_block_start", content_block = { type = kind } }
  return vim.json.encode({ type = "stream_event", event = event }) .. "\n"
end

local function result(text)
  return vim.json.encode({ type = "result", is_error = false, result = text }) .. "\n"
end

test("plain text output passes through unchanged", function()
  local decode = stream.decoder("text")
  eq("Hello wor", decode("Hello wor"), "first chunk")
  eq("ld\n", decode("ld\n"), "second chunk")
end)

test("claude text deltas become answer text", function()
  local decode = stream.decoder("claude-stream-json")
  eq("Hello world", decode(delta("Hello") .. delta(" world")), "deltas in order")
end)

test("claude event split across chunks is decoded once complete", function()
  local decode = stream.decoder("claude-stream-json")
  local line = delta("Hello")
  eq("", decode(line:sub(1, 20)), "half a line is not text yet")
  eq("Hello", decode(line:sub(21)), "completed line")
end)

test("claude thinking, tool and system events are not answer text", function()
  local decode = stream.decoder("claude-stream-json")
  local thinking = { type = "content_block_delta", delta = { type = "thinking_delta", thinking = "hmm" } }
  local tool_input = { type = "content_block_delta", delta = { type = "input_json_delta", partial_json = "{" } }
  local noise = vim.json.encode({ type = "system", subtype = "init" })
    .. "\n"
    .. vim.json.encode({ type = "stream_event", event = thinking })
    .. "\n"
    .. vim.json.encode({ type = "stream_event", event = tool_input })
    .. "\n"
    .. vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "dup" } } } })
    .. "\n"
  eq("", decode(noise), "only text deltas count")
end)

test("claude malformed and wrong-shaped lines are skipped without losing later text", function()
  local decode = stream.decoder("claude-stream-json")
  eq("ok", decode('not json\n{"type":"stream_event"}\n' .. delta("ok")), "bad lines dropped")
end)

test("claude text after a tool call starts a new paragraph", function()
  local decode = stream.decoder("claude-stream-json")
  local output = block_start("text") .. delta("Reading.") .. block_start("tool_use") .. block_start("text") .. delta("Done.")
  eq("Reading.\n\nDone.", decode(output), "blank line between text blocks")
end)

test("claude subagent text is not answer text", function()
  local decode = stream.decoder("claude-stream-json")
  eq("main", decode(delta("sub", "toolu_1") .. delta("main")), "only the top-level agent speaks")
end)

test("claude result text is used when nothing was streamed", function()
  local decode = stream.decoder("claude-stream-json")
  eq("Credit balance is too low", decode(result("Credit balance is too low")), "error result")
end)

test("claude thinking before a failure does not hide the result text", function()
  local decode = stream.decoder("claude-stream-json")
  local thinking = { type = "content_block_delta", delta = { type = "thinking_delta", thinking = "hmm" } }
  local output = vim.json.encode({ type = "stream_event", event = thinking }) .. "\n" .. result("Rate limited")
  eq("Rate limited", decode(output), "thinking is not answer text, so the result still counts")
end)

test("claude result text is not repeated after streaming", function()
  local decode = stream.decoder("claude-stream-json")
  eq("Hi", decode(delta("Hi") .. result("Hi")), "answer shown once")
end)

-- ── thread: turns → float content ───────────────────────────────────────────

local thread = require("askfn.thread")

test("turn renders the quoted question above its answer", function()
  local lines = thread.render({ { question = "why?", answer = "Because.\nReally." } })
  eq({ "> why?", "", "Because.", "Really." }, lines, "question, blank, answer")
end)

test("turn without an answer yet renders only the question", function()
  eq({ "> why?" }, (thread.render({ { question = "why?", answer = "" } })), "pending turn")
end)

test("turns are separated and the last question line is reported", function()
  local turns = { { question = "why?", answer = "Because." }, { question = "and?", answer = "" } }
  local lines, last_question_line = thread.render(turns)
  eq({ "> why?", "", "Because.", "", "> and?" }, lines, "two turns")
  eq(5, last_question_line, "line of the newest question")
end)

test("first code block is extracted without its fence", function()
  local answer = "Use:\n```lua\nlocal x = 1\nreturn x\n```\nor\n```lua\nlocal y = 2\n```"
  eq("local x = 1\nreturn x", thread.first_code_block(answer), "first of two blocks")
end)

test("answer without a code block has none", function()
  eq(nil, thread.first_code_block("Just prose."), "no fence")
end)

-- ── plugin: keymaps against a fake language server and a fake agent ─────────

local askfn = require("askfn")
local SOURCE = { "local x = 1", "", "local function add(a, b)", "  return a + b", "end", "", "return add" }
local ECHO_PROMPT = { cmd = { "sh", "-c", 'printf "%s" "$0"' }, output = "text" }
local ECHO_ARGS_WITH_SESSION = { cmd = { "sh", "-c", 'printf "%s\\n" "$@"', "sh" }, output = "text", session = SESSION }
local SLOW_WITH_SESSION = { cmd = { "sh", "-c", "sleep 1" }, output = "text", session = SESSION }

local function says(text)
  return { cmd = { "sh", "-c", ("printf '%s'"):format(text) }, output = "text" }
end

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
  vim.cmd.stopinsert()
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
---@param backend table
---@param animate boolean? defaults to off so heights are final as soon as text is rendered
local function use_agent(backend, animate)
  handed_off = {}
  askfn.setup({
    backend = "fake",
    backends = { fake = backend },
    animate = animate or false,
    handoff = function(argv)
      handed_off[#handed_off + 1] = argv
    end,
  })
end

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function wait_for_buffer_text(needle)
  vim.wait(WAIT_MS, function()
    return buffer_text():find(needle, 1, true) ~= nil
  end, POLL_MS)
  return buffer_text()
end

local function title_of(win)
  local title = vim.api.nvim_win_get_config(win).title
  return vim
    .iter(title)
    :map(function(chunk)
      return chunk[1]
    end)
    :join("")
end

local function target_marks(bufnr)
  local namespace = vim.api.nvim_get_namespaces().askfn
  return vim.tbl_map(function(mark)
    return { first_row = mark[2], last_row = mark[4].end_row }
  end, vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true }))
end

local function ask(question)
  feed("4G<leader>aq")
  submit(question)
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

-- Docker's language server reports every instruction as a one-line "function".
local function open_dockerfile(symbols)
  open_source(symbols)
  vim.api.nvim_buf_set_name(0, vim.fn.getcwd() .. "/Dockerfile")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, DOCKERFILE)
  vim.bo.filetype = "dockerfile"
end

test("yaf in a Dockerfile selects the whole build stage, not one instruction", function()
  use_agent(ECHO_PROMPT)
  open_dockerfile({ sym("WORKDIR", SymbolKind.Function, 1, 1) })
  feed("2Gyaf")
  eq("FROM golang:1.26 AS build\nWORKDIR /src\nRUN go build -o /out/app ./cmd\n", vim.fn.getreg('"'), "stage, not WORKDIR")
end)

test("asking in a Dockerfile works without a language server and sends the stage", function()
  use_agent(ECHO_PROMPT)
  open_dockerfile(nil)
  feed("2G<leader>aq")
  submit("why this base image?")
  local answer = wait_for_buffer_text("Question: why this base image?")
  contains(answer, "Dockerfile:1-3", "prompt names the stage range")
  contains(answer, "RUN go build -o /out/app ./cmd", "stage source reached the agent")
  lacks(answer, "ENTRYPOINT", "the next stage is not included")
end)

test("asking sends function and question to the agent and shows its answer", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  ask("why?")
  local answer = wait_for_buffer_text("Question: why?")
  contains(answer, "Question: why?", "question reached the agent")
  contains(answer, "local function add(a, b)", "function reached the agent")
  feed("q")
  eq(1, #vim.api.nvim_list_wins(), "q closes the answer")
end)

test("answer text appears while the agent is still running", function()
  use_agent({ cmd = { "sh", "-c", "printf one; sleep 0.6; printf two" }, output = "text" })
  open_source({ ADD })
  ask("why?")
  lacks(wait_for_buffer_text("one"), "onetwo", "first chunk is shown before the agent finishes")
  contains(wait_for_buffer_text("onetwo"), "onetwo", "later chunk is appended")
end)

test("claude stream output is shown as decoded text", function()
  local fixture = vim.fn.tempname()
  vim.fn.writefile(vim.split(delta("Hello") .. delta(" world"), "\n", { trimempty = true }), fixture)
  use_agent({ cmd = { "sh", "-c", "cat " .. fixture }, output = "claude-stream-json" })
  open_source({ ADD })
  ask("why?")
  local answer = wait_for_buffer_text("Hello world")
  contains(answer, "Hello world", "decoded text")
  lacks(answer, "content_block_delta", "raw events are not shown")
end)

test("title shows activity while answering and the plain label afterwards", function()
  use_agent({ cmd = { "sh", "-c", "sleep 0.4; printf done" }, output = "text" })
  open_source({ ADD })
  ask("why?")
  local float = vim.api.nvim_get_current_win()
  vim.wait(200)
  local busy_title = title_of(float)
  wait_for_buffer_text("done")
  vim.wait(200)
  eq(" fake · add ", title_of(float), "plain label once answered")
  contains(busy_title, "fake · add", "label stays visible while busy")
  eq(true, busy_title ~= " fake · add ", "busy title carries the activity indicator: " .. busy_title)
end)

test("failing agent shows its error output", function()
  use_agent({ cmd = { "sh", "-c", "echo boom >&2; exit 3" }, output = "text" })
  open_source({ ADD })
  ask("why?")
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
  use_agent({ cmd = { "askfn-no-such-binary" }, output = "text" })
  open_source({ ADD })
  feed("4G<leader>aq")
  eq(1, #vim.api.nvim_list_wins(), "no popup")
  eq(vim.log.levels.ERROR, notifications[1].level, "error shown")
end)

test("empty question does not run the agent", function()
  local marker = vim.fn.tempname()
  use_agent({ cmd = { "sh", "-c", "touch " .. marker }, output = "text" })
  open_source({ ADD })
  ask("")
  vim.wait(300)
  eq(1, #vim.api.nvim_list_wins(), "popup closed, no answer window")
  eq(nil, vim.uv.fs_stat(marker), "agent must not have run")
end)

test("closing the answer window stops the running agent", function()
  local marker = vim.fn.tempname()
  use_agent({ cmd = { "sh", "-c", "sleep 1; touch " .. marker }, output = "text" })
  open_source({ ADD })
  ask("why?")
  feed("q")
  vim.wait(1500)
  eq(nil, vim.uv.fs_stat(marker), "agent was killed before it finished")
end)

test("asked function is highlighted while the popup and the answer are open", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  local source = vim.api.nvim_get_current_buf()
  feed("4G<leader>aq")
  eq({ { first_row = 2, last_row = 4 } }, target_marks(source), "highlight while typing the question")
  submit("why?")
  wait_for_buffer_text("Question: why?")
  eq({ { first_row = 2, last_row = 4 } }, target_marks(source), "highlight while reading the answer")
  feed("q")
  eq({}, target_marks(source), "highlight removed with the answer")
end)

test("cancelling the question removes the highlight", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  local source = vim.api.nvim_get_current_buf()
  feed("4G<leader>aq")
  feed("<Esc>")
  eq({}, target_marks(source), "no highlight left behind")
  eq(1, #vim.api.nvim_list_wins(), "popup closed")
end)

test("float is as tall as a short answer", function()
  use_agent(says("a\\nb\\nc"))
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("c")
  eq(5, vim.api.nvim_win_get_height(0), "question, blank line and three answer lines")
end)

test("float height is capped for a long answer", function()
  use_agent({ cmd = { "sh", "-c", "seq 1 60" }, output = "text" })
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("60")
  eq(24, vim.o.lines, "test assumes the headless default screen")
  eq(19, vim.api.nvim_win_get_height(0), "80% of the 24 screen lines")
end)

test("animated float grows through intermediate heights to its content", function()
  use_agent({ cmd = { "sh", "-c", "seq 1 10" }, output = "text" }, true)
  open_source({ ADD })
  ask("why?")
  local float = vim.api.nvim_get_current_win()
  local seen = {}
  vim.wait(WAIT_MS, function()
    seen[vim.api.nvim_win_get_height(float)] = true
    return seen[12]
  end, POLL_MS)
  eq(true, seen[12], "settles at question, blank line and ten answer lines")
  eq(true, vim.tbl_count(seen) > 2, "passes heights between 1 and 12: " .. vim.inspect(vim.tbl_keys(seen)))
end)

test("follow-up resumes the same session with only the new question", function()
  use_agent(ECHO_ARGS_WITH_SESSION)
  open_source({ ADD })
  ask("why?")
  local session_id = wait_for_buffer_text("Question: why?"):match("%-%-sid\n([^\n]+)")
  vim.wait(200)
  feed("<CR>")
  submit("and then?")
  local follow_up_argv = "--continue-sid\n" .. session_id .. "\nand then?"
  local conversation = wait_for_buffer_text(follow_up_argv)
  contains(conversation, follow_up_argv, "resume flag, same id, bare question")
  contains(conversation, "> why?", "first question stays in the thread")
  contains(conversation, "> and then?", "follow-up question joins the thread")
end)

test("follow-up scrolls its question to the top when the thread outgrows the window", function()
  -- Short first answer, long follow-up: the window is still small when the second question is added.
  local short_then_long = 'case "$*" in *--continue-sid*) for n in $(seq 1 40); do echo $n; sleep 0.01; done;; *) echo short;; esac'
  use_agent({ cmd = { "sh", "-c", short_then_long, "sh" }, output = "text", session = SESSION }, true)
  open_source({ ADD })
  ask("first?")
  wait_for_buffer_text("short")
  vim.wait(600)
  feed("<CR>")
  submit("second?")
  wait_for_buffer_text("40")
  vim.wait(600)
  local float = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local question_line = vim.fn.index(lines, "> second?") + 1
  eq(question_line, vim.fn.line("w0", float), "newest question is the first visible line")
end)

test("follow-up key while the agent is still answering warns", function()
  use_agent(SLOW_WITH_SESSION)
  open_source({ ADD })
  ask("why?")
  feed("<CR>")
  eq(vim.log.levels.WARN, notifications[1].level, "warning shown")
  eq(2, #vim.api.nvim_list_wins(), "no question popup on top of the answer")
end)

test("backend without session support has no follow-up", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Question: why?")
  vim.wait(200)
  feed("<CR>")
  eq(2, #vim.api.nvim_list_wins(), "no question popup")
end)

test("handoff key after the answer resumes the same session and closes the float", function()
  use_agent(ECHO_ARGS_WITH_SESSION)
  open_source({ ADD })
  ask("why?")
  local session_id = wait_for_buffer_text("Question: why?"):match("%-%-sid\n([^\n]+)")
  vim.wait(200)
  feed("o")
  eq({ { "agent", "--resume", session_id } }, handed_off, "interactive command for the asked session")
  eq(1, #vim.api.nvim_list_wins(), "answer float closed")
end)

test("handoff key while the agent is still answering warns and keeps waiting", function()
  use_agent(SLOW_WITH_SESSION)
  open_source({ ADD })
  ask("why?")
  feed("o")
  eq({}, handed_off, "nothing to resume yet")
  eq(vim.log.levels.WARN, notifications[1].level, "warning shown")
  eq(2, #vim.api.nvim_list_wins(), "answer float stays open")
end)

test("backend without session support has no handoff", function()
  use_agent(ECHO_PROMPT)
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Question: why?")
  vim.wait(200)
  feed("o")
  eq({}, handed_off, "handoff key is not mapped")
end)

test("default handoff opens the interactive command in a terminal split", function()
  local session = { start = "--sid", resume = "--continue-sid", interactive = { "sh", "-c", "sleep 5" } }
  askfn.setup({ backend = "fake", backends = { fake = { cmd = ECHO_PROMPT.cmd, output = "text", session = session } } })
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Question: why?")
  vim.wait(200)
  feed("o")
  eq("terminal", vim.bo.buftype, "interactive command runs in a terminal buffer")
  eq(2, #vim.api.nvim_list_wins(), "terminal sits in a split next to the source")
  vim.cmd("bwipeout!")
end)

test("copy key puts the last answer in the register", function()
  use_agent(says("Use this:\\n```lua\\nlocal x = 1\\n```\\nDone."))
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Done.")
  feed("gy")
  eq("Use this:\n```lua\nlocal x = 1\n```\nDone.", vim.fn.getreg('"'), "answer without the question")
end)

test("copy-code key puts the first code block in the register", function()
  use_agent(says("Use this:\\n```lua\\nlocal x = 1\\n```\\nDone."))
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Done.")
  feed("gY")
  eq("local x = 1", vim.fn.getreg('"'), "code without its fence")
end)

test("copy-code key warns when the answer has no code block", function()
  use_agent(says("Just prose."))
  open_source({ ADD })
  ask("why?")
  wait_for_buffer_text("Just prose.")
  feed("gY")
  eq("", vim.fn.getreg('"'), "register untouched")
  eq(vim.log.levels.WARN, notifications[1].level, "warning shown")
end)

test("unknown backend is rejected at setup", function()
  local ok, message = pcall(askfn.setup, { backend = "nope" })
  eq(false, ok, "setup must fail")
  contains(message, "nope", "error names the backend")
end)

test("unknown output format is rejected at setup", function()
  local ok, message = pcall(askfn.setup, { backend = "fake", backends = { fake = { cmd = { "sh" }, output = "xml" } } })
  eq(false, ok, "setup must fail")
  contains(message, "xml", "error names the format")
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
