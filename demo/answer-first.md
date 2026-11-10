`backoff` doubles the wait on every attempt (`base_ms * 2 ^ attempt`) and caps it at `max_ms`.

The jitter adds up to 10% random delay on top. Without it, clients that failed together retry together, and the server gets hit by the whole crowd at once: a thundering herd.

One catch: the jitter is added before the cap. At the cap every client sleeps exactly `max_ms`, so the spread disappears.
