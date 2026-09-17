# Menso implementation status

This document separates implemented source from the local checks actually completed.

## Current scope

| Area | Source implementation |
| --- | --- |
| Desktop app | Regular Dock app, one resizable AppKit window, native SwiftUI content, standard menu and Settings |
| Voice | GPT-Live `gpt-live-1`, authenticated server SDP exchange, native WebRTC, transcript deltas, client delegation, reconnects and explicit close |
| Task backend | TypeSafe Choice selects one native candidate; AgentOS retained for verified JWT/HTTP/database hosting, no registered Agent |
| Mac actions | Voice-proposed open/switch app, focus window, insert text, set control; native target matching and mandatory local approval |
| Approval | Approve once or decline; exact action binding, expiry, durable audit, receipt verification |
| Results | In-window result status, saved voice-result delivery, concise verified voice result |
| Connection | Server URL and product credentials in Settings; device Keychain; restart after changes |

## Removed

Floating widget/robot, screen-edge modes, app/process monitoring, coding-agent token dashboards, Claude hooks, dictation/HUD/hotkeys, learning management and LearningMachine, improvement/deployment/eval workflows, schedules, and the public MCP server.

The release scripts still contain signing/notarization and Sparkle packaging infrastructure. There is no updater UI or running updater in this reduced app. Historical SQLite tables and action wire variants remain readable; no user data has been deleted.

## Local validation — September 18, 2026

With explicit user authorization:

- `swift build --package-path macos --arch arm64` passed.
- The debug bundle was assembled, ad-hoc signed, installed in `/Applications`, and passed `codesign --verify --deep --strict`.
- The new desktop window, conversation captions, action preparation sheet, and connection settings were inspected in the running app.
- Backend health and verified local JWT context succeeded. Required voice scopes were present.
- The backend created a real GPT-Live session (HTTP 201); the Mac reached `Conversation live`, and both user and assistant transcript events arrived. Ending the session returned the UI to microphone-off state.
- Backend Ruff and mypy passed (17 Python source files); `git diff --check` passed.

Fixes found during this run: a deleted-agent import, an eager database import cycle, a hard-coded packaging path that selected an August executable, an empty SwiftUI Settings startup window, and continuous ICE gathering incompatible with the single SDP exchange. A private salt was added only to ignored local configuration with approval; the API container was recreated without modifying the database.

## Still unverified

### TypeSafe migration — latest source only

The active desktop path is now GPT-Live → native candidate catalog → authenticated `/menso/actions/select` → TypeSafe Choice → native approve-once card → local executor/verification → GPT-Live result. The generative Menso agent is unregistered. AgentOS remains for HTTP/JWT/database hosting, and legacy source/data are retained without starting continuation workers.

New sources cover known-ID-only selection, identity/scope checks, exact literal-text candidates, low-confidence abstention, native review expiry, duplicate-call suppression, and completed results backed by local receipts. A new `native_voice` policy source does not weaken legacy Agent/Workflow binding requirements. Current-user transcript extraction excludes assistant speech and saved history.

`TYPESAFE_API_KEY` must be configured server-side. No private environment files, containers, installed app bundles, database data, or credentials were changed. Offline regression tests were authored but not run. No builds, tests, linters, formatters, validation scripts, or live calls were performed for this migration. Earlier checks below/above do not validate this revision.

Limitations: one semantic action per request; no generated drafts, screen reading, arbitrary clicks, or multi-step planning. The confidence threshold requires future evaluation. Pending native reviews are memory-only, expire after three minutes, and are not recovered after quitting. Existing action receipts/reservations remain durable. End-to-end approval/execution, transcript interleaving, expiry/cancellation, fresh packaging, and TypeSafe account/model access require an explicitly authorized check.

### Earlier voice-first actions — superseded action-selection path

Removed the manual preparation form and its capture/countdown state. A request-scoped native provider supplies app names/IDs from running apps and standard application folders plus the focused Accessibility target (no screenshots or field values). The first supported proposal is matched locally and its exact operation/tool-call ID is frozen before mandatory approval. Additional actions and mismatched targets fail closed. Receipt checks use that resolved local binding. The window comes forward when a live request needs review; Accessibility setup is available directly in the footer.

The flow remains limited to one of the four existing semantic actions per request. Arbitrary screen reading, browser navigation/submission, and multi-step autonomous control are not implemented. Registry/context regression tests have been added but not run. No build, install, live action, or runtime validation was performed for this voice-first change.

### Follow-up action failures — source changes only

The supplied screenshots show working live conversation but failed task delegation. A standalone backend task returned a structured `RunCompleted` result, so that does not establish that the Mac action/approval path works. One earlier backend request logged a provider 404; a separate minimal model request succeeded. The full cause of the photographed failures has not been confirmed.

Follow-up changes replace the generic safety error with fixed messages for authentication, network, missing/mismatched authority, malformed responses, and unverified results. The SSE transport now preserves byte-level event boundaries, bounds event size, and rejects incomplete results. The prepared-action label names the exact operation, and both the UI and voice instructions explain that screen/app contents are not shared. No local authority or approval requirement was relaxed.

Regression tests were added for stream framing and safe error messages but **have not been run**. These follow-up changes have not been built, installed, or exercised; prior validation above applies only to the earlier revision.

Mac action execution/approval receipts and Accessibility grants for the rebuilt bundle, backend task delegation, interruption/audio-quality behavior, network reconnection, crash recovery, and Developer ID release/notarization remain unverified. No automated end-to-end action suite was run. The existing requirements lock remains a compatible superset; it was not regenerated.

Existing limitations: a process crash during an in-flight AgentOS task needs run-status reconciliation; continuation POSTs have an at-least-once acknowledgement window. The local action ledger prevents repeating the desktop side effect.
