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


## Execution evidence

- RED: `api-red.log` and `store-red.log` confirmed missing implementation; `store-and-ui-red.log` confirmed missing association UI.
- Review-driven RED: `rotation-red.log` reproduced 16 vs 20 retained states; `invalidation-red.log` reproduced a GET after token invalidation. Both repaired and included in final suite; read-only independent re-review found no residual P1/P2.
- Final full unit run in fresh `/private/tmp/AgentInboxAPIAudit`: 107 executed, 101 passed, 6 environment-gated skips, zero failures. `audit-unit.log`. Fresh run also executes the rename/address-update regression omitted by the earlier stale incremental runner.
- Core UI 7 passed with complete process exit: `final-regression.log`. Final screenshots exported and visually checked. Earlier compatibility failures were an inherited accessibility identifier and an offscreen row; fixed and revalidated.
- Debug signed and Release device architecture builds passed. Strict signatures, profiles, App-only OAuth Keychain group versus Widget, original shared pairing and development APNs checked. API build installed over the existing iPhone app and launched successfully. No Apple identity or OAuth credential was created by this implementation.
- A public invalid-credential HTTPS request to the fixed token endpoint returned 401; this is a negative-path observation only.
- Physical real OAuth client/list evidence now passed with the user's credential entered only on the phone. After correcting Client ID mistakenly entered as Tailnet ID, the directory loaded; formal source build installed, manual refresh and cold restart passed with the same 6 stable device IDs and a newer API cache timestamp. Existing app pairing remained available. See `physical-proof.json`, `physical-final-refresh-v2.log`, `physical-final-relaunch-test.log` in ignored `evidence/tailscale-api/`. Daemon/application-auth and VPN/network recovery remain pending.
- Device-endpoint 404 now explains Tailnet ID vs Client ID without echoing error bodies. RED reproduced the missing guidance; GREEN ran 16 API/store tests successfully. Token-endpoint 404 remains distinguished from a missing tailnet. Temporary diagnostic app was replaced by the formal source build.

- Final coverage also verifies a successful Tailnet switch discards an older in-flight API response in both memory and disk. Final unit count is 107 (101 pass / 6 gated skips); no tests are pending execution outside the explicitly gated physical scenarios.

## 2026-10-22 completion audit and remaining physical gates

- [x] Confirm actual API directory restoration/refresh and retained pairing on iPhone; current cache still has the same 6 stable IDs with a newer timestamp.
- [x] Verify list-only DNS/IP and detail DNS, authenticated relay selection success and failure preservation.
- [x] Verify manual VPN disconnection guidance and connected return with actual relay authentication. Bare `tailscale://` was rejected after its signing error was observed; the verified supported handoff uses the official App Store page, then the user's Open/Install action. Direct automatic app launch remains unsupported.
- [x] Verify a real iPhone reaches the current native discovery module on this Mac's existing Tailnet address. Saved-relay authentication succeeds, while the deliberately unregistered fixture host remains awaiting heartbeat; existing app pairing is retained. This is a native-component integration check, not a deployed-host positive authorization claim. Temporary listener stopped and no 8788 listener remains.
- [x] Run current native full suite (95 pass / 2 gated ignores), native arm64 Release build, and current iOS Release device build. Actual signed App/Widget entitlements isolate OAuth private group from Widget.
- [x] Verify an existing installed host's discovery → saved relay authentication → registered heartbeat positive path; restore original host and configuration afterward.
- [x] Verify actual Wi-Fi → cellular → Wi-Fi transitions with catalog timestamps, stable IDs and relay authentication on each path.
- [ ] Verify actual device rename/address update, retaining stable identity; fixture mapping tests already pass but are not physical evidence.

### Historical pre-approval installed-host preflight (execution below)

Read-only preflight found Mac mini LaunchAgent `dev.matianyi.agentinbox.host`, PID 49423, with `activeHooks=0`, `activeRequests=0`, `submitting=0`, `startupReconciled=true`, `draining=false`. Recheck immediately before any mutation.

Current executable is `/Users/developer/Library/Application Support/AgentInbox/releases/0.1.0-upgrade-guard/agentinbox` (SHA256 `553f2131319e84bf85eae34dc2e514aae57c170fcb06e3fc33851f2d2f950a1f`). Current ProgramArguments are that executable, `host`, and `/Users/developer/Library/Application Support/AgentInbox/host.json`; no discovery listener is enabled.

