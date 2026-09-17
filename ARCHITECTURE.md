# Menso architecture

## Product boundary

One Mac desktop window supports voice conversation, one proposed Mac action per request, explicit approval, and a visible result. There are no preparation forms, widget modes, monitoring dashboards, Claude hooks, dictation, learning screens, scheduler, operational workflows, or public MCP server.

The four semantic actions are `open_application`, `focus_window`, `insert_text`, and `activate_control`. On a voice delegation the Mac snapshots installed/running app identities and, with Accessibility permission, the focused target's app/window/control metadata. No screenshot or field value is captured. The Mac constructs an immutable catalog of exact actions. TypeSafe selects one catalog ID or abstains; it cannot generate action arguments. Text candidates are literal transcript spans, not generated drafts. Control candidates have explicit checked/unchecked/selected/unselected outcomes. The Mac creates one three-minute, approve-once review before execution. No manual preparation is required.

## Trust domains

The signed Mac owns action orchestration, policy, approval, audio, desktop execution, and verification. TypeSafe owns only a bounded classification decision. AgentOS remains as the existing verified-JWT HTTP/database host, with no registered agents. Legacy stored task history is retained. There is no Agent run, tool pause, or continuation in the active voice-action path.

TypeSafe receives candidate IDs, semantic kinds, descriptions, and the current user utterance. The complete target/operation bindings remain in the Mac's catalog. Raw CUA, coordinates, screenshots, key events, shell commands, and arbitrary selectors are never exposed to a model. The pinned embedded driver runs only behind the local broker and the signed app's permissions.

Authentication derives `user_id` from the verified JWT subject. A caller-supplied user field is never authority. The Mac verifies the backend account before obtaining its product bearer token for voice negotiation. HTTPS is required except for local loopback.

## Voice

1. The Mac opens a native WebRTC audio track after explicit user activation and microphone permission.
2. It gathers ICE candidates and submits an SDP offer to authenticated `POST /menso/live/session`.
3. The backend creates `gpt-live-1` with client delegation at OpenAI's `POST /v1/live/sessions`. The standard OpenAI key remains server-side.
4. The Mac applies the returned SDP answer and waits for `session.started`. An open data channel alone is not readiness.
5. Input/output transcript deltas are retained as bounded conversational context and displayed as independent speaker captions.
6. `session.delegation.created` carries an opaque ID and timestamp, not a task. The adapter takes fresh user transcript fragments since the previous delegation and before that timestamp, preserving user speech interleaved with backchannels. Assistant speech, saved history, and already delegated fragments are excluded. Oversized text is rejected, not suffix-truncated into a different command. A bare confirmation without an explicit target requires clarification.
7. The Mac calls authenticated `POST /menso/actions/select`. The backend calls TypeSafe `POST /v1/systemone` with one Choice question and `jev-latest`. The response is a known candidate ID, `unclear`, or `unsupported`. A malformed, unknown, or low-confidence choice cannot create a review. Confidence is an unevaluated abstention heuristic, never authority.
8. Verified results return through `session.commentary.append`; quiet progress uses `session.thinking.append`. Payloads are bounded below Live's 500-token append limit. Full receipts stay local.
9. Ending a conversation disables microphone/playback immediately, requests `session.close`, waits briefly for `session.closed`, and tears down the peer. A timeout is not proof of provider finalization.

The voice adapter owns the native audio path; no second microphone capture or dictation engine runs. Client event permissions are restricted by server configuration. GPT-Live handles conversation; TypeSafe selects actions without a second generative agent. Generated writing, arbitrary screen reading, and multi-step task planning are outside this path.

## Approval and execution

The local authority includes target, operation, content hash, verified user/product-session IDs, action ID, expiry, and idempotency key. The `native_voice` source accepts no backend requirement origin; legacy `voice_delegation` still requires an Agent/Workflow origin. A selection cannot invent an installed app or substitute another target. `TypeSafeVoiceDelegationBridge` registers an exact review-only policy rule, then publishes a native review through `RunPauseCoordinator`. No Agno identifiers are fabricated.

The UI exposes approve-once and decline. Execution requires durable local storage, current permissions, policy approval, a matching target, and observable evidence. A completed desktop task must include its one locally stored, verified receipt with the same target and content hash.

Approval cards are pinned below the transcript and come only from the native pending-review stream. They display the exact target and proposed text/state. The TypeSafe response schema has no approval, completion, or continuation fields. After review, identity is rechecked and the existing local executor enforces current policy, secure input, exact target matching, audit persistence, and evidence. Only the executor's verified result is reported as completed. Repeated provider call IDs reuse the same task; conflicting payloads are rejected.

A provider's spoken response, successful HTTP request, or data-channel acceptance is never proof of desktop execution.

## Continuation and recovery

The new path has no backend continuation. Pending native reviews are memory-only and expire after three minutes. After quitting, users must issue a fresh request; reviews and in-flight provider calls are not automatically replayed. SQLite still persists audit, execution reservations, and terminal receipts before result delivery. Interrupting voice is not rollback of an already approved action.

Legacy Agent, Team, and Workflow continuation payloads remain distinct in shared transport/storage types. Direct Agent pauses use `tools`; Workflow continuation preserves the complete `step_requirements` envelope. Never translate between them. The desktop no longer starts legacy continuation delivery workers. Stored envelopes and historical user data are not deleted.

Voice reconnects use fresh authenticated sessions and bounded, passive continuity. Saved results can be redelivered without selecting or executing the action again. An interrupted in-flight action has an unknown outcome until its local receipt is inspected; a fresh request is not automatic recovery and may repeat a user's intended action.

Restored voice context excludes earlier assistant speech. Historical `requires_external_action` results become silent, unconfirmed history, never a current approval claim. Original checkpoints remain intact for recovery; only the context sent to the replacement voice session is filtered. A new explicit user request still needs a fresh delegation.

Existing local database migration definitions and legacy action wire cases are retained for compatibility. This change does not purge previously stored user data.

## Deployment status

Agno remains pinned at 2.8.5 for host/auth compatibility. Both GPT-Live negotiation and TypeSafe selection use the existing `httpx` dependency; no new SDK/lock update is required. Set `TYPESAFE_API_KEY` server-side and optionally `TYPESAFE_MODEL` (default `jev-latest`). Existing `live:connect` credentials are accepted for selection; dedicated clients may use `actions:select`.

The source has not been built or exercised as part of this change. Signed-app permissions, real WebRTC sessions, per-app action verification, dependency-lock cleanup, and release packaging remain unvalidated.
