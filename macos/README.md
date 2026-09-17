# Menso for macOS

Menso is a regular macOS 14+ desktop app with a Dock icon, one resizable window, native menus, and Settings. AppKit owns the window; SwiftUI shows a voice conversation, approve-once/decline decisions, and visible results. There is no action preparation sheet.

## Current client

- OpenAI `gpt-live-1` over native WebRTC with microphone input and speaker output.
- SDP negotiation through the authenticated Menso backend; the provider key stays server-side.
- Live transcript deltas, client delegation through TypeSafe candidate selection, bounded continuity and reconnects.
- Four typed Mac actions requested by voice: open/switch app, focus a known window, insert text, set a focused control. Installed apps and focused Accessibility targets are resolved locally for each request.
- Local approval, target/content binding, receipt verification, and SQLite audit. No AgentOS continuation in the active action path.
- Settings for a server URL and product credentials. Secrets stay in device Keychain. Restart after changing credentials.
- The microphone is off until you start a conversation. Ending it or closing the window stops voice. Accessibility is requested only for Mac actions.

The floating widget, monitoring, token dashboards, Claude hooks, dictation, learning UI, global hotkeys, and updater UI were removed. Old database tables remain for compatibility and no existing user records were purged.

## Running after authorization

Configure the backend with GPT-Live access, a server-only `TYPESAFE_API_KEY`, and product JWT scope `live:connect` (also authorizes the action selector). Existing `realtime:connect` tokens need reissuing. Debug builds can use the ignored `backend/.local-auth` token; release builds use Settings. No manual action preparation is needed. Text insertion supports literal dictated text, not generated drafts.

The app must be packaged and installed in Applications for signed-app permissions and the embedded driver boundary. Command-line binary launches are not substitutes for TCC validation.

For a local Apple Silicon debug build, from the repository root:

```sh
swift build --package-path macos --arch arm64
zsh macos/scripts/package-debug-app.sh
open macos/.build/local-app
```

Quit the existing Menso app, then move the freshly packaged app into Applications and launch that copy. The packaging script asks SwiftPM for its current output directory; do not manually copy from a cached architecture directory. Rebuilding an ad-hoc signed app can require renewed macOS permissions.

Earlier desktop/GPT-Live checks predate this migration. The TypeSafe path has not been built, installed, or tested. Pending native reviews expire after three minutes and are not restored after quitting; ask again after restart. Terminal results and execution reservations remain in SQLite. See [validation scope](../docs/IMPLEMENTATION_STATUS.md).

## Release infrastructure

The existing signing/notarization scripts and pinned Sparkle packaging dependencies remain as release infrastructure; this reduced app does not start a Sparkle updater. Release work and public hosting are separate authorized steps.

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

## Remaining release inputs

The release requires original AppIcon.icns artwork, Apple signing/notarization credentials, the pinned embedded CUA executable, and the external hosting credentials referenced by the release scripts. The scripts have not been exercised for this simplification.

The bundle requests microphone access for live voice and Accessibility for approved Mac actions. No dictation, screen-capture, monitoring, or hook feature starts.
