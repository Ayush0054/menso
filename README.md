# Menso

Menso is a native macOS companion that monitors local apps and AI-agent sessions, surfaces approvals, supports dictation and live voice, and delegates narrow desktop actions through a signed, policy-controlled client.

The implementation follows [ARCHITECTURE.md](ARCHITECTURE.md). It is split into two trust domains:

- `macos/` owns observation, approvals, policy, credentials, audio, audit evidence, and all desktop execution.
- `backend/` owns AgentOS APIs, reusable Agno Agents and Workflows, typed external-execution requirements, learning state, and Postgres persistence.

The backend cannot control the Mac. A CUA-backed Agno tool pauses its run; the authenticated Mac validates the exact requirement, applies local policy, executes only through the pinned embedded CUA host, requires observable outcome evidence, and continues the same run with the endpoint-specific payload. When an application-specific verifier is unavailable, the action fails closed.

## Repository map

- `backend/` — Python 3.12 AgentOS service and Railway-compatible deploy layer.
- `macos/` — macOS 14+ Swift package containing the AppKit/SwiftUI shell and trusted client core.
- `integrations/claude-code/` — opt-in Claude Code hook plugin; it never edits global Claude settings.
- `docs/SECURITY.md` — non-negotiable trust, identity, and action invariants.
- `docs/IMPLEMENTATION_STATUS.md` — implemented milestone map and remaining platform adapters.

## Local setup

Read the component READMEs before configuring credentials:

1. Start Postgres with pgvector and configure `backend/example.env`.
2. Run the AgentOS service using the backend's documented environment.
3. Configure the macOS client with the authenticated AgentOS URL.
4. Opt into CUA, Claude hooks, microphone, or Screen Recording only when their feature is enabled.

The checked-in source includes the trusted boundaries and release machinery. Generic CUA actions are implemented through a pinned private driver adapter that proves the exact native target and resulting state before returning success. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the precise split between source implementation and external production inputs.

Provider, JWT, and Realtime secrets must not be committed. Production provider keys remain on the backend. The local hook token remains in the Mac Keychain.

## Validation status

Validation is intentionally not run during architecture implementation. Repository policy requires explicit user approval before any build, test, lint, formatting, import, or live smoke command.
