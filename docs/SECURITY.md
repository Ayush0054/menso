# Menso security invariants

Menso treats every message, transcript line, model response and selected desktop target as untrusted input. These invariants are architectural requirements, not prompt guidance.

## Trust domains

The signed macOS app is the only component allowed to hold Accessibility and microphone permissions, plus local credentials. TypeSafe receives bounded candidate descriptions and user text, never raw TCC authority. AgentOS is retained as the verified-JWT HTTP/database host with no registered agents.

The app launches only the pinned CUA 0.12.6 resources through a direct-child embedded-host responsibility chain. The release manifest binds the archive, executable, session policy, release commit, and MCP protocol; runtime startup rechecks the executable and policy hashes, signed-host attribution, and required permissions. A hosted service, terminal, shell tool, or arbitrary helper must never spawn a raw CUA daemon on Menso's behalf.

## Action authority

- Model output can propose only registered semantic actions. It cannot create a tool, widen a capability, change a policy rule, or waive confirmation.
- Voice requests snapshot app identities and focused-target metadata locally. TypeSafe can select only an ID from an immutable native catalog or abstain. The Mac freezes exact target, text/state, identity, content hash, and expiry before mandatory review. TypeSafe confidence never grants authority. Observed labels and transcript text are untrusted data. No manual preparation form is required.
- `native_voice` requests have no AgentOS origin. Legacy `voice_delegation` still requires an Agent or Workflow binding. Policy remains deny-by-default; a native proposal gets only an exact review-only rule. A selected ID cannot return arbitrary tool arguments, policy, approval state, run IDs, or execution results.
- Raw click, type, key, screenshot, shell, browser, and unrestricted CUA primitives are not model-visible.
- Workflow human review and CUA external execution are separate pauses. Approval of one does not resolve the other.
- The Mac binds each request to authenticated user and device identity, run and session IDs, workflow and step IDs where applicable, expected tool name, target, content hash, idempotency key, and expiry.
- Replays return the prior terminal result. They do not repeat the desktop side effect.
- Ambiguous targets, expired requests, secure input, missing verification, mismatched IDs, unknown tools, or unavailable audit storage fail closed.
- Transport acceptance is not verification. Until an application-specific adapter can observe the exact target and resulting content, CUA clicks, key presses, typing, and CGEvent insertion cannot produce a verified action receipt.

## Continuations

These are legacy transport invariants. The TypeSafe desktop path uses no backend continuation and does not start the old delivery worker. Its native pending reviews expire in three minutes and are not restored after quitting. Durable action reservations/receipts prevent implicit execution replay; persisted in-flight voice requests are not resubmitted automatically.

Direct Agent tool requirements continue through the Agent endpoint with the original tool ID and `tools` payload. Workflow executor requirements continue through the Workflow endpoint with the complete updated `step_requirements` envelope. Menso never translates one contract into the other or reconstructs rich requirements from generic tool calls.

Only the last active unresolved Workflow requirement may be resolved. Earlier requirements are preserved as run history.

Before a continuation POST, the client durably stores the exact Agent `tools` or Workflow `step_requirements` JSON. Retry workers submit only that stored envelope and never call the local action executor. A server `2xx` is quarantined from same-process resend even if the local delivered mark temporarily fails. Because the pinned direct AgentOS endpoints have no idempotency-nonce field, a crash in the server-accepted/local-uncommitted window remains at-least-once for the continuation request; this limitation does not authorize replaying the desktop side effect.

## Identity and storage

- `user_id` comes from the verified JWT subject; request bodies cannot override it.
- The durable product conversation ID is the verified native product session ID (compatible with legacy AgentOS `session_id`); an ephemeral GPT-Live connection ID is not.
- Local SQLite is authoritative for whether a desktop action executed. Backend rows may reference a local action ID but cannot claim local execution independently.
- GPT-Live session and delegation IDs never become durable AgentOS identity. Replacement voice sessions receive bounded, passive continuity; a prior delegation is never replayed as a new action.
- Provider keys stay on the server. Product bearers are sent only to the configured Menso backend. Audio is sent to OpenAI only during a voice session the user starts.

## Platform limits

Menso does not automate SecurityAgent, TCC, admin-password, Touch ID, or other OS-owned secure surfaces. Input Monitoring and Full Disk Access are out of scope for v1.
