local SymbolKind = vim.lsp.protocol.SymbolKind

local M = {}

local CALLABLE_KINDS = {
  [SymbolKind.Function] = true,
  [SymbolKind.Method] = true,
  [SymbolKind.Constructor] = true,
}

---@class askfn.Target
---@field name string? function name; nil for a plain selection
---@field start_line integer 1-based, inclusive
---@field end_line integer 1-based, inclusive

---Innermost function, method or constructor whose lines contain `line`.
---Accepts both LSP shapes: nested `DocumentSymbol[]` and flat `SymbolInformation[]`.
---@param symbols table[] result of textDocument/documentSymbol
---@param line integer 1-based cursor line
---@return askfn.Target?
function M.innermost_callable(symbols, line)
  local best
  for _, item in ipairs(symbols) do
    local range = item.range or item.location.range
    local start_line, end_line = range.start.line + 1, range["end"].line + 1
    if start_line <= line and line <= end_line then
      local candidate = M.innermost_callable(item.children or {}, line)
      if not candidate and CALLABLE_KINDS[item.kind] then
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

return M
