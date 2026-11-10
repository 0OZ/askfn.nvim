Seed the generator, then assert bounds instead of exact values:

```lua
math.randomseed(42)
local delay = M.backoff(3, 100, 10000)
assert(delay >= 800 and delay <= 880)
```

`2 ^ 3 * 100` is 800, and the jitter adds at most 80.
