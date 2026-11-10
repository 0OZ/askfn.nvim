-- Self-contained config for recording the demo: nvim -u demo/init.lua demo/sample.lua
-- Real language server, scripted agent (demo/fake-agent.sh), so every run looks the same.
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "

vim.o.number = true
vim.o.termguicolors = true
vim.o.cmdheight = 0
vim.o.laststatus = 0
vim.o.showmode = false
vim.o.ruler = false
vim.o.signcolumn = "no"
vim.o.swapfile = false
vim.o.shortmess = "filnxtToOFIc"
vim.cmd.colorscheme("habamax")

-- Mason's bin dir, when present, so the demo finds lua-language-server.
vim.env.PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH

vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function(args)
    vim.lsp.start({ name = "lua_ls", cmd = { "lua-language-server" }, root_dir = root }, { bufnr = args.buf })
  end,
})

require("askfn").setup({
  backend = "claude",
  backends = {
    claude = {
      cmd = { "sh", root .. "/demo/fake-agent.sh" },
      output = "text",
      session = { start = "--session-id", resume = "--resume", interactive = { "true" } },
    },
  },
})
