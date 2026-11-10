local answer = require("askfn.answer")
local input = require("askfn.input")
local request = require("askfn.request")
local stream = require("askfn.stream")
local thread = require("askfn.thread")

local M = {}

---@class askfn.ConversationOptions
---@field config askfn.Config
---@field label string "<backend> · <function>", shown in the titles
---@field question string the first question, as typed
---@field prompt string the first question with file, range and source
---@field on_close fun() called when the answer window closes

---@class askfn.Action
---@field key string|false
---@field hint string
---@field needs_session boolean
---@field run fun()

---@class askfn.Conversation
---@field config askfn.Config
---@field backend askfn.Backend
---@field label string
---@field session_id string? nil for a backend without sessions
---@field turns askfn.Turn[]
---@field busy boolean an agent run is in flight
---@field job vim.SystemObj?
---@field view askfn.AnswerView

---@param conversation askfn.Conversation
local function show(conversation)
  conversation.view.render((thread.render(conversation.turns)))
end

---Adds a turn, runs the agent for it and streams the answer into the float.
---@param conversation askfn.Conversation
---@param argv string[]
---@param question string
local function run_turn(conversation, argv, question)
  local turn = { question = question, answer = "" }
  table.insert(conversation.turns, turn)
  local lines, question_line = thread.render(conversation.turns)
  conversation.view.render(lines)
  conversation.view.focus_line(question_line)
  conversation.view.set_busy(true)
  conversation.busy = true

  local decode = stream.decoder(conversation.backend.output)
  local function on_stdout(_, chunk)
    if not chunk then
      return
    end
    vim.schedule(function()
      turn.answer = turn.answer .. decode(chunk)
      show(conversation)
    end)
  end
  local on_exit = vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      turn.answer = ("%s\n%s"):format(turn.answer, result.stderr or "")
      show(conversation)
    end
    conversation.busy = false
    conversation.view.set_busy(false)
  end)
  conversation.job = vim.system(argv, { text = true, stdout = on_stdout }, on_exit)
end

---@param conversation askfn.Conversation
---@param action fun()
---@return fun()
local function when_answered(conversation, action)
  return function()
    if conversation.busy then
      vim.notify("askfn: still answering", vim.log.levels.WARN)
      return
    end
    action()
  end
end

---@param conversation askfn.Conversation
local function follow_up(conversation)
  input.open((" %s "):format(conversation.label), {
    on_cancel = function() end,
    on_submit = function(question)
      local argv = request.follow_up_argv(conversation.backend, question, conversation.session_id)
      run_turn(conversation, argv, question)
    end,
  })
end

---@param conversation askfn.Conversation
local function hand_off(conversation)
  conversation.view.close()
  conversation.config.handoff(request.interactive_argv(conversation.backend.session, conversation.session_id))
end

---@param text string
---@param what string
local function copy(text, what)
  vim.fn.setreg(vim.v.register, text)
  vim.notify(("askfn: %s copied"):format(what), vim.log.levels.INFO)
end

---@param conversation askfn.Conversation
local function copy_answer(conversation)
  copy(vim.trim(conversation.turns[#conversation.turns].answer), "answer")
end

---@param conversation askfn.Conversation
local function copy_code(conversation)
  local code = thread.first_code_block(conversation.turns[#conversation.turns].answer)
  if not code then
    vim.notify("askfn: no code block in the answer", vim.log.levels.WARN)
    return
  end
  copy(code, "code block")
end

---Actions the configured keys and this backend allow, in footer order.
---@param conversation askfn.Conversation
---@return askfn.Action[]
local function available_actions(conversation)
  local keys = conversation.config.keys
  ---@type askfn.Action[]
  local actions = {
    {
      key = keys.follow_up,
      hint = "follow up",
      needs_session = true,
      run = when_answered(conversation, function()
        follow_up(conversation)
      end),
    },
    {
      key = keys.handoff,
      hint = "terminal",
      needs_session = true,
      run = when_answered(conversation, function()
        hand_off(conversation)
      end),
    },
    {
      key = keys.yank,
      hint = "copy",
      needs_session = false,
      run = function()
        copy_answer(conversation)
      end,
    },
    {
      key = keys.yank_code,
      hint = "copy code",
      needs_session = false,
      run = function()
        copy_code(conversation)
      end,
    },
  }
  local has_session = conversation.backend.session ~= nil
  return vim.tbl_filter(function(action)
    return action.key and (has_session or not action.needs_session)
  end, actions)
end

---@param actions askfn.Action[]
---@return string
local function footer(actions)
  local hints = vim.tbl_map(function(action)
    return ("%s %s"):format(action.key, action.hint)
  end, actions)
  return (" %s "):format(table.concat(vim.list_extend({ "q close" }, hints), " · "))
end

---Opens the answer float and asks the first question.
---@param opts askfn.ConversationOptions
function M.start(opts)
  local backend = opts.config.backends[opts.config.backend]
  ---@type askfn.Conversation
  local conversation = {
    config = opts.config,
    backend = backend,
    label = opts.label,
    session_id = backend.session and request.session_id() or nil,
    turns = {},
    busy = false,
  }
  local actions = available_actions(conversation)
  conversation.view = answer.open({ label = opts.label, footer = footer(actions), animate = opts.config.animate })
  for _, action in ipairs(actions) do
    conversation.view.map(action.key, action.run)
  end
  conversation.view.on_close(function()
    local job = conversation.job
    if job and not job:is_closing() then
      job:kill("sigterm")
    end
    opts.on_close()
  end)

  run_turn(conversation, request.first_argv(backend, opts.prompt, conversation.session_id), opts.question)
end

return M
