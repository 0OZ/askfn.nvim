# askfn.nvim

Ask a coding agent about the function under your cursor, without leaving the buffer.

- `af` text object: the whole function, signature included (`vaf`, `yaf`, `daf`)
- `<leader>aq`: popup for a question about that function, answer in a floating window
- In visual mode `<leader>aq` asks about the selection instead
- `o` in the answer window: continue the same conversation in an interactive agent terminal
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

## Configuration

Defaults:

```lua
require("askfn").setup({
  backend = "claude",
  backends = {
    claude = {
      cmd = { "claude", "-p", "--model", "claude-sonnet-5-5", "--effort", "xhigh" },
      session = { flag = "--session-id", resume = { "claude", "--resume" } },
    },
    pi = { cmd = { "pi", "-p", "--thinking", "xhigh" } },
  },
  keys = {
    ask = "<leader>aq", -- false to disable
    textobject = "af", -- false to disable
    handoff = "o", -- inside the answer window; false to disable
  },
  -- Opens the interactive agent; argv resumes the session that was just asked.
  handoff = function(argv)
    vim.cmd("botright vnew")
    vim.fn.jobstart(argv, { term = true })
    vim.cmd.startinsert()
  end,
})
```

Switch to pi with `backend = "pi"`. Add your own backend by giving it a `cmd`; the prompt
(file path, line range, function source and your question) is appended as the last argument.

In the answer window, `q` or `<Esc>` closes it. Closing it while the agent is still working stops the agent.

### Continuing in the agent

A backend with a `session` runs each question under a fresh session id. Once the answer is in,
`o` closes the float and calls `handoff` with the command that resumes that session, by default
in a terminal split. Backends without `session` (pi, for now) have no handoff key.

To resume inside [claudecode.nvim](https://github.com/coder/claudecode.nvim) instead (this ends
the Claude session it currently has open):

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
