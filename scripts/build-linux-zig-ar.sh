#!/usr/bin/env bash
set -euo pipefail
: "${AGENTINBOX_ZIG:?Use build-linux-musl.sh to select the fixed Zig toolchain}"
exec "$AGENTINBOX_ZIG" ar "$@"
