local M = {}

---@class askfn.Session
---@field flag string CLI flag that names the session of a one-shot run; the id follows it
---@field resume string[] argv that reopens a session interactively; the id is appended

---@class askfn.Backend
---@field cmd string[] argv of the agent CLI; session flag and prompt are appended
---@field session askfn.Session? omit when the CLI cannot resume a one-shot run

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
---@param prompt string
---@param session_id string? required when the backend has a session
---@return string[]
function M.argv(backend, prompt, session_id)
  local argv = vim.deepcopy(backend.cmd)
  if backend.session then
    vim.list_extend(argv, { backend.session.flag, session_id })
  end
  return vim.list_extend(argv, { prompt })
end

---@param session askfn.Session
---@param session_id string
---@return string[]
function M.resume_argv(session, session_id)
  return vim.list_extend(vim.deepcopy(session.resume), { session_id })
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

---What to show once the agent exits: its answer, or its error output when it failed.
---@param result vim.SystemCompleted
---@return string[]
function M.answer_lines(result)
  local text = result.code == 0 and result.stdout or result.stderr
  return vim.split(vim.trim(text or ""), "\n")
end

return M
