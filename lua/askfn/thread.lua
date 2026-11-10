local M = {}

local QUOTE = "> "
local CODE_BLOCK = "```[^\n]*\n(.-)\n```"

---@class askfn.Turn
---@field question string
---@field answer string text received so far

---@param turn askfn.Turn
---@return string[]
local function turn_lines(turn)
  local question = { QUOTE .. turn.question }
  local answer = vim.trim(turn.answer)
  if answer == "" then
    return question
  end
  return vim.list_extend(vim.list_extend(question, { "" }), vim.split(answer, "\n", { plain = true }))
end

---Markdown lines of the whole conversation, turns separated by a blank line.
---@param turns askfn.Turn[] at least one
---@return string[] lines
---@return integer last_question_line 1-based line of the newest question
function M.render(turns)
  local blocks = vim.tbl_map(turn_lines, turns)
  local lines = vim
    .iter(blocks)
    :map(function(block)
      return vim.list_extend({ "" }, block)
    end)
    :flatten()
    :totable()
  table.remove(lines, 1)
  return lines, #lines - #blocks[#blocks] + 1
end

---@param answer string
---@return string? code content of the first fenced block, without the fence
function M.first_code_block(answer)
  return answer:match(CODE_BLOCK)
end

return M
