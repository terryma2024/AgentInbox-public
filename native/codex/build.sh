#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SCRATCH="$REPO_ROOT/.superpowers/native-reply"
SOURCE="$SCRATCH/upstream"
ACTION=${1:-build}
case "$ACTION" in prepare|test|build) ;; *) echo 'Usage: build.sh prepare|test|build' >&2; exit 2 ;; esac
mkdir -p "$SCRATCH"
REVISION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$SCRIPT_DIR/UPSTREAM.json")
if [ ! -f "$SCRATCH/prepared-source.json" ]; then
    if [ -e "$SOURCE" ]; then
        echo 'Refusing to overwrite an existing source tree; use a separate clean checkout.' >&2
        exit 1
    fi
    curl -fL --retry 2 "https://codeload.github.com/openai/codex/tar.gz/$REVISION" -o "$SCRATCH/upstream.tar.gz"
    python3 - "$SCRIPT_DIR/UPSTREAM.json" "$SCRATCH/upstream.tar.gz" <<'PY'
import hashlib, json, sys
pin = json.load(open(sys.argv[1]))
with open(sys.argv[2], "rb") as source:
    actual = hashlib.file_digest(source, "sha256").hexdigest()
if actual != pin["archiveSha256"]:
    raise SystemExit("Upstream archive checksum mismatch")
PY
    mkdir "$SOURCE"
    tar -xzf "$SCRATCH/upstream.tar.gz" --strip-components=1 -C "$SOURCE"
    patch --batch -d "$SOURCE" -p1 < "$SCRIPT_DIR/agentinbox-receipt.patch"
    python3 - "$SCRIPT_DIR/UPSTREAM.json" "$SCRIPT_DIR/agentinbox-receipt.patch" "$SOURCE" "$SCRATCH/prepared-source.json" <<'PYPREPARE'
import hashlib, json, pathlib, sys
pin, patch, source, marker = map(pathlib.Path, sys.argv[1:])
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
files = [line[6:] for line in patch.read_text().splitlines() if line.startswith("+++ b/")]
state = {"revision": json.loads(pin.read_text())["revision"], "patchSha256": digest(patch),
         "files": {name: digest(source / name) for name in files}}
marker.write_text(json.dumps(state, sort_keys=True))
PYPREPARE
fi
python3 - "$SCRIPT_DIR/UPSTREAM.json" "$SCRIPT_DIR/agentinbox-receipt.patch" "$SOURCE" "$SCRATCH/prepared-source.json" <<'PYVERIFY'
import hashlib, json, pathlib, sys
pin, patch, source, marker = map(pathlib.Path, sys.argv[1:])
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
state = json.loads(marker.read_text())
files = [line[6:] for line in patch.read_text().splitlines() if line.startswith("+++ b/")]
valid = state.get("revision") == json.loads(pin.read_text())["revision"] and state.get("patchSha256") == digest(patch)
valid = valid and set(state.get("files", {})) == set(files)
valid = valid and all((source / name).is_file() and digest(source / name) == state["files"][name] for name in files)
if not valid:
    raise SystemExit("Prepared native source is stale or modified; retain it privately and prepare a fresh clean checkout.")
PYVERIFY
[ "$ACTION" != prepare ] || exit 0
export RUSTUP_HOME="$SCRATCH/rustup"
export CARGO_HOME="$SCRATCH/cargo"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}
export CARGO_PROFILE_DEV_DEBUG=0
export CARGO_PROFILE_TEST_DEBUG=0
CARGO_ENCODED_RUSTFLAGS=$(python3 - "$HOME" "$REPO_ROOT" <<'PYFLAGS'
import os, shlex, sys
encoded = os.environ.get("CARGO_ENCODED_RUSTFLAGS")
flags = encoded.split("\x1f") if encoded else shlex.split(os.environ.get("RUSTFLAGS", ""))
flags += [f"--remap-path-prefix={sys.argv[1]}=/private-build", f"--remap-path-prefix={sys.argv[2]}=/workspace"]
print("\x1f".join(flags), end="")
PYFLAGS
)
export CARGO_ENCODED_RUSTFLAGS
TOOLCHAIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rustToolchain"])' "$SCRIPT_DIR/UPSTREAM.json")
rustup toolchain install "$TOOLCHAIN" --profile minimal
cd "$SOURCE/codex-rs"
if [ "$ACTION" = test ]; then
    rustup run "$TOOLCHAIN" cargo test --locked -p codex-app-server --lib agentinbox
else
    rustup run "$TOOLCHAIN" cargo build --locked -p codex-app-server --bin codex-app-server
fi
