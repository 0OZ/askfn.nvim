local M = {}

---@class askfn.Session
---@field start string flag that names the session of the first question; the id follows it
---@field resume string flag that continues that session for a follow-up; the id follows it
---@field interactive string[] argv that reopens the session interactively; the id is appended

---@class askfn.Backend
---@field cmd string[] argv of the agent CLI; session flag and question are appended
---@field output askfn.OutputFormat how the CLI writes its answer to stdout
---@field session askfn.Session? omit when the CLI cannot continue a one-shot run

---@class askfn.PromptInput
---@field path string file path shown to the agent
---@field filetype string
---@field target askfn.Target
---@field code string[] lines of the target
---@field question string

---@param input askfn.PromptInput
---@return string
function M.prompt(input)
  local target = input.target
  local header = ("File: %s:%d-%d"):format(input.path, target.start_line, target.end_line)
  if target.name then
    header = ("%s\nFunction: %s"):format(header, target.name)
  end
  local code = table.concat(input.code, "\n")
  return ("%s\n\n```%s\n%s\n```\n\nQuestion: %s"):format(header, input.filetype, code, input.question)
end

---@param backend askfn.Backend
---@param session_args string[] empty for a backend without sessions
---@param text string
---@return string[]
local function argv(backend, session_args, text)
  local with_session = vim.list_extend(vim.deepcopy(backend.cmd), session_args)
  return vim.list_extend(with_session, { text })
end

---Command for the first question of a conversation.
---@param backend askfn.Backend
---@param prompt string
---@param session_id string? required when the backend has a session
---@return string[]
function M.first_argv(backend, prompt, session_id)
  local session = backend.session
  return argv(backend, session and { session.start, session_id } or {}, prompt)
end

---Command for a further question in the same session.
---@param backend askfn.Backend must have a session
---@param question string
---@param session_id string
---@return string[]
function M.follow_up_argv(backend, question, session_id)
  return argv(backend, { backend.session.resume, session_id }, question)
end

---@param session askfn.Session
---@param session_id string
---@return string[]
function M.interactive_argv(session, session_id)
  return vim.list_extend(vim.deepcopy(session.interactive), { session_id })
end

local UUID_BYTES = 16
local UUID_FORMAT = "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"

---Random version-4 UUID (RFC 9562).
---@return string
function M.session_id()
  local bytes = { vim.uv.random(UUID_BYTES):byte(1, UUID_BYTES) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40) -- version 4
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80) -- RFC variant
  return UUID_FORMAT:format(unpack(bytes))
end

return M
