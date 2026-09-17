# Menso implementation status

This document describes source implementation, not successful builds or live behavior.

## Current scope

| Area | Source implementation |
| --- | --- |
| Desktop app | Regular Dock app, one resizable AppKit window, native SwiftUI content, standard menu and Settings |
| Voice | GPT-Live `gpt-live-1`, authenticated server SDP exchange, native WebRTC, transcript deltas, client delegation, reconnects and explicit close |
| Task backend | One Menso Agent, verified JWT identity, Postgres task history, typed results |
| Mac actions | Open app, focus window, insert exact text, set control; locally prepared target and operation |
| Approval | Approve once or decline; exact action binding, expiry, durable audit, receipt verification |
| Results | In-window result status, saved continuation retry, concise voice result |
| Connection | Server URL and product credentials in Settings; device Keychain; restart after changes |

## Removed

Floating widget/robot, screen-edge modes, app/process monitoring, coding-agent token dashboards, Claude hooks, dictation/HUD/hotkeys, learning management and LearningMachine, improvement/deployment/eval workflows, schedules, and the public MCP server.

The release scripts still contain signing/notarization and Sparkle packaging infrastructure. There is no updater UI or running updater in this reduced app. Historical SQLite tables and action wire variants remain readable; no user data has been deleted.

## Not yet validated

Per repository instructions, no builds, compilers, tests, imports, linters, formatters, containers, or live smoke checks were run for this change. The new UI has not been rendered.

Still requires authorized validation: Swift compilation, Python imports, signed microphone/Accessibility prompts, real GPT-Live access/session lifecycle, per-app action evidence, reconnection behavior, and release packaging. The existing requirements lock is retained as a compatible superset; regenerating it after dependency removal is deferred until authorized.

Existing limitations: a process crash during an in-flight AgentOS task needs run-status reconciliation; continuation POSTs have an at-least-once acknowledgement window. The local action ledger prevents repeating the desktop side effect.