Prepared local current-source artifact: `target/release/agentinbox`, arm64 Mach-O, SHA256 `a1d6f398c6a2b35de4db7f74913b517fcf40e7f1cbb66f100bde98fd661ca368`. Build source revision is `1f4b03e`; no native product source changed during this audit. Existing host requires this newer native discovery implementation, so merely appending flags to the old installed binary is insufficient.

After user approval for changing the running remote host, copy to a distinct release directory, preserve the original plist and binary, drain and recheck all activity counters at zero, then temporarily use the new binary with the existing config plus `--discovery-listen 100.64.0.13:8788 --discovery-relay-url https://relay.example.ts.net:8443`. Do not modify scopes, token files, daemon/Herdr, relay or ACL. Verify real phone discovery and the original registered host heartbeat. Restore the original executable/arguments and pre-test drain state; verify the service reconciles and 8788 closes. No deployment or restart has occurred in this preflight.

Evidence: ignored `evidence/tailscale-api/native-discovery-physical-v2.log`, `goal-native-regression.log`, `goal-native-release-build.log`, `goal-ios-release-build.log`. The initial native-discovery UI assertion used a standalone StaticText query for a combined LabeledContent; it failed without proving a transport failure. The corrected grouping query passed. Subsequent installed-host and network evidence is recorded below. After those checks the user explicitly accepted the goal as complete; unchecked physical scenarios remain unverified rather than being counted as passed.

### Authorized installed-host acceptance and restoration (2026-10-22)

The user approved this one temporary Mac mini upgrade with restoration, and Wi-Fi/cellular transitions only; real rename/address change remains unverified this round. Rechecked all three activity counts at zero, preserved the complete original LaunchAgent and configuration hashes, verified the exact prepared binary hash, then used `prepare-upgrade` to prove no blockers before switching to the separate temporary release. The temporary host stayed drained; discovery listened only on `100.64.0.13:8788`.

The real iPhone on user-confirmed Wi-Fi reached the installed Mac mini descriptor, authenticated the existing saved relay with the original pairing, displayed “已配对，应用认证通过”, and showed the registered `mac-mini` host online. Corrected test passed 1/1; the first attempt had already passed discovery/auth but queried a combined cell label for the separate online field. Descendant lookup passed without product changes. A recent online heartbeat is defined by the relay as less than 30 seconds old.

Restoration completed before the network-transition tests: original binary, byte-identical LaunchAgent and config, original non-draining state, reconciled startup and three zero activity counts all verified. Port 8788 is closed; the temporary release and staged binary were removed. No scope, pairing, token, daemon, Herdr or Tailscale configuration changed. This is temporary acceptance evidence, not permanent rollout of discovery to the existing host. Evidence is ignored `installed-host-wifi-physical-v2.log`, `installed-host-restoration.log` and `installed-host-proof.json` under `evidence/tailscale-api/`.

### Network-transition acceptance passed (2026-10-22)

The user confirmed Wi-Fi plus Tailscale Connected for baseline, then explicitly switched Wi-Fi off in Settings and confirmed cellular data plus Tailscale Connected. On cellular, the formal app returned without a disconnected prompt, refreshed the real API directory, and successfully authenticated the original `relay-host` relay; physical test passed 1/1. Both API snapshots contained the same 6 stable IDs (SHA256 `c67aa11dccf979c7ea6cc7e5adb8622579f021539b31db2a6637041be801f4ac`), with importedAt advancing from `814325640.532463` to `814325854.103234`. Transport is established by the user's confirmation, not inferred from API success. The user then confirmed reconnection to Wi-Fi with Tailscale Connected. The return test passed 1/1: no disconnected prompt, manual API refresh and original relay authentication succeeded; importedAt advanced again to `814326589.287426`, with the same 6 stable IDs. The phone finished on the Inbox. This verifies foreground return plus explicit refresh across the network transitions, not unattended background recovery or a timed assertion of automatic path-change refresh. Real device rename/address update remains unverified by user choice. Evidence: ignored `network-cellular-physical.log`, `network-wifi-return-physical.log`, `network-switch-proof.jsonl` and `network-switch-proof.json`.
