local M = {}

local WIDTH = 60

---@class askfn.InputHandlers
---@field on_submit fun(text: string) called with a non-blank question
---@field on_cancel fun() called when the popup closes without one

---One-line floating prompt under the cursor.
---@param title string
---@param handlers askfn.InputHandlers
function M.open(title, handlers)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "prompt"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = WIDTH,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = title,
  })

  local submitted = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not submitted then
        handlers.on_cancel()
      end
    end,
  })

  vim.fn.prompt_setprompt(buf, "")
  vim.fn.prompt_setcallback(buf, function(text)
    submitted = vim.trim(text) ~= ""
    vim.cmd.stopinsert()
    close()
    if submitted then
      handlers.on_submit(text)
    end
  end)
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.cmd.startinsert()
end

return M
