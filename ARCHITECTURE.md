# Menso architecture

## Product boundary

One Mac desktop window supports voice conversation, one prepared Mac action, explicit approval, and a visible result. There are no widget modes, monitoring dashboards, Claude hooks, dictation, learning screens, scheduler, operational workflows, or public MCP server.

The four semantic actions are `open_app`, `focus_window`, `insert_text`, and `activate_control`. The user selects an installed app or captures an exact Accessibility target in the Prepare action sheet. Exact text/state is bound locally. The prepared authority expires after five minutes and is consumed by the next client delegation; preparing an action never executes it.

## Trust domains

The signed Mac owns policy, approval, audio, desktop execution, and verification. AgentOS owns orchestration, verified identity, task history, and backend persistence.

Models receive typed semantic action declarations. Raw CUA, coordinates, screenshots, key events, shell commands, and arbitrary selectors are never exposed to a model. The pinned embedded driver runs only behind the local broker and the signed app's permissions.

Authentication derives `user_id` from the verified JWT subject. A caller-supplied user field is never authority. The Mac verifies the backend account before obtaining its product bearer token for voice negotiation. HTTPS is required except for local loopback.

## Voice

1. The Mac opens a native WebRTC audio track after explicit user activation and microphone permission.
2. It gathers ICE candidates and submits an SDP offer to authenticated `POST /menso/live/session`.
3. The backend creates `gpt-live-1` with client delegation at OpenAI's `POST /v1/live/sessions`. The standard OpenAI key remains server-side.
4. The Mac applies the returned SDP answer and waits for `session.started`. An open data channel alone is not readiness.
5. Input/output transcript deltas are retained as bounded conversational context and displayed as independent speaker captions.
6. `session.delegation.created` carries an opaque ID and timestamp, not a task. The adapter combines the relevant transcript fragments with prior context; it does not invent function arguments.
7. The one Menso Agent runs with the verified product identity. An exact prepared action, if present, is bound to that run locally.
8. Verified results return through `session.commentary.append`; quiet progress uses `session.thinking.append`. Payloads are bounded below Live's 500-token append limit. Full receipts stay local.
9. Ending a conversation disables microphone/playback immediately, requests `session.close`, waits briefly for `session.closed`, and tears down the peer. A timeout is not proof of provider finalization.

The voice adapter owns the native audio path; no second microphone capture or dictation engine runs. Client event permissions are restricted by server configuration. A separate AgentOS model performs task reasoning; GPT-Live is the voice model.

## Approval and execution

The local authority includes target, operation, content hash, identity, run/session IDs, expiry, and idempotency key. The model must echo the exact bound operation. Changed or ambiguous arguments fail closed.

The UI exposes approve-once and decline. Execution requires durable local storage, current permissions, policy approval, a matching target, and observable evidence. A completed desktop task must include its one locally stored, verified receipt with the same target and content hash.

A provider's spoken response, successful HTTP request, or data-channel acceptance is never proof of desktop execution.

## Continuation and recovery

Agent, Team, and Workflow continuation payloads remain distinct in the shared transport types even though only the Menso Agent is registered. Direct Agent pauses use `tools`; Workflow continuation must preserve the complete `step_requirements` envelope. Never translate between them.

The Mac persists terminal action results and the exact continuation envelope before delivery. Retries send saved results and never repeat local execution. Because pinned AgentOS continuation endpoints lack an idempotency nonce, the server-accepted/local-uncommitted crash window remains at-least-once for the continuation POST.

Voice reconnects use fresh authenticated sessions and bounded, passive continuity. Prior provider delegation IDs are not reused. An in-flight delegation after process termination is not automatically replayed: server run-status reconciliation remains an outstanding capability.

Existing local database migration definitions and legacy action wire cases are retained for compatibility. This change does not purge previously stored user data.

## Deployment status

Agno remains pinned at 2.8.5. GPT-Live negotiation uses HTTP directly, so it does not rely on Live helpers in the older pinned OpenAI Python SDK. Model and API definitions follow the current official Live guides.

The source has not been built or exercised as part of this change. Signed-app permissions, real WebRTC sessions, per-app action verification, dependency-lock cleanup, and release packaging remain unvalidated.
