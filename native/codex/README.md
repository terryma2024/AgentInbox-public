# Optional native reply provenance

This directory contains an independently reviewable patch against the exact public
OpenAI Codex revision in `UPSTREAM.json`. It does not modify or replace an installed
Codex engine. The original answer map and strings are unchanged.

The extension adds local provenance at `OutgoingMessageSender::notify_client_response`:
only the response that takes the original pending callback and successfully sends
the result to its receiver can write a receipt. A successful handoff is not proof
that the original tool produced output or that its turn continued. AgentInbox must
independently check the original rollout before announcing those milestones.

## Reproduce

Prerequisites: Unix, Python 3, curl, tar, patch, Git, a native C/C++ build toolchain,
and rustup. Upstream Cargo dependencies include public pinned Git repositories;
the first build can require significant download, CPU, memory and disk space.

```sh
native/codex/build.sh prepare
native/codex/build.sh test
native/codex/build.sh build
```

Source, toolchain, Cargo cache and binary stay below ignored
`.superpowers/native-reply/`. The source archive SHA-256 is checked before extraction;
Cargo uses the upstream lockfile. Cached sources are checked against the pinned
revision, canonical patch SHA-256 and exact patched file digests; stale or modified
trees are refused. The build remaps local source paths and disables
debug information. No binary is intended to be committed or distributed. If a
binary will be released, inspect the actual artifact separately for private strings.

Use a **fresh, empty, canonical absolute directory** owned by the engine user with
mode `0700` for each engine process. A stale manifest prevents receipt capability
from activating. No receipt capability is active without the environment variable:

```sh
AGENTINBOX_NATIVE_RECEIPT_DIR=/absolute/private/receipts \
CODEX_HOME=/absolute/private/isolated-codex-home \
  /absolute/private/codex-app-server --listen unix:///absolute/private/control.sock
```

The standalone binary also supports `stdio://` and `ws://127.0.0.1:PORT` transports.
The Unix endpoint uses WebSocket framing over a Unix socket. Keep the installed
engine and its live sessions running independently during qualification.

A controlled qualification uses the real built engine with two Unix WebSocket
clients and a deterministic loopback Responses provider. It checks both winners,
exact original tool output and subsequent continuation:

```sh
python3 native/codex/qualify.py \
  --binary .superpowers/native-reply/upstream/codex-rs/target/debug/codex-app-server \
  --output .superpowers/native-reply/qualification-fresh
```

The output directory must not exist. It contains private raw protocol/rollout
records and stays ignored. This controlled transport exercise does not establish
physical phone, keyboard, or external model acceptance.

## Wire and disk contract, schema 1

Manifest `manifest.json`:

```json
{"schemaVersion":1,"nativePid":12345,"nativeInstanceId":"20000000-0000-4000-8000-000000000001"}
```

The host attaches this reserved member **beside** `answers` in the JSON-RPC result,
only after explicit local configuration and validation of the manifest and process:

```json
{
  "answers":{"fixture-question":{"answers":["yes"]}},
  "_agentinboxReceipt":{
    "schemaVersion":1,
    "dispatchId":"10000000-0000-4000-8000-000000000001",
    "bindingDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "nativeInstanceId":"20000000-0000-4000-8000-000000000001"
  }
}
```

The reserved metadata is removed before upstream analytics and the callback,
including when receipt capability is disabled or metadata is invalid. Missing or
invalid metadata cannot create a receipt, but original answer delivery remains
unchanged. Metadata rejects unknown fields, noncanonical or nil UUIDs, mismatched
process instance, unsupported schema and digests other than 64 lowercase hex bytes.
Only a valid typed response to `item/tool/requestUserInput` is eligible.

A winner creates `dispatch-DISPATCH_UUID.json` containing:

```json
{
  "schemaVersion":1,
  "nativePid":12345,
  "nativeInstanceId":"20000000-0000-4000-8000-000000000001",
  "dispatchId":"10000000-0000-4000-8000-000000000001",
  "bindingDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "callback":{"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"fixture-thread","turnId":"fixture-turn","itemId":"fixture-call","questions":[],"isBlocking":true,"autoResolutionMs":null}},
  "result":{"answers":{"fixture-question":{"answers":["yes"]}}}
}
```

`callback` is the complete original upstream server request, with its original
request ID and all parameters. `result` is the original JSON value after removing
only the reserved envelope. The host is responsible for computing and checking
`bindingDigest`, exact callback/result matching, and the original execution output.
The engine validates digest syntax and records the actual binding bytes rather
than trusting client-supplied callback identity.

Files are mode `0600`, written to an exclusive temporary file, fsynced, atomically
published with no replacement, and followed by directory fsync. Directory traversal
uses fd-relative no-follow operations; every path component rejects symlinks. The
final directory must retain owner-only `0700` access. Existing manifests, dispatch
files and symlinks fail closed. The process nonce prevents PID reuse and receipt
reuse across engine instances. Failed or unavailable callback handoff writes no
receipt. Filesystem failures can yield a missing receipt after a valid answer;
the host must keep reception unknown in that case and must never retry the answer
as a consequence of missing provenance.

Receipts contain private original question/answer and execution identifiers. They
must remain local and ignored; only sanitized fixture results belong in public
artifacts. This is a trusted local same-user channel, not an attestation against
malicious code running under that same account.

## Validation status

The pinned engine compiled and ran on macOS. The 12 new native tests and all 44
outgoing-message module tests passed. Two controlled real-engine cases passed:
phone winner produced one bound receipt; same-value local winner produced none.
Both preserved the exact original answer and continued the original turn through
the local fixture provider. These are protocol races, not physical keyboard tests.

The local qualification binary is not a release artifact: byte inspection still
found dependency build-location strings despite Rust path remapping. It remains
ignored and must not be published without a separately cleaned and inspected build.

## License

Upstream Codex and this extension patch are Apache-2.0. See `LICENSE.upstream` and
`NOTICE.upstream` for preserved upstream license and attribution. Fetched source
retains its own additional third-party notices.
