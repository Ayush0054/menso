# Menso security invariants

Menso treats every message, transcript line, dialog label, model response, recalled learning, and desktop observation as untrusted input. These invariants are architectural requirements, not prompt guidance.

## Trust domains

The signed macOS app is the only component allowed to hold Accessibility, Screen Recording, microphone, or local hook credentials. AgentOS and its models receive typed context and action receipts, never raw TCC authority.

The app launches only the pinned CUA 0.12.6 resources through a direct-child embedded-host responsibility chain. The release manifest binds the archive, executable, session policy, release commit, and MCP protocol; runtime startup rechecks the executable and policy hashes, signed-host attribution, and required permissions. A hosted service, terminal, shell tool, or arbitrary helper must never spawn a raw CUA daemon on Menso's behalf.

## Action authority

- Model output can propose only registered semantic actions. It cannot create a tool, widen a capability, change a policy rule, or waive confirmation.
- Raw click, type, key, screenshot, shell, browser, and unrestricted CUA primitives are not model-visible.
- Workflow human review and CUA external execution are separate pauses. Approval of one does not resolve the other.
- The Mac binds each request to authenticated user and device identity, run and session IDs, workflow and step IDs where applicable, expected tool name, target, content hash, idempotency key, and expiry.
- Replays return the prior terminal result. They do not repeat the desktop side effect.
- Ambiguous targets, expired requests, secure input, missing verification, mismatched IDs, unknown tools, or unavailable audit storage fail closed.
- Transport acceptance is not verification. Until an application-specific adapter can observe the exact target and resulting content, CUA clicks, key presses, typing, and CGEvent insertion cannot produce a verified action receipt.

## Continuations

Direct Agent tool requirements continue through the Agent endpoint with the original tool ID and `tools` payload. Workflow executor requirements continue through the Workflow endpoint with the complete updated `step_requirements` envelope. Menso never translates one contract into the other or reconstructs rich requirements from generic tool calls.

Only the last active unresolved Workflow requirement may be resolved. Earlier requirements are preserved as run history.

Before a continuation POST, the client durably stores the exact Agent `tools` or Workflow `step_requirements` JSON. Retry workers submit only that stored envelope and never call the local action executor. A server `2xx` is quarantined from same-process resend even if the local delivered mark temporarily fails. Because the pinned direct AgentOS endpoints have no idempotency-nonce field, a crash in the server-accepted/local-uncommitted window remains at-least-once for the continuation request; this limitation does not authorize replaying the desktop side effect.

## Identity and storage

- `user_id` comes from the verified JWT subject; request bodies cannot override it.
- The durable product conversation/task ID is the AgentOS `session_id`; an ephemeral Realtime connection ID is not.
- Local SQLite is authoritative for whether a desktop action executed. Backend rows may reference a local action ID but cannot claim local execution independently.
- Learnings are user-scoped and advisory. They cannot alter tools, policies, targets, confirmations, idempotency, or permissions.
- Credentials, tokens, raw screenshots, audio, terminal secrets, and full third-party messages are excluded from learnings.
- Realtime provider session IDs and function-call IDs never become durable AgentOS identity. Replacement voice sessions receive only bounded, non-executable continuity data; a prior provider call ID is never replayed as a new `function_call_output`.

## Platform limits

Menso does not automate SecurityAgent, TCC, admin-password, Touch ID, or other OS-owned secure surfaces. Input Monitoring and Full Disk Access are out of scope for v1.
