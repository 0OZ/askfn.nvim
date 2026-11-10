# askfn.nvim

Ask a coding agent about the function under your cursor, without leaving the buffer.

- `af` text object: the whole function, signature included (`vaf`, `yaf`, `daf`)
- `<leader>aq`: popup for a question about that function; in visual mode, about the selection
- The answer streams into a floating window that grows with it; the asked code stays highlighted
- Follow-up questions in the same window, same agent session
- One key to continue the conversation in an interactive agent terminal
- Backends: [Claude Code](https://claude.com/claude-code) (default) or pi (experimental), or any CLI that takes a prompt as its last argument

No dependencies. Function boundaries come from the attached language server
(`textDocument/documentSymbol`), so no treesitter parsers are needed.

## Requirements

- Neovim 0.11+
- A language server attached to the buffer (for the function lookup; visual selection works without one)
- The agent CLI on your `PATH`

## Install

lazy.nvim:

```lua
{
  "0OZ/askfn.nvim",
  opts = {},
}
```

Anything else: put the plugin on your runtimepath and call `require("askfn").setup()`.

## Keys

| Where | Key | Does |
|---|---|---|
| normal | `<leader>aq` | ask about the function under the cursor |
| visual | `<leader>aq` | ask about the selection |
| visual / operator | `af` | the whole function including its signature |
| answer window | `<CR>` | ask a follow-up question |
| answer window | `o` | continue in an interactive agent terminal |
| answer window | `gy` | copy the last answer |
| answer window | `gY` | copy the first code block of the last answer |
| answer window | `q`, `<Esc>` | close; stops the agent if it is still answering |

Follow-up and terminal handoff wait until the current answer is complete.

## Configuration

Defaults:

```lua
require("askfn").setup({
  backend = "claude",
  backends = {
    claude = {
      cmd = {
        "claude", "-p", "--model", "claude-sonnet-5-5", "--effort", "xhigh",
        "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      },
      output = "claude-stream-json",
      session = { start = "--session-id", resume = "--resume", interactive = { "claude", "--resume" } },
    },
    pi = { cmd = { "pi", "-p", "--thinking", "xhigh" }, output = "text" },
  },
  keys = { -- any of them: false to disable
    ask = "<leader>aq",
    textobject = "af",
    follow_up = "<CR>",
    handoff = "o",
    yank = "gy",
    yank_code = "gY",
  },
  animate = true, -- grow the answer window smoothly; false jumps to the content height
  -- Opens the interactive agent; argv resumes the session that was just asked.
  handoff = function(argv)
    vim.cmd("botright vnew")
    vim.fn.jobstart(argv, { term = true })
    vim.cmd.startinsert()
  end,
})
```

The asked lines are highlighted with `AskfnTarget`, linked to `CursorLine` by default.

### Backends

A backend is a table:

- `cmd`: argv of the CLI. The prompt (file path, line range, source and your question) is appended as the last argument.
- `output`: how the CLI writes its answer to stdout.
  - `"text"`: shown as it arrives.
  - `"claude-stream-json"`: Claude Code's `--output-format stream-json`; only the answer text is shown.
- `session` (optional): lets the plugin continue a conversation. Each first question runs under a fresh
  session id passed after `start`; follow-ups pass the same id after `resume`; `interactive` plus the id
  reopens the session in a terminal. Without `session` there is no follow-up and no handoff (pi, for now).

Switch to pi with `backend = "pi"`.

### Handing off to claudecode.nvim

By default `o` opens the session in a terminal split. To resume inside
[claudecode.nvim](https://github.com/coder/claudecode.nvim) instead (this ends the Claude session it
currently has open):

```lua
handoff = function(argv)
  vim.cmd("ClaudeCodeClose")
  vim.cmd("ClaudeCode --resume " .. argv[#argv])
end,
```

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```

## License

MIT
