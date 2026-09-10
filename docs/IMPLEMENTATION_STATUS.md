# Implementation status

“Implemented” means the fail-closed source path exists. It does not mean the code has been built, tested, signed, deployed, or exercised against live services. Repository policy requires explicit user authorization before those checks.

| Milestone | Implemented in source | External work before production |
|---|---|---|
| M0 — shell and distribution | Native `LSUIElement` app; fixed nonactivating panel; drag/snap/display persistence; approvals; status recovery; Sparkle; pinned CUA and WebRTC packaging; Developer ID/notary/staple/DMG/appcast release lane | Original art; Apple and Sparkle credentials; HTTPS release hosting; signed update rehearsal; visual QA |
| M1 — app monitor | `NSWorkspace` lifecycle and activation; same-user `libproc` metrics; responsible-process grouping; bounded AX title lookup; idle/screen-state handling | Supported-device energy and compatibility measurements |
| M2 — agent telemetry | Defensive Claude/Codex JSONL parsing; durable inode/offset cursors; bounded incremental reads; delta-only Codex accounting; FSEvents and per-file activity watching | Version fixtures, rotation/archive exercises, and long-file profiling |
| M3 — AgentOS backend | Agno 2.8.5 AgentOS; reusable Menso Agent; app-agnostic `MensoCuaToolkit`; user-scoped LearningMachine; reviewed improvement Workflow; authenticated learning CRUD; JWT identity; safe registry; Realtime client-secret route; Postgres/pgvector; Docker/Railway assets | Provider/JWT/Postgres credentials, deployment configuration, and authorized validation |
| M4 — approvals and generic CUA | Exact app/window/element targets; typed open/focus/insert/activate operations; app-owned target and full-operation authority; policy/review; idempotent ActionExecutor; durable results/audit/reviews/continuations; pinned CUA 0.12.6 private MCP host; structured pre/post verification | Signed TCC exercise and per-app compatibility evidence; server acknowledgement for fully crash-atomic continuation delivery |
| M5 — dictation | AVAudioEngine capture; 16 kHz mono conversion; route/config rebuild; Carbon hotkey; nonactivating HUD; Apple on-device Speech adapter; exact focused target; policy/review; verified insertion boundary | Microphone/Accessibility exercise, locale coverage, application-specific observable insertion support, and HUD QA |
| M6 — live voice | Authenticated short-lived Realtime credentials; native WebRTC mic/playback/data channel; single `delegate_to_menso` boundary; direct Agent routing; exact optional desktop-action authority; bounded fresh-credential reconnect; durable compact continuity; CoreAudio route/AEC policy | Authorized Realtime exercise and AgentOS status reconciliation for an `in_flight` delegation recovered after process death |
| M7 — learning management | User-scoped profile/memory/session learning; admin evidence-backed improvement review; native authenticated list/edit/delete UI; recalled learning kept advisory | Production retention policy, operator review procedure, and authorized end-to-end exercises |

## Deliberate fail-closed boundaries

- Raw CUA MCP tools never enter a model. Agno exposes only typed semantic functions with `external_execution=True`; the signed app compares the model proposal with app-owned target and operation authority before local execution.
- CUA resources are accepted only at the reviewed release, archive hash, binary hash, session-policy hash, and protocol. A semantic receipt succeeds only after structured native read-back proves the requested result.
- The continuation outbox persists exact endpoint-specific JSON and never re-executes the desktop action. Direct AgentOS continue endpoints do not accept Menso’s delivery nonce, so a process crash after server acceptance but before the local delivered mark leaves an at-least-once POST window. Local side effects remain at-most-once.
- A live-voice delegation recovered as `in_flight` is not blindly submitted again. An authenticated AgentOS run-status reconciliation API is required to decide its terminal state safely.
- Missing SQLite, identity, credentials, permissions, exact authority, audit persistence, or post-action evidence disables the affected feature.

No test, build, compiler, lint, format, import, package-resolution, signing, deployment, eval, or live integration command has been run.
