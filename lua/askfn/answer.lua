local M = {}

local MAX_WIDTH = 100
local SCREEN_RATIO = 0.8
local MIN_HEIGHT = 1
local FRAME_MS = 16
-- Each frame closes a third of the remaining distance: fast start, soft landing.
local EASING_DIVISOR = 3
local SPINNER_MS = 80
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local MS_PER_SECOND = 1000

---@class askfn.AnswerOptions
---@field label string shown in the title
---@field footer string key hints on the bottom border
---@field animate boolean grow smoothly instead of jumping to the content height

---@class askfn.AnswerView
---@field render fun(lines: string[]) replace the content and fit the height to it
---@field set_busy fun(busy: boolean) spinner and elapsed seconds in the title while busy
---@field focus_line fun(line: integer) make `line` the top line of the window
---@field map fun(key: string, action: fun()) normal-mode key inside the window
---@field on_close fun(callback: fun()) run `callback` when the window closes
---@field close fun()

---Markdown float that starts one line tall and grows downwards with its content.
---@param opts askfn.AnswerOptions
---@return askfn.AnswerView
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(MAX_WIDTH, math.floor(vim.o.columns * SCREEN_RATIO))
  local max_height = math.floor(vim.o.lines * SCREEN_RATIO)
  local idle_title = (" %s "):format(opts.label)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - max_height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = MIN_HEIGHT,
    style = "minimal",
    border = "rounded",
    title = idle_title,
    footer = opts.footer,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 0
  vim.bo[buf].filetype = "markdown"

  local resize_timer = assert(vim.uv.new_timer())
  local spinner_timer = assert(vim.uv.new_timer())
  local target_height = MIN_HEIGHT
  local spinning = false

  local function is_open()
    return vim.api.nvim_win_is_valid(win)
  end

  local function on_close(callback)
    vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = callback })
  end

  on_close(function()
    spinning = false
    resize_timer:close()
    spinner_timer:close()
  end)

  local function grow_one_frame()
    if not is_open() then
      return
    end
    local height = vim.api.nvim_win_get_height(win)
    if height >= target_height then
      resize_timer:stop()
      return
    end
    vim.api.nvim_win_set_height(win, height + math.ceil((target_height - height) / EASING_DIVISOR))
  end

  local function render(lines)
    if not is_open() then
      return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local content_height = vim.api.nvim_win_text_height(win, {}).all
    target_height = math.min(max_height, math.max(MIN_HEIGHT, content_height))
    if not opts.animate then
      vim.api.nvim_win_set_height(win, target_height)
      return
    end
    if not resize_timer:is_active() then
      resize_timer:start(0, FRAME_MS, vim.schedule_wrap(grow_one_frame))
    end
  end

  local function set_title(title)
    vim.api.nvim_win_set_config(win, { title = title })
  end

  local function set_busy(busy)
    if not is_open() then
      return
    end
    spinning = busy
    if not busy then
      spinner_timer:stop()
      set_title(idle_title)
      return
    end
    local started = vim.uv.now()
    local frame = 0
    spinner_timer:start(
      0,
      SPINNER_MS,
      vim.schedule_wrap(function()
        -- A tick queued just before the answer finished must not bring the spinner back.
        if not spinning then
          return
        end
        frame = frame % #SPINNER_FRAMES + 1
        local seconds = math.floor((vim.uv.now() - started) / MS_PER_SECOND)
        set_title((" %s %s · %ds "):format(SPINNER_FRAMES[frame], opts.label, seconds))
      end)
    )
  end

  local function focus_line(line)
    vim.api.nvim_win_call(win, function()
      -- `zt` is unreliable while the window is still smaller than its content; set the view directly.
      vim.fn.winrestview({ topline = line, lnum = line, col = 0 })
    end)
  end

  local function close()
    if is_open() then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function map(key, action)
    vim.keymap.set("n", key, action, { buffer = buf, nowait = true })
  end
  map("q", close)
  map("<Esc>", close)

  return {
    render = render,
    set_busy = set_busy,
    focus_line = focus_line,
    map = map,
    on_close = on_close,
    close = close,
  }
end

return M
