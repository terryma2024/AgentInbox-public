# Reply Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make submission, original-call reception, and subsequent execution independently provable and recoverable without replaying an answer.

**Architecture:** Keep legacy lifecycle states. Add transactional, cumulative progress records bound to the immutable request and winning response; native observers provide structured evidence, while shared Swift logic validates and presents it.

**Tech Stack:** Rust 1.96, bundled SQLite, Swift 5/iOS 17, existing dependencies only.

**Spec:** ../specs/2026-10-22-reply-reliability-design.md

## Global Constraints

- Preserve existing RequestState strings and single-dispatch/claim guards.
- Never infer reception from HTTP success, helper output, resolved alone, or natural-language markers.
- Keep host/device credentials and raw native transcripts out of device progress views.
- Unknown outcomes permit read-only reconciliation; only explicit user retry of an unchanged pending original answer may POST.
- Keep old database table layouts intact; legacy adopted cannot generate new milestones.
- Work on the prepared `codex/reply-reliability` branch in this checkout; production deployment remains a separate concrete review step.

## Task 1: Transactional progress and protocol

**Files:** Create `src/reply_progress.rs`, `tests/reply_progress.rs`; modify `src/{lib,store,relay}.rs`.

**Interfaces:** `binding_digest(&Value) -> String`; `Store::incomplete_progress(&str) -> ApiResult<Vec<Value>>`; requests and submission receipts expose `bindingDigest` and `replyProgress`. Host receipts accept a versioned, cumulative proof envelope. Authenticated `/v1/capabilities` advertises version 1.

- [x] Write failing store tests for submission-only progress, legacy adopted, empty/wrong-binding proofs, received/continued merge, out-of-order proof delivery, ownership, and restart.

```rust
let q = store.get("q", false).unwrap();
assert_eq!(q["replyProgress"]["submitted"]["at"], 1001);
assert!(q["replyProgress"]["received"].is_null());
assert!(q["replyProgress"]["continued"].is_null());
```

- [x] Run `cargo test --locked --offline --test reply_progress`; expect assertion failures because fields are absent.
- [x] Add independent progress table, canonical digest, strict typed proof validation, cumulative/idempotent merge, safe device projection, complete host recovery reads and upgrade counts. Preserve existing tables and old receipts.

```rust
// Within the answer transaction, bind submission to the immutable request.
reply_progress::record_submission(&tx, &q, &a, time)?;
// Within a host receipt transaction, reject mismatched bindings before merging.
reply_progress::merge_receipt(&tx, &q, &v, time)?;
```

- [x] Run `cargo test --locked --offline --test reply_progress --test core_state --test core_auth --test widget_push_store --test upgrade_guard`; expect no failures.
- [x] Commit `feat: persist independently bound reply progress`.

## Task 2: Structured native evidence

**Files:** Create `src/reply_evidence.rs`, `tests/reply_evidence.rs`; modify `src/lib.rs`.

**Interfaces:** Evidence observer takes request, native callback, answer, native JSONL and durable dispatch context; returns optional received/continued proof. Proofs contain stable source digests and native positions; no raw transcript is projected to devices.

- [x] Write failing tests using full session/turn/call fixtures: wrong answer, wrong session/turn/call, result before dispatch, duplicate output, continuation before reception, another turn, and Claude parent-chain mismatch.

```rust
assert!(observe(&wrong_call).received.is_none());
assert!(observe(&received_only).continued.is_none());
assert!(observe(&received_then_progress).continued.is_some());
```

- [x] Run `cargo test --locked --offline --test reply_evidence`; expect missing observer behavior.
- [x] Implement read-only native parsing with exact structured-answer comparison, dispatch boundary checks and original execution-chain continuation. Unsupported approval formats return no proof.
- [x] Run `cargo test --locked --offline --test reply_evidence --test adapters`; expect no failures.
- [x] Commit `feat: derive reply milestones from original native results`.

## Task 3: Host delivery, observation and recovery

**Files:** Modify `src/host.rs`, `tests/{recovery_round2,upgrade_guard}.rs`; add host progress integration tests to `tests/reply_progress.rs` or a dedicated process test.

**Interfaces:** Host negotiates `replyProgressVersion`, persists cumulative reconciliation receipts before sending, reconciles incomplete continuation without dispatch, and checks additive upgrade counts. Current native adapters retain source-unconfirmed observations rather than promote content matches into received/continued. Receipt files include stable stage/proof identity.

- [x] Add failing process tests for received-only pause, outbox reorder/retry, relay/host restart and no repeated native output.

```rust
assert_eq!(read_original_dispatch_count(), 1);
assert!(latest["replyProgress"]["received"].is_object());
assert!(latest["replyProgress"]["continued"].is_null());
```

