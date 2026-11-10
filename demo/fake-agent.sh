#!/bin/sh
# Stand-in for the agent CLI in the demo: a pause as if thinking, then a fixed answer typed out.
# First question: --session-id <id> <prompt>. Follow-up: --resume <id> <question>.
dir=$(dirname "$0")
answer="$dir/answer-first.md"
for arg in "$@"; do
  [ "$arg" = "--resume" ] && answer="$dir/answer-follow-up.md"
done

sleep 2
perl -e '$| = 1; local $/; $_ = <>; for (split /(?<=\s)/) { print; select(undef, undef, undef, 0.035) }' "$answer"
