# Self-check Diagnostics Implementation Plan

> **For agentic workers:** Execute inline with superpowers:executing-plans and test-driven-development. Review the whole change after verification.

**Goal:** Locate failed inbox and reply stages and share only explicitly allowed diagnostic facts.

**Architecture:** Extend authenticated host heartbeats with bounded observations and store per-device diagnostic jobs. Reuse existing native callback collection and reply proof verification for isolated Codex test calls. Keep the public export model independent of operational payloads.

**Tech Stack:** Rust, SQLite, tiny_http, existing Codex WebSocket client, SwiftUI and XCTest; no additional host language runtime.

**Spec:** `docs/superpowers/specs/2026-10-23-self-check-diagnostics-design.md`

## Global Constraints

- Preserve existing pairing, product identities, normal capture scopes and reply proof semantics.
- A heartbeat is not capture proof; notification delivery is not original-call reception.
- Only a native received proof for the same test answer confirms the reply loop.
- Public files contain artificial fixtures only; local evidence remains ignored.
- Export uses fixed enums and numeric facts; no operational identifiers, endpoints or arbitrary strings.

### Task 1: Authenticated observations and diagnostic jobs

**Files:** Create `src/diagnostics.rs`, `tests/diagnostics.rs`; modify `src/lib.rs`, `src/store.rs`, `src/relay.rs`.

**Interfaces:** `Store::diagnostic_snapshot(device, time)`, `start_diagnostic(device, body, time)`, `claim_diagnostic(host, time)`, `update_diagnostic(host, body, time)`, `diagnostic_test(device, id, time)` return `ApiResult<Value>`; `diagnostic_heartbeat(host, body, time)` accepts only bounded observations.

- [x] Write store tests for stale/missing observations, ownership, idempotent creation, expiration and one-time claims. Example: `assert_eq!(store.claim_diagnostic("fixture-host", 101).unwrap()["test"]["testId"], "fixture-test"); assert!(store.claim_diagnostic("fixture-host", 102).unwrap()["test"].is_null());`.
- [x] Run `cargo test --test diagnostics`; observe missing production interface failures.
- [x] Implement additive tables and role-checked HTTP routes. Sanitize every accepted status field and derive test results from actual request progress and push outbox.
- [x] Run `cargo test --test diagnostics --test core_auth --test core_state --test reply_progress` and require all tests to pass.

### Task 2: Host observations and isolated native probe

**Files:** Create `src/diagnostic_native.rs`; modify `src/host.rs`; extend `tests/diagnostics.rs` and HTTP integration tests.

**Interfaces:** A bounded loopback fixed provider supplies thread-local model configuration; host creates a new thread, binds test to the captured native callback and leaves ordinary scope rules intact. Heartbeat reports initialization, last successful scan, draining, reconciliation and hook event observation.

- [x] Write tests proving provider output contains only fixed tool/message events, expires, and never sends received facts itself. Test unsupported adapters and jobs that cannot restart after claim.
- [x] Run the tests and confirm failure before implementing.
- [x] Start native test thread using thread-specific provider config, read-only sandbox and private cwd. Add only the returned owned thread to the attached set. Publish its fixed callback through the normal host and let existing native proof code establish reception.
- [x] Run Rust tests and an isolated native-process integration when the optional patched engine exists. Stop the provider and archive the test thread at completion or deadline; errors never terminate the normal host loop.

### Task 3: App self-check, reply UI and safe sharing

**Files:** Create `ios/Shared/Diagnostics.swift`, `ios/App/DiagnosticsView.swift`, `ios/Tests/DiagnosticsTests.swift`; modify `ios/Shared/API.swift`, `ios/App/AgentInboxApp.swift`, project file and UI tests.

**Interfaces:** A diagnostic service fetches observations and tests through `InboxAPI`. A separately encoded share report contains fixed stage/reason enums and numeric facts only. The view snapshots relay connection and discards changed-connection results.

- [x] Add tests that inject private-looking endpoint/body/ID/error fields and assert they never occur in the export; assert APNs acceptance alone leaves original reception unconfirmed.
- [x] Run the focused XCTest suite and observe the missing model failures.
- [x] Implement classification, fixed localized advice, one-click checks, per-host test start, fixed-choice submission and independent notification observation. Share only the whitelist report through ShareLink.
- [x] Run focused and complete unit tests, compile App/Widget and exercise the diagnostic UI on an isolated fixture server.

### Task 4: Verification, documentation and review

**Files:** Update `docs/NEXT-REQUIREMENTS.md`, `docs/PROTOCOL.md`; create `docs/SELF-CHECK-DIAGNOSTICS.md`.

- [x] Run `cargo fmt --check`, `cargo test` and iOS tests/build; inspect outcomes and explicit skips.
- [x] Document exact supported tests, fault categories, export schema and unverified physical delivery boundaries.
- [x] Inspect final diff and candidate publication bytes for sensitive data; verify ignored sensitive paths remain absent from the index.
- [x] Request one independent review of the whole feature and fix material findings with regression tests.
- [x] Leave a concrete reviewable result; do not mark physical/device deployment complete without corresponding evidence.
