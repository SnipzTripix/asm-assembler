#!/usr/bin/env bash
# safe.sh -- run one test script under a hard wall-clock timeout.
#
#   usage: safe.sh <script> [args...]
#
# A bug in the fork path or the symbol table is a hang, not a crash: no
# output, no diagnostic, every core busy, forever. CI has no timeout of
# its own short of six hours, so an unguarded hang burns a whole runner.
# That is not hypothetical -- a narrowed worker table could fill and send
# the probe loop round its ring indefinitely, and it took an outside
# report to find, because nothing here would ever have stopped waiting.
#
# This used to also do `ulimit -u 64` to cap the process count. That is
# removed deliberately: on Linux RLIMIT_NPROC counts every process the
# *user* already has, not the ones this script starts, so on any machine
# with a desktop session it either fails everything instantly or does
# nothing at all, depending on what else is running. A cap that behaves
# differently on the developer's machine and CI is worse than no cap.
# Fork count is bounded where it belongs instead -- MAX_JOBS clamps the
# worker count, and the value is read from memory rather than carried in
# a register through a syscall, which is what made it a fork bomb once.
#
# The earlier version of this file claimed "every parallel test goes
# through this rather than being run directly" while nothing anywhere
# called it. run_all.sh runs every suite through it now.
# coreutils timeout, not a hand-rolled watchdog. The hand-rolled one was
# `( sleep N; kill $pid ) &` plus a kill of that subshell afterwards --
# which kills the subshell and leaves the sleep running, holding the
# write end of whatever pipe the suite was writing to. One orphan per
# test, so `run_all.sh > file` finished in 6 seconds and
# `run_all.sh | tail` sat there for three minutes waiting on EOF from
# twenty sleeps. It also called every signal death a timeout, since it
# only checked for status >= 128.
TIMEOUT=${SAFE_TIMEOUT:-180}
timeout -k 5 "$TIMEOUT" "$@"
rc=$?
if [ "$rc" -eq 124 ]; then
    echo "TIMED OUT after ${TIMEOUT}s: $*"
    exit 1
fi
exit "$rc"
