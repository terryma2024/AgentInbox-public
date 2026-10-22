# Native reply proof implementation plan

> **For agentic workers:** Execute with subagent-driven-development. Native engine integration and host observation have separate files; review the combined behavior before real-device acceptance.

**Goal:** Establish reply provenance at native callback arbitration without changing the original answer, then qualify reception and continuation on a real phone.

**Architecture:** Opt-in Codex extension writes private durable arbitration receipts. The host sends `_agentinboxReceipt` outside the original answer map; the patched engine strips that envelope before forwarding the original result. A native receipt alone is insufficient: host also verifies the exact original function output and subsequent execution chain. Unmodified engines retain source-unknown behavior.

**Tech Stack:** Rust, JSON, filesystem durability, existing relay and Swift clients.

**Spec:** Existing reply reliability design plus `docs/REPLY-NATIVE-PROOF-AUDIT.md`; user approved native interface extension with original answer content preserved.

## Global constraints

- No extra question, turn, answer-map entry, invisible answer character, or natural-language marker.
- Only native winner arbitration may produce the source receipt. First write, helper exit and resolved are insufficient.
- Same-value local winners never confirm phone reception.
- Persist dispatch before sending; recovery reads receipts, never replays answers.
- Private evidence, credentials and installation identifiers remain ignored; public files use synthetic fixtures.

## Task 1: Native extension

Files: `native/codex/` reproducible patch and upstream revision; upstream source/build tree only in ignored scratch.

- [x] Pin a public upstream revision and inspect actual callback arbitration and transport.
- [x] Add failing native tests for phone winner, same-value local winner, cancelled receiver, metadata stripping and invalid bindings.
- [x] Implement opt-in private receipt directory and `_agentinboxReceipt` envelope stripping at the winner callback. Validate complete original identity against the original native request. Record requestId, dispatchId, bindingDigest, original callback, original result, native process ID and schemaVersion; no receipt when receiver handoff fails. Atomic private files and directory fsync; reject unsafe paths. Native receipts are provenance, not proof the original tool has produced output.
- [x] Build and run the patched real engine; produce a reproducible public patch and license notice, never commit a binary or the fetched source tree.

## Task 2: Host source and progress

Files: `src/native_receipt.rs`, `src/reply_evidence.rs`, `src/host.rs`, integration tests.

- [x] Add failing tests that reject missing, wrong, tampered, duplicate and same-value local source receipts.
- [x] Persist a unique dispatch ID before send and pass it in `_agentinboxReceipt` outside `answers` only for opted-in native engines.
- [x] Combine native arbitration receipt with exact original output to produce received; retain observation to continued, timeout or explicit failure. Send cumulative bound progress via existing durable outbox.
- [x] Keep old engines conservative; preserve received when continuation becomes unknown; recovery must not resend an answer.

## Task 3: Qualification

- [x] Run meaningful targeted tests, then full native and relevant iOS checks. Independently review source attribution and lifecycle boundaries.
- [x] Run isolated real-engine questions and same-value competition; inspect native arbitration and original output without exposing private IDs.
- [x] Validate actual phone App and Widget against the qualified path, duplicate submissions and lost-response/restart recovery. Separate controlled transport races from physical keyboard competition.
- [x] Update completion status only for combinations supported by actual evidence. Missing engine or physical evidence remains explicit.

## Outcome · 2026-10-22

Qualified on macOS with the pinned optional real Codex engine, deterministic local provider, production relay and a real iPhone. App and Widget used separate fresh original calls, one dispatch each, unchanged original answer. Received was observed while continuation was held; continued required releasing the original execution. Widget started with the App stopped and never opened it. Lost receipt response, host exit/restart and natural same-value local arbitration passed independently.

Rust: 130 passed, 0 failed, 3 ignored. iOS unit: 127 passed, 6 configured integration checks skipped; conservative milestone UI regression passed. Native extension: 12 new tests within 44 passing outgoing-module tests. Source and lifecycle reviews completed. Physical App first exposed stale captured scene phase; diagnostic reproduction preceded the polling fix and a passing fresh-call retest. Widget first exposed a test harness Home-key failure; terminating the App and activating SpringBoard established the correct acceptance surface.

Installed Codex engines remain unchanged. Unmodified Codex/Claude remain source-unconfirmed; Linux extension, physical keyboard and external-model combinations are not qualified by these tests. Local debug/native binaries are not release artifacts. See the public reliability record for support limits; raw evidence remains ignored.