- [x] Run new process tests; expect no received milestone on existing host.
- [x] Integrate observer into live Codex/Claude paths. Remove marker-only adoption, report native content matches as source-unconfirmed, and write recovery context before dispatch. Preserve independently supplied accepted proofs and read incomplete records on restart without restoring callbacks; current adapters do not fabricate attribution they cannot prove.
- [x] Run `cargo test --locked --offline --test recovery_round2 --test upgrade_guard --test reply_progress` and native host unit tests; expect no failures and unchanged dispatch count.
- [x] Commit `feat: reconcile native reply progress without redispatch`.

## Task 4: Shared client progress and durable journal

**Files:** Modify `ios/Shared/{Models,ReplySubmission,Storage,API}.swift`, `ios/App/PairingService.swift`, relevant pairing tests; create `ios/Tests/ReplyProgressTests.swift`.

**Interfaces:** Optional Codable progress fields; shared projection accepts a request plus optional local responseId. Journal binds immutable digest and connection/pairing generation with atomic file persistence. `ReplySubmission.send` validates exact returned identities before exposing success.

- [x] Add failing tests for mismatched HTTP receipt, received-only presentation, legacy adopted, other winner, corrupt progress, journal isolation, restart and unchanged-answer retry.

```swift
XCTAssertFalse(request.replyStatus(for: "other-response").received)
XCTAssertFalse(receivedOnly.replyStatus(for: "original-response").continued)
```

- [x] Run focused iOS unit tests; expect missing model/validation failures.
- [x] Implement optional fields, fail-closed progress validation, atomic fsync journal with ownership context, migration of legacy records to history, capability-aware transport and exact receipt verification. Never auto retry a POST.
- [x] Run the iOS unit suite; expect no failures, with configured-only integration skips separately recorded.
- [x] Commit `feat: validate reply receipts and persist scoped original answers`.

## Task 5: App and Widget presentation

**Files:** Modify `ios/App/AgentInboxApp.swift`, `ios/Widget/InboxWidget.swift`; extend iOS UI and progress tests.

**Interfaces:** Both surfaces consume the same progress projection; active/history selection accounts for received-but-awaiting-continuation without blocking the next pending request.

- [x] Add failing UI/shared-selection tests for three separate steps, local-only journal, legacy adoption, unknown continuation and old/wrong response binding.
- [x] Run focused tests; expect old lifecycle-only labels or selection failure.
- [x] Show independent stage rows/reasons, preserve saved original answer, make recovery check read-only, retain awaiting continuation in App, and keep Widget next-pending preference. Cached state cannot infer a new proof.
- [x] Run unit/UI tests and unsigned simulator Debug/Release builds; expect no failures. Keep physical installation and live acceptance separately marked.
- [x] Commit `feat: show independently verified reply milestones`.

## Task 6: Whole-chain verification and documentation

**Files:** Modify `docs/{PROTOCOL,STATUS,NEXT-REQUIREMENTS}.md`; create `docs/REPLY-RELIABILITY.md`; extend process/concurrency tests where coverage is missing.

- [x] Add any missing failing regression for the 17 spec scenarios before its fix, including claimed-vs-local boundaries, same-answer provenance ambiguity, legacy SQL table writes and capability failure. Explicit previous-binary rollback remains a configured-only drill, recorded as unverified when skipped.
- [x] Run `cargo test --locked --offline`, the iOS unit/UI suites, Debug/Release builds, and formatting/diff checks. Record exact pass/skip/failure counts and actual source scope.
- [x] Review the entire branch against the spec, emphasizing proof provenance, immutable request fingerprints, no replay, terminal progress, legacy binaries and cross-process journal operations. Fix actionable issues with regression tests.
- [x] Update protocol and acceptance records with measured local results and explicit unverified physical/production cases; do not relabel simulated runs as real-engine or iPhone success.
- [x] Commit `docs: record reply reliability protocol and verification` and report code, tests and remaining live acceptance.

## Review Focus

Inspect same-answer local/phone attribution, error and cancelled turns, native record duplication/truncation, digest canonicalization, proof owner/conflict rules, cumulative proofs arriving after terminal states, fsync crash windows, old relay capability negotiation, pairing/middle-of-flight changes, Widget generation races, and old binaries writing a new database. Tests prove controlled fixtures; they do not prove every future native engine transcript format or physical device behavior.

## Execution rulings and remaining acceptance

- Current native protocols do not provide a winning-client identifier sufficient to eliminate equal-answer local/phone ambiguity. Shipped adapters report source-unconfirmed observations; the protocol fixture's positive received/continued proves relay/client behavior only. See the implementation ledger and docs/REPLY-RELIABILITY.md.
- Local scope and exclusion fixtures now return actual versioned capabilities and complete progress recovery responses. Unsupported or malformed production responses still fail closed.
- All checked steps refer to local code and test work. Physical iPhone, actual native attribution, production rollout and two explicit previous-binary drills remain unverified and are not counted as feature acceptance.
- Publication cleanup appeared concurrently. Its unrelated docs, dist deletions, fixture anonymization and signing changes remain outside this feature's commits.
