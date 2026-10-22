# Native Linux build

AgentInbox's Linux artifact is compiled Rust machine code for `x86_64-unknown-linux-musl`. The intended deployment executable is `dist/linux/agentinbox`; it does not launch Python, Node, Java, Cargo, or Zig on the target machine. SQLite and TLS dependencies are compiled into the native binary (`rusqlite` uses bundled SQLite; `reqwest` uses rustls).

## Reproduce on Apple Silicon macOS

Prerequisites: Cargo **1.96.1**, Bash, curl, tar, shasum, and the `Cargo.lock` dependency cache. Build-tool archives are downloaded from official distribution sites and checked against fixed SHA256 values before extraction. The script manually extracts the official Rust compiler and both Apple host and Linux target standard libraries into a temporary sysroot without executing `install.sh` or changing the installed compiler. Matching official host libraries support Cargo build scripts and procedural macros. Homebrew Rust 1.96.1 has a different compiler metadata marker and was observed to reject the official Linux libraries with E0514, despite sharing the version and commit hash. Zig supplies the C compiler and ELF linker for `ring` and bundled SQLite.

```sh
cd /path/to/AgentInbox
./scripts/build-linux-musl.sh
```

The script runs:

```sh
cargo build --release --locked --offline --target x86_64-unknown-linux-musl
```

`--offline` deliberately requires cached Cargo dependencies. On a fresh developer machine, fetch the dependencies with `cargo fetch --locked` before the cross-build, using the project's dependency-review policy. This download is a build-host prerequisite, not a target runtime requirement.

By default, temporary build tools, Rust sysroot and Zig caches live in `/private/tmp/AgentInboxLinuxTools`; Cargo products live in `/private/tmp/AgentInboxLinuxBuild`. Set `AGENTINBOX_LINUX_TOOLS` and `AGENTINBOX_LINUX_BUILD` to change those locations. Use paths without spaces because `RUSTFLAGS` contains the sysroot path. `RUSTC` points directly to the temporary official compiler; no system compiler replacement or global Rust target installation occurs. The environment overrides apply only to this build process. The script does not alter shell startup files, system PATH, Homebrew, or remote servers.

The `build-linux-zig-cc.sh` and `build-linux-zig-ar.sh` wrappers are development build tools. They forward compiler/linker arguments directly as shell arguments and are never needed by `agentinbox` on Linux. The C target is fixed to `x86_64-linux-musl`; Rust explicitly enables static CRT linking and disables its own startup-object selection (`-C link-self-contained=no`), so Zig supplies one consistent musl CRT. A minimal link probe found duplicate `_start` symbols when both Rust and Zig supplied startup objects; selecting Zig alone produced a static ELF without `INTERP` or a dynamic section.

## Fixed archive provenance

| Build input | Official source | SHA256 |
| --- | --- | --- |
| Rust 1.96.1 Apple Silicon compiler | [static.rust-lang.org](https://static.rust-lang.org/dist/rustc-1.96.1-aarch64-apple-darwin.tar.xz) | `9b548f0665f85f3c7fd45165611e3dea79f048c69d163be193986310d204fc2c` |
| Rust 1.96.1 Apple Silicon standard library | [static.rust-lang.org](https://static.rust-lang.org/dist/rust-std-1.96.1-aarch64-apple-darwin.tar.xz) | `0d433a74c303febc915f8fa1091ef166445706461d0c96984ecb7303aa8208f5` |
| Rust 1.96.1 Linux musl standard library | [static.rust-lang.org](https://static.rust-lang.org/dist/rust-std-1.96.1-x86_64-unknown-linux-musl.tar.xz) | `94192fe7e10f11e8595f2a29ebda182da0f786797fe908f44fbf80213cd845ac` |
| Zig 0.15.2 for Apple Silicon macOS | [ziglang.org](https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz) | `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b` |

Rust's official companion `.sha256` files supplied all Rust digests. The official [Zig download index](https://ziglang.org/download/index.json), entry `0.15.2.aarch64-macos`, supplied the Zig digest and version. Both are pinned in the build script.

## Verify the deliverable

```sh
cd dist/linux
shasum -a 256 -c SHA256SUMS
file agentinbox
llvm-readelf --file-header --program-headers --dynamic agentinbox
```

The build also records source checksums in `SOURCE-SHA256SUMS` and refuses to publish an artifact if inputs change during compilation.

An x86-64 ELF with no `INTERP` program header and no `NEEDED` dynamic entries does not require a separately installed ELF loader or shared libraries. A static PIE may still contain a dynamic section used for self-relocation. Checking only whether a dynamic section exists is insufficient.

A successful cross-compilation and ELF inspection establish the binary format and linking properties. They do **not** establish Linux runtime behavior, actual Codex/Claude integration, APNs delivery, service installation, or Ubuntu acceptance. No remote upload, deployment, or execution is part of this build workflow. Perform the separately authorized Linux runtime acceptance after deployment approval.

## Recorded final build result (2026-10-14)

The frozen APNs provider JWT **50-minute cache** change passed all **47 native tests**, including a deterministic public-fixture cache regression. The final Linux incremental release build succeeded in **3.63 seconds**, reusing verified tools without further downloads. The source manifest includes every file under `src` and `vendor/tiny_http`, including both original licenses and the local patch record.

The artifact is **7,117,968 bytes**, `ELF64`, x86-64, `EXEC`, statically linked and stripped. SHA256: `7113dd64f0851a852a1325ca8d646a416acc5e81ac210fd9a1dd60a4340588a1`. Source manifest SHA256: `854a7e82b8794c577b50a2bee41d58e98b3e077c4b82fb65f1b94a9eb01a23f0`; all **38** input hashes match, including final `src/apns.rs`. LLVM readelf finds no `INTERP`, dynamic section or `NEEDED` shared libraries.

The approved Japan relay upgrade now runs `/opt/agentinbox/releases/0.1.0-jwt-cache/agentinbox`; actual process path, native usage, HTTP authentication/host isolation and pre-upgrade heartbeat persistence were checked. The old `0.1.0` binary remains intact. Server APNs is null, so this proves native deployment and the tested code change, not actual Apple delivery.

Evidence: `evidence/linux-jwt-cache-release.log`, `evidence/linux-final-source-check.log`, `evidence/linux-elf.txt`, `evidence/linux-build-verification.json`, `evidence/linux-jwt-cache-upgrade.log`, and `evidence/linux-jwt-cache-native-verification.json`. [Deployment details](LINUX-DEPLOYMENT.md) include the protected backup and the now-verified private HTTPS 8443 endpoint. Earlier build records remain available.
