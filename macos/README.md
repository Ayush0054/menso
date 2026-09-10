# Menso for macOS

This directory contains Menso's native macOS 14+ client. It is Apple Silicon-first and uses AppKit for window/process integration, SwiftUI for composition, GRDB 7 for local durable state, and Sparkle 2.9.4 for signed out-of-App-Store updates.

## Implemented client slice

- Shell: an `LSUIElement` app with one fixed 320×520 transparent, nonactivating `NSPanel`, precise transparent-region hit testing, a 4 pt drag threshold, edge snap/peek, per-display position persistence, and a menu-bar recovery affordance.
- Presentation: native robot sprite states, a pure-SwiftUI expanded/collapsed morph, Apps/Agents/Actions tabs, approval bubbles beside the collapsed robot, and Control–Option–Return / Control–Option–Escape global approval hotkeys. The Carbon hotkeys do not require Input Monitoring.
- App monitoring: `NSWorkspace` lifecycle/activation observation, same-user `libproc` CPU and physical-footprint sampling, responsible-process grouping, optional frontmost Accessibility title lookup, idle timing, and screen sleep/wake handling.
- Agent metering: bounded incremental JSONL reads with persisted inode/offset cursors, defensive Claude Code and Codex parsers, delta-only Codex token accounting, process liveness, local quota projections, and oversized-fragment progress guarantees.
- File discovery: root-level FSEvents coalesces telemetry changes into immediate refreshes; per-file kqueue/`DispatchSource` watchers trigger sub-second reads and retire descriptors on rename, delete, or revoke; bounded timer polling remains the reconciliation path and discovers roots created after launch.
- Durable safety state: action audit transitions, pre-side-effect idempotency reservations, terminal execution results, trusted run authority, pending reviews, and endpoint-specific continuation envelopes are persisted in GRDB. The volatile fallback is only for non-authoritative monitor/window settings; desktop action execution must use the SQLite stores and fail closed.
- Trusted runtime: authenticated AgentOS identity verification, typed SSE pause ingestion, durable run authority, endpoint-specific continuation outbox, permission health, and the pinned embedded CUA host are composed from the app only after durable storage and configuration gates succeed.
- Audio: dictation capture/conversion, hotkey, HUD, insertion boundaries, native WebRTC Realtime transport, bounded reconnect continuity, and speaker/headphone AEC policy are implemented. Dictation remains disabled without a reviewed transcriber/model, and live voice remains disabled until its complete authenticated delegation composition is available.

The app never reads Claude credentials or calls subscription OAuth usage endpoints. Claude quota is explicitly a local estimate. Codex rate-limit observations come from Codex's local rollout events.

## Updates

`Package.swift` pins the official `Sparkle` product to exactly 2.9.4. That patch release includes an activation fix for backgrounded/dockless apps, which matters for this `LSUIElement` process.

`AppUpdaterController` creates `SPUStandardUpdaterController` programmatically and the status menu exposes **Check for Updates…**. Sparkle starts only when the packaged bundle contains all of the following:

- an HTTPS `SUFeedURL` with no embedded credentials;
- a base64 Ed25519 `SUPublicEDKey` that decodes to 32 bytes;
- `SURequireSignedFeed = true`;
- `SUVerifyUpdateBeforeExtraction = true`;
- `SUSignedFeedFailureExpirationInterval = 0`, so a bad feed signature never expires into a weaker fallback.

The checked-in plist contains placeholders. Development executable launches therefore keep updates disabled instead of contacting a placeholder endpoint. Release packaging replaces the placeholders before signing; it never stores the private Ed25519 key in the app.

## Release lane

The manually dispatched `.github/workflows/release-macos.yml` performs this sequence on a macOS runner:

1. Fetch and hash-check the pinned CUA Driver archive, resolve immutable package revisions, and create an arm64 release executable while no release secret is present.
2. Require and decode release credentials into runner-temporary files.
3. Import the Developer ID Application certificate into an ephemeral keychain.
4. Assemble `Menso.app`, preserving the Sparkle and WebRTC frameworks' symlinks and executable modes, and place the pinned CUA executable in `Contents/Helpers` with its reviewed manifest and bounded policy in Resources.
5. Embed the real feed URL, public Ed25519 key, semantic version, and monotonically increasing build number.
6. Sign Sparkle's nested helpers, WebRTC, and the embedded CUA executable inside-out, then sign Menso with hardened runtime and `Menso.entitlements`. The scripts intentionally do not use `codesign --deep`.
7. Submit an app archive to `notarytool` and staple the accepted ticket to `Menso.app`.
8. Create an APFS/LZFSE DMG containing Menso and an `/Applications` symlink, Developer ID-sign it, notarize it, and staple it.
9. Run the pinned Sparkle `generate_appcast` with `--ed-key-file` and the HTTPS download prefix. Because the embedded app requires a signed feed, Sparkle signs the archive and appcast and fails if the key does not match.
10. Upload the DMG, signed `appcast.xml`, and any generated deltas as a workflow artifact. Publishing those files to the configured HTTPS host is deliberately a separate hosting adapter.

