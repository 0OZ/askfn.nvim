local M = {}

---Wait before retry number `attempt` (0-based), in milliseconds.
function M.backoff(attempt, base_ms, max_ms)
  local delay = base_ms * 2 ^ attempt
  local jitter = math.random() * delay * 0.1
  return math.min(delay + jitter, max_ms)
end

function M.should_retry(status)
  return status == 429 or status >= 500
end

return M
