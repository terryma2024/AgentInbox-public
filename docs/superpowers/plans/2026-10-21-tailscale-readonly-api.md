# Tailscale Read-only API Implementation Plan

> 2026-10-21：实机确认 Screens 首次关联为 Tailnet ID＋客户端密钥表单，用户明确选择按现有方案继续，亲自在手机填写凭据做真机验证。本计划恢复为当前方案；先前网页授权探索见 [核查记录](../../TAILSCALE-WEB-AUTH-INVESTIGATION.md)。

> **For agentic workers:** Use executing-plans inline for the user-authorized local implementation. No delegation is required.

**Goal:** Link a tailnet like Screens using a private read-only OAuth credential, automatically list devices, and connect through iPhone Tailscale VPN without an extra node or Shortcuts.

**Architecture:** An actor owns fixed-origin OAuth/API traffic and in-memory tokens. A private Keychain repository stores the association. TailnetStore coordinates list synchronization and existing daemon/auth probes; SwiftUI renders association and device state.

**Tech Stack:** Swift 5, SwiftUI, URLSession, Security, XCTest, XcodeGen, iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-21-tailscale-readonly-api-design.md`

## Global Constraints

- iOS 17 baseline; no embedded TailscaleKit, new node, auth keys, tags or device-write calls.
- `devices:core:read` only; fixed HTTPS api.tailscale.com, no redirects, cookies, secret logs or credential sharing with daemon/relay/Widget.
- Preserve existing application pairing and response journal.
- User approved the architecture and requested implementation; continue in the existing local branch.

## Task 1: API and credentials

Files: create `ios/App/TailnetAPI.swift`, `ios/App/TailnetAPICredentials.swift`, `ios/Tests/TailnetAPITests.swift`.

- [x] Write contract tests: rejected malicious tailnet IDs; token form requests only `devices:core:read`; cached token yields two GETs but one exchange; expired/401 token renews once; 403/429 preserve safe errors; device nodeId/name/os/version survive mapping; invalid addresses and oversized payload fail closed.
- [x] Run `xcodebuild test` selecting TailnetAPITests on the existing simulator and capture the missing-feature RED result.
- [x] Implement `TailnetAPICredentials(tailnetID:clientSecret:)`, private Keychain `load/save/clear`, `TailnetAPI.devices(credentials:) async throws -> [TailnetAPIDevice]`, and token invalidation using bounded URLSession bytes.
- [x] Run the same tests GREEN; verify only fixed HTTPS token POST/device GET can carry credentials.

## Task 2: Store synchronization

Files: modify `ios/App/TailnetStore.swift`, `ios/App/TailnetImport.swift`, `ios/App/TailnetDiscovery.swift`; create `ios/Tests/TailnetAPIStoreTests.swift`.

- [x] Write RED tests for successful association and metadata, failed candidate association preserving old data, persisted association reload, read-only failure retaining cache, unlink/switch winning over late responses, app credential never overwritten.
- [x] Add optional API metadata to snapshot Codable for compatible private cache; keep missing fields unknown.
- [x] Add `linkAPI(tailnetID:clientSecret:) async`, `unlinkAPI() async throws` and API-first refresh/foreground restore. Commit association only after validating remote data, guard generations, preserve existing pairing calls and saved-origin restriction.
- [x] Run store tests plus existing Tailnet import/discovery tests; fix regressions without broad refactors.

## Task 3: Product interface, docs and validation

Files: create `ios/App/TailnetLinkView.swift`, modify `ios/App/AgentInboxApp.swift`, `ios/App/TailnetMachineView.swift`, `ios/UITests/InboxUITests.swift`, project config and current requirement/status docs.

- [x] Add UI test for link sheet, malformed input, cancellation preserving settings; adapt existing tab/import tests to the secondary compatibility path.
- [x] Implement private SecureField association form and Tailscale section with count, timestamps, refresh, unlink confirmation, official console/status links; show API vs historic import source accurately.
- [x] Regenerate project, run the complete iOS unit suite and all 7 InboxUITests, inspect rendered screenshots. Build signed device Debug and SDK-free Release, verify strict signing and required entitlements, install over current iPhone app.
- [x] Update NEXT-REQUIREMENTS, FEATURE1, STATUS, IOS, README and shortcut compatibility note; record physical limitations separately.
- [x] Review final diff and test evidence, commit only relevant changes.
- [x] Use user's own private read-only credential on the phone; verify real device list, manual refresh, cold app restart and retained app pairing. Never request the secret in chat.
- [ ] Complete all remaining real-phone gates. Installed host/application authentication and Wi-Fi/cellular transitions have passed; real device rename/address update below remains unverified.


## Sanitized verification summary

The API, credential store, synchronization and interface tasks passed their regression suites. The final iOS unit run executed 107 tests with 6 environment-gated skips and zero failures; core App UI checks passed 7 tests. Signed Debug and Release device builds passed, including separate App-only OAuth storage and preserved shared pairing.

Physical verification covered credential entry on the phone, listing and refreshing devices, cold restart, and retained application pairing. An authorized temporary discovery deployment verified saved-relay authentication and registered-host heartbeat, then restored the original executable and configuration. Foreground return, explicit refresh and relay authentication passed across user-confirmed Wi-Fi, cellular and Wi-Fi return.

Manual VPN guidance and the official App Store handoff were verified. Direct automatic Tailscale launch remains unsupported. Actual device rename/address changes, unattended background recovery and automatic path-change refresh timing remain unverified.

Installation metadata, build fingerprints, device identifiers, timestamps, process details and raw test records are retained only in ignored local evidence. This public summary records behavior and verification boundaries without identifying a real installation.
