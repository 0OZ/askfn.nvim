local M = {}

---How an agent CLI writes its answer to stdout.
---@alias askfn.OutputFormat "text"|"claude-stream-json"

---Turns one stdout chunk into the answer text it carries (possibly none).
---@alias askfn.Decode fun(chunk: string): string

local BLOCK_SEPARATOR = "\n\n"

---@return askfn.Decode
local function text_decoder()
  return function(chunk)
    return chunk
  end
end

---`claude -p --output-format stream-json --verbose --include-partial-messages`:
---one JSON message per line, answer text in `text_delta` events.
---@return askfn.Decode
local function claude_decoder()
  local unfinished_line = ""
  local streamed = false

  local stream_events = {
    content_block_start = function(event)
      -- Text resumes after a tool call in a new block; keep the two apart.
      local resumes_text = streamed and event.content_block.type == "text"
      return resumes_text and BLOCK_SEPARATOR or ""
    end,
    content_block_delta = function(event)
      if event.delta.type ~= "text_delta" then
        return ""
      end
      streamed = true
      return event.delta.text
    end,
  }

  local messages = {
    stream_event = function(message)
      local from_subagent = type(message.parent_tool_use_id) == "string"
      local handler = stream_events[message.event.type]
      if from_subagent or not handler then
        return ""
      end
      return handler(message.event)
    end,
    result = function(message)
      -- Failures arrive only here, as does everything from a CLI without partial messages.
      if streamed or type(message.result) ~= "string" then
        return ""
      end
      return message.result
    end,
  }

  -- stdout of another program: a line that is not the expected shape is dropped, never fatal.
  local function decode_line(line)
    local is_json, message = pcall(vim.json.decode, line)
    local handler = is_json and type(message) == "table" and messages[message.type]
    if not handler then
      return ""
    end
    local has_shape, text = pcall(handler, message)
    return has_shape and text or ""
  end

  return function(chunk)
    local lines = vim.split(unfinished_line .. chunk, "\n", { plain = true })
    unfinished_line = table.remove(lines)
    return table.concat(vim.tbl_map(decode_line, lines))
  end
end

---@type table<askfn.OutputFormat, fun(): askfn.Decode>
local DECODERS = {
  text = text_decoder,
  ["claude-stream-json"] = claude_decoder,
}

---@param format any
---@return boolean
function M.is_format(format)
  return DECODERS[format] ~= nil
end

---Fresh decoder for one agent run.
---@param format askfn.OutputFormat
---@return askfn.Decode
function M.decoder(format)
  return DECODERS[format]()
end

return M
