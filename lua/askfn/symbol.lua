local SymbolKind = vim.lsp.protocol.SymbolKind

local M = {}

---@class askfn.Target
---@field name string? function or type name; nil for a plain selection
---@field start_line integer 1-based, inclusive
---@field end_line integer 1-based, inclusive

---What a key looks for in the document symbols.
---@class askfn.Scope
---@field noun string what the target is called, in notices and in the prompt
---@field kinds table<integer, boolean> LSP symbol kinds that count as one

---@type askfn.Scope
M.FUNCTION = {
  noun = "function",
  kinds = {
    [SymbolKind.Function] = true,
    [SymbolKind.Method] = true,
    [SymbolKind.Constructor] = true,
  },
}

---A Rust trait is an interface and an impl block is an object, as far as language servers say.
---@type askfn.Scope
M.TYPE = {
  noun = "type",
  kinds = {
    [SymbolKind.Class] = true,
    [SymbolKind.Struct] = true,
    [SymbolKind.Enum] = true,
    [SymbolKind.Interface] = true,
    [SymbolKind.Object] = true,
  },
}

---Innermost symbol of the scope whose lines contain `line`.
---Accepts both LSP shapes: nested `DocumentSymbol[]` and flat `SymbolInformation[]`.
---@param symbols table[] result of textDocument/documentSymbol
---@param line integer 1-based cursor line
---@param scope askfn.Scope
---@return askfn.Target?
function M.innermost(symbols, line, scope)
  local best
  for _, item in ipairs(symbols) do
    local range = item.range or item.location.range
    local start_line, end_line = range.start.line + 1, range["end"].line + 1
    if start_line <= line and line <= end_line then
      local candidate = M.innermost(item.children or {}, line, scope)
      if not candidate and scope.kinds[item.kind] then
        candidate = { name = item.name, start_line = start_line, end_line = end_line }
      end
      -- Flat lists carry a closure as a sibling of its parent: the later start is the inner one.
      if candidate and (not best or candidate.start_line >= best.start_line) then
        best = candidate
      end
    end
  end
  return best
end

---@param symbols table[]
---@param line integer
---@return askfn.Target?
function M.innermost_callable(symbols, line)
  return M.innermost(symbols, line, M.FUNCTION)
end

return M
