#!/usr/bin/env bash
# Runs the interpreter fuzzer, and whenever it crashes, archives the input to
# `fuzz-crashes/crash-N` and starts fuzzing again. `zig build --fuzz` stops
# every instance after the first crash, and only keeps the latest crash input.
#
# Usage: ./fuzz.sh [extra zig build args, e.g. --webui=[::1]:33127]
# Environment: FUZZ_FILTER (default "Interp fuzz"), CRASH_DIR (default fuzz-crashes).
set -euo pipefail

cd "$(dirname "$0")"
filter=${FUZZ_FILTER:-Interp fuzz}
crash_dir=${CRASH_DIR:-fuzz-crashes}
mkdir -p "$crash_dir"

fuzz_pid=
stop_fuzzer() {
    if [[ -n $fuzz_pid ]]; then
        # The build runner spawns one test process per core, so take down its
        # whole process group, not just `zig build`.
        kill -- "-$fuzz_pid" 2>/dev/null || true
        wait "$fuzz_pid" 2>/dev/null || true
        fuzz_pid=
    fi
}
trap 'stop_fuzzer; exit 130' INT TERM

# Archives `$1` unless an identical input is already archived, since the
# fuzzer tends to rediscover the same crash after a restart.
archive_crash() {
    local input=$1
    local hash existing
    hash=$(sha256sum "$input" | cut -d' ' -f1)
    for existing in "$crash_dir"/crash-*; do
        [[ -e $existing ]] || continue
        if [[ $(sha256sum "$existing" | cut -d' ' -f1) == "$hash" ]]; then
            echo "fuzz.sh: crash input is identical to $existing, not archiving it again"
            return
        fi
    done

    local i=0
    while [[ -e $crash_dir/crash-$i ]]; do i=$((i + 1)); done
    cp "$input" "$crash_dir/crash-$i"
    echo "fuzz.sh: archived crash input to $crash_dir/crash-$i"
}

while true; do
    # `setsid` makes `zig build` the leader of a new process group (see
    # `stop_fuzzer`). In forever mode it keeps running after a crash, serving the
    # web UI, so the crash is detected from its output rather than its exit.
    coproc FUZZ {
        exec setsid zig build test -Duse-llvm=true -Dtrace-mem=false \
            -Doptimize=ReleaseSafe -Dtest-filter="$filter" --fuzz "$@" 2>&1
    }
    fuzz_pid=$FUZZ_PID

    crash_input=
    while IFS= read -r line <&"${FUZZ[0]}"; do
        printf '%s\n' "$line"
        # Printed once the crash input has been fully written, e.g.
        # error: test '...' terminated with signal ABRT; input saved to '.zig-cache/f/crash'
        if [[ $line == *"input saved to '"* ]]; then
            crash_input=${line#*input saved to \'}
            crash_input=${crash_input%%\'*}
            break
        fi
    done

    if [[ -z $crash_input ]]; then
        # Exited without crashing, such as on a compile error, or a `--fuzz=N` limit.
        status=0
        wait "$fuzz_pid" || status=$?
        exit "$status"
    fi

    stop_fuzzer
    archive_crash "$crash_input"
    echo "fuzz.sh: restarting the fuzzer"
done