The workflow is `workflow_dispatch` only and protected by the `macos-release` environment. It needs these secrets:

| Name | Required value |
| --- | --- |
| `MENSO_DEVELOPER_ID_APPLICATION` | Full Developer ID Application identity name |
| `MENSO_DEVELOPER_ID_P12_BASE64` | Base64-wrapped exported signing identity and certificate |
| `MENSO_DEVELOPER_ID_P12_PASSWORD` | Password for that PKCS#12 export |
| `MENSO_NOTARY_KEY_ID` | App Store Connect API key ID |
| `MENSO_NOTARY_ISSUER_ID` | App Store Connect API issuer UUID |
| `MENSO_NOTARY_KEY_BASE64` | Base64-wrapped `.p8` notarization API key |
| `MENSO_SPARKLE_PUBLIC_ED_KEY` | Base64 32-byte public key printed by Sparkle `generate_keys` |
| `MENSO_SPARKLE_PRIVATE_ED_KEY_BASE64` | Base64 wrapper around the exported Sparkle private-key file |

The dispatch inputs provide `version` (`X.Y.Z`), numeric `build`, `feed_url`, and `download_url_prefix`. All URLs must use HTTPS. Missing identities, keys, tools, real icon artwork, versions, or trust flags terminate the release before an artifact is emitted.

For a local authorized release, first build the executable and resolve Sparkle, then use:

```text
scripts/package-app.sh /absolute/path/to/MensoApp /absolute/path/to/Sparkle.framework /absolute/path/to/WebRTC.framework /absolute/archive-directory
scripts/release-macos.sh /absolute/archive-directory/Menso.app /absolute/release-directory
```

`release-macos.sh` requires the corresponding `MENSO_*` environment variables documented directly in the script. Never commit exported `.p12`, `.p8`, or Sparkle private keys. `Resources/appcast.xml.template` is only a generator seed; do not publish it or manually edit an appcast after `generate_appcast` signs it.

## Bundle and privacy

`Resources/Info.plist` is the bundle template, `Menso.entitlements` is the hardened-runtime entitlement set, and `Resources/PrivacyCopy.json` contains onboarding copy. Accessibility has no Info.plist usage-description prompt. The current semantic CUA path is AX-only and never requests screenshots, so Screen Recording is not required. The panel composes explicit Accessibility, microphone, and Speech Recognition permission health; moving the app to `/Applications` remains a prerequisite for trusted-runtime enablement.

The status item uses an SF Symbol while original robot artwork is pending. A release must replace `Resources/AppIcon.icns.placeholder` with an original `Resources/AppIcon.icns` containing 16, 32, 128, 256, 512, and 1024 px representations; the packaging script fails if it is absent.

For local SwiftPM debug runs, `backend/scripts/generate_local_auth.sh` creates an ignored JWT and expiry under `backend/.local-auth/`. When no connection has previously been stored, the debug app reads that token in memory, fixes the endpoint to `http://127.0.0.1:8000`, and verifies it with AgentOS. This avoids requiring Data Protection Keychain access from an unsigned debug executable and is excluded from release builds; signed release builds remain Keychain-only.

## Remaining external release inputs

- Developer ID membership, certificate, Team identity, and protected `macos-release` environment.
- App Store Connect notarization API credentials.
- One retained Sparkle Ed25519 keypair and an HTTPS host for the appcast, DMGs, deltas, and release notes.
- Original licensed app icon artwork.
- Signed-device compatibility exercises for the generic CUA operations and the on-device Apple Speech dictation adapter.
- A publication adapter for the chosen HTTPS host, historical archives if delta generation is desired, and an older signed/notarized build for an end-to-end update rehearsal.

No local build, test, lint, package-resolution, signing, notarization, workflow, or runtime check was run while implementing this slice, per repository instruction.
