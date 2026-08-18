#!/usr/bin/env bash
# safe.sh -- run a candidate assembler under a hard process cap and a
# wall-clock timeout. A bug in the fork path is a fork bomb, not a crash,
# so every parallel test goes through this rather than being run directly.
#   usage: safe.sh <assembler> [args...]
ulimit -u 64 2>/dev/null
exec timeout 20 "$@"
