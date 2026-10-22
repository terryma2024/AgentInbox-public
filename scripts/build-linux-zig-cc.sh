#!/usr/bin/env bash
set -euo pipefail
: "${AGENTINBOX_ZIG:?Use build-linux-musl.sh to select the fixed Zig toolchain}"
# cc-rs detects Clang and appends Rust's four-part target spelling. Zig expects
# x86_64-linux-musl. Consume only those fixed target forms and forward all other
# arguments, including -Wl,..., without shell re-parsing.
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target=x86_64-unknown-linux-musl|--target=x86_64-linux-musl)
            shift ;;
        -target|--target)
            [[ $# -ge 2 && ( "$2" == x86_64-unknown-linux-musl || "$2" == x86_64-linux-musl ) ]] || { echo 'Unexpected compiler target' >&2; exit 64; }
            shift 2 ;;
        --target=*)
            echo 'Unexpected compiler target' >&2; exit 64 ;;
        *)
            args+=("$1"); shift ;;
    esac
done
exec "$AGENTINBOX_ZIG" cc -target x86_64-linux-musl "${args[@]}"
