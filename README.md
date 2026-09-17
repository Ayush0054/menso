# Menso

Menso is a native Mac desktop app for one loop: talk, prepare a small Mac action, approve it, and see the result.

The app has one resizable window with live captions, a start/end voice control, action approvals, and results. A small action sheet supports opening an app, focusing a window, inserting exact text, and setting a control. Preparing an action does not approve it: each execution still requires a local decision.

Voice uses OpenAI `gpt-live-1` with client delegation. A single AgentOS agent handles reasoning and requests typed actions. The signed Mac owns microphone access, target selection, policy, approvals, execution, and verification. Provider keys stay on the backend.

## Repository

- `macos/`: AppKit/SwiftUI desktop app and trusted local execution.
- `backend/`: authenticated AgentOS, GPT-Live session negotiation, and Postgres task state.
- [Architecture](ARCHITECTURE.md): trust boundaries and the voice/action flow.
- [Implementation status](docs/IMPLEMENTATION_STATUS.md): source changes and outstanding runtime validation.
- [Security](docs/SECURITY.md): authority and continuation invariants.

The floating widget, app/process monitoring, coding-agent dashboards, Claude hooks, dictation, learning management, and scheduled workflows have been removed. Historical SQLite tables and action wire variants are retained for data compatibility; nothing collects new monitoring data.

## Configuration

See [backend setup](backend/README.md) and [Mac setup](macos/README.md). The backend needs an OpenAI project with GPT-Live access, Postgres, verified JWT authentication, and a private safety-identifier salt. Product tokens need `live:connect` and `agents:menso:run`; old `realtime:connect` tokens must be reissued by the trusted issuer.

This change has not been built, tested, formatted, or exercised live. The repository requires explicit authorization before those checks. No credentials or databases were changed.
