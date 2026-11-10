local M = {}

---Docker's language server reports every instruction as a one-line function, which is no
---unit worth asking about. The unit of a Dockerfile is the build stage: a FROM line and
---everything up to the next one.

---Name of the stage a FROM line opens: its `AS` alias, else the image.
---@param line string
---@return string? name nil when the line is not a FROM
local function stage_name(line)
  local arguments = line:match("^%s*[Ff][Rr][Oo][Mm]%s+(.+)$")
  if not arguments then
    return nil
  end
  local alias = arguments:match("%s+[Aa][Ss]%s+(%S+)%s*$")
  while arguments:find("^%-%-") do -- flags such as --platform=...
    arguments = arguments:gsub("^%S+%s*", "", 1)
  end
  return alias or arguments:match("^%S+")
end

---@param line string
---@return boolean
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

---@param lines string[]
---@param from_line integer
---@return integer? line of the closest FROM at or above `from_line`
local function stage_start(lines, from_line)
  for number = from_line, 1, -1 do
    if stage_name(lines[number]) then
      return number
    end
  end
end

---@param lines string[]
---@param start integer line of the stage's FROM
---@return integer last last non-blank line before the next FROM, or of the file
local function stage_end(lines, start)
  local last = #lines
  for number = start + 1, #lines do
    if stage_name(lines[number]) then
      last = number - 1
      break
    end
  end
  while last > start and is_blank(lines[last]) do
    last = last - 1
  end
  return last
end

---@param lines string[] the whole Dockerfile
---@param cursor_line integer 1-based
---@return askfn.Target? stage nil before the first FROM and on the blank lines between stages
function M.stage_at(lines, cursor_line)
  local start = stage_start(lines, math.min(cursor_line, #lines))
  if not start then
    return nil
  end
  local last = stage_end(lines, start)
  if cursor_line > last then
    return nil
  end
  return { name = stage_name(lines[start]), start_line = start, end_line = last }
end

return M
