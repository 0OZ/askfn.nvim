local M = {}

local INPUT_WIDTH = 60
local ANSWER_SCREEN_RATIO = 0.8
local BORDER = "rounded"

local function scratch_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

---One-line floating prompt under the cursor. Blank input is dropped.
---@param title string
---@param on_submit fun(text: string)
function M.input(title, on_submit)
  local buf = scratch_buffer()
  vim.bo[buf].buftype = "prompt"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = INPUT_WIDTH,
    height = 1,
    style = "minimal",
    border = BORDER,
    title = title,
  })
  vim.fn.prompt_setprompt(buf, "")
  vim.fn.prompt_setcallback(buf, function(text)
    vim.cmd.stopinsert()
    close(win)
    if vim.trim(text) ~= "" then
      on_submit(text)
    end
  end)
  vim.keymap.set("n", "<Esc>", function()
    close(win)
  end, { buffer = buf })
  vim.cmd.startinsert()
end

---@class askfn.AnswerView
---@field set fun(lines: string[]) replace the content; no-op once the window is closed
---@field on_close fun(callback: fun()) run `callback` when the window closes
---@field map fun(key: string, action: fun()) normal-mode key inside the window
---@field close fun()

---Centered markdown float, closed with q or <Esc>.
---@param title string
---@param lines string[] initial content
---@param footer string key hints shown on the bottom border
---@return askfn.AnswerView
function M.answer(title, lines, footer)
  local buf = scratch_buffer()
  local width = math.floor(vim.o.columns * ANSWER_SCREEN_RATIO)
  local height = math.floor(vim.o.lines * ANSWER_SCREEN_RATIO)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = BORDER,
    title = title,
    footer = footer,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local function map(key, action)
    vim.keymap.set("n", key, action, { buffer = buf, nowait = true })
  end
  local function close_view()
    close(win)
  end
  map("q", close_view)
  map("<Esc>", close_view)

  return {
    map = map,
    close = close_view,
    set = function(new_lines)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
      end
    end,
    on_close = function(callback)
      vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = callback })
    end,
  }
end

return M
