#!/usr/bin/env bash
# Cross-build only; never installs a runtime or deploys to a remote host.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tools_dir="${AGENTINBOX_LINUX_TOOLS:-/private/tmp/AgentInboxLinuxTools}"
build_dir="${AGENTINBOX_LINUX_BUILD:-/private/tmp/AgentInboxLinuxBuild}"
readonly target=x86_64-unknown-linux-musl
readonly rust_version=1.96.1
readonly zig_version=0.15.2
readonly rust_archive=rust-std-1.96.1-x86_64-unknown-linux-musl.tar.xz
readonly zig_archive=zig-aarch64-macos-0.15.2.tar.xz
readonly compiler_archive=rustc-1.96.1-aarch64-apple-darwin.tar.xz
readonly host_archive=rust-std-1.96.1-aarch64-apple-darwin.tar.xz
readonly compiler_sha=9b548f0665f85f3c7fd45165611e3dea79f048c69d163be193986310d204fc2c
readonly host_sha=0d433a74c303febc915f8fa1091ef166445706461d0c96984ecb7303aa8208f5
readonly rust_sha=94192fe7e10f11e8595f2a29ebda182da0f786797fe908f44fbf80213cd845ac
readonly zig_sha=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This script requires an Apple Silicon macOS build host.' >&2; exit 1; }
[[ "$(cargo --version | awk '{print $2}')" == "$rust_version" ]] || { echo "Install Cargo $rust_version before building." >&2; exit 1; }
mkdir -p "$tools_dir" "$build_dir" "$root/dist/linux"
verify() { printf '%s  %s\n' "$2" "$1" | shasum -a 256 -c -; }
fetch() {
    local archive="$1" url="$2" digest="$3"
    if [[ ! -f "$tools_dir/$archive" ]]; then
        curl --fail --location --retry 2 --output "$tools_dir/$archive.part" "$url"
        verify "$tools_dir/$archive.part" "$digest"
        mv "$tools_dir/$archive.part" "$tools_dir/$archive"
    fi
    verify "$tools_dir/$archive" "$digest"
}
fetch "$compiler_archive" "https://static.rust-lang.org/dist/$compiler_archive" "$compiler_sha"
fetch "$host_archive" "https://static.rust-lang.org/dist/$host_archive" "$host_sha"
fetch "$rust_archive" "https://static.rust-lang.org/dist/$rust_archive" "$rust_sha"
fetch "$zig_archive" "https://ziglang.org/download/$zig_version/$zig_archive" "$zig_sha"
if [[ ! -x "$tools_dir/zig-aarch64-macos-$zig_version/zig" ]]; then
    tar -xf "$tools_dir/$zig_archive" -C "$tools_dir"
fi
if [[ ! -d "$tools_dir/rust-std-$rust_version-$target/rust-std-$target/lib/rustlib/$target" ]]; then
    tar -xf "$tools_dir/$rust_archive" -C "$tools_dir"
fi
if [[ ! -x "$tools_dir/rustc-$rust_version-aarch64-apple-darwin/rustc/bin/rustc" ]]; then
    tar -xf "$tools_dir/$compiler_archive" -C "$tools_dir"
fi
if [[ ! -d "$tools_dir/rust-std-$rust_version-aarch64-apple-darwin/rust-std-aarch64-apple-darwin/lib/rustlib/aarch64-apple-darwin" ]]; then
    tar -xf "$tools_dir/$host_archive" -C "$tools_dir"
fi
sysroot="$tools_dir/rustc-$rust_version-aarch64-apple-darwin/rustc"
mkdir -p "$sysroot/lib/rustlib"
if [[ ! -d "$sysroot/lib/rustlib/aarch64-apple-darwin/lib" ]]; then
    cp -R "$tools_dir/rust-std-$rust_version-aarch64-apple-darwin/rust-std-aarch64-apple-darwin/lib/rustlib/aarch64-apple-darwin" "$sysroot/lib/rustlib/"
fi
export RUSTC="$sysroot/bin/rustc"
if [[ ! -d "$sysroot/lib/rustlib/$target" ]]; then
    cp -R "$tools_dir/rust-std-$rust_version-$target/rust-std-$target/lib/rustlib/$target" "$sysroot/lib/rustlib/"
fi
export AGENTINBOX_ZIG="$tools_dir/zig-aarch64-macos-$zig_version/zig"
export ZIG_GLOBAL_CACHE_DIR="$tools_dir/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$build_dir/zig-cache"
export CARGO_TARGET_DIR="$build_dir"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$root/scripts/build-linux-zig-cc.sh"
export CC_x86_64_unknown_linux_musl="$root/scripts/build-linux-zig-cc.sh"
export AR_x86_64_unknown_linux_musl="$root/scripts/build-linux-zig-ar.sh"
export RUSTFLAGS="--sysroot $sysroot -C target-feature=+crt-static -C link-self-contained=no"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
"$AGENTINBOX_ZIG" version
"$RUSTC" --version --verbose
cd "$root"
record_inputs() {
    shasum -a 256 Cargo.toml Cargo.lock rust-toolchain.toml
    find src vendor/tiny_http -type f -print | LC_ALL=C sort | while IFS= read -r source; do shasum -a 256 "$source"; done
}
record_inputs > "$build_dir/linux-inputs.before.sha256"
cargo build --release --locked --offline --target "$target"
record_inputs > "$build_dir/linux-inputs.after.sha256"
cp "$build_dir/linux-inputs.before.sha256" "$root/dist/linux/SOURCE-SHA256SUMS"
if ! cmp -s "$build_dir/linux-inputs.before.sha256" "$build_dir/linux-inputs.after.sha256"; then
    echo 'Source changed during compilation. Rebuild after edits settle before release.' >&2
    exit 1
fi
cp "$build_dir/$target/release/agentinbox" "$root/dist/linux/agentinbox"
chmod 755 "$root/dist/linux/agentinbox"
(cd "$root/dist/linux" && shasum -a 256 agentinbox > SHA256SUMS)
file "$root/dist/linux/agentinbox"
cat "$root/dist/linux/SHA256SUMS"
