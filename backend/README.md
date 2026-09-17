# Menso backend

The backend hosts one AgentOS agent (`menso`), verified JWT authentication, Postgres task history, and GPT-Live session negotiation. It has no desktop execution privileges, LearningMachine, workflows, schedules, or public MCP server.

Agno stays pinned at 2.8.5. The narrow registry prevents automatic toolkit publication. The public agent exposes only externally executed `open_app`, `focus_window`, `insert_text`, and `activate_control` declarations.

## Voice contract

Authenticated `POST /menso/live/session` accepts `{"sdp": "..."}` and returns `{"session": {"id": "..."}, "transport": {"type": "webrtc", "sdp": "..."}}`.

The backend derives the subject from verified JWT middleware, requires `live:connect`, and creates `gpt-live-1` with client delegation. The OpenAI project key stays on the server. The Mac sends its product bearer only to the configured Menso server. No provider client-secret endpoint remains.

GPT-Live supplies transcript/delegation events; the Mac invokes the Menso Agent with relevant context. The backend returns `status`, `spoken_summary`, optional `display_payload`, and `action_receipts`. A model cannot supply local action authority: the signed Mac must have prepared an exact target/operation and must obtain approval.

## Setup

Configuration lives in `example.env`: OpenAI API key with GPT-Live access, `OPENAI_LIVE_MODEL=gpt-live-1`, a private safety salt of at least 32 characters, Postgres, and asymmetric JWT verification with audience `menso-os`.

The existing `scripts/generate_local_auth.sh` creates ignored development credentials with `live:connect` and `agents:menso:run`. Existing tokens with only `realtime:connect` must be reissued. No credentials were generated or rotated in this change.

Debug Mac builds can read the ignored local token. Release builds use Settings to verify and store a server URL, session UUID, token, and expiry in Keychain. Restart after connection changes.

Compose and Railway scaffolding remain. No services were started or deployed. The requirements lock is intentionally retained pending an authorized dependency-resolution pass.

## Continuation

Only the Menso Agent is registered. Agent `tools` and Workflow `step_requirements` types remain distinct for compatibility with saved envelopes. Retrying a continuation sends its exact saved result and does not execute the Mac action again.

No tests, builds, imports, linting, formatting, or live API calls were run.
