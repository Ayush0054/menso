# Menso backend

The backend hosts a TypeSafe action selector, verified JWT authentication, existing Postgres state, and GPT-Live session negotiation. It has no desktop execution privileges, LearningMachine, workflows, schedules, or public MCP server.

Agno stays pinned at 2.8.5 only for the existing AgentOS HTTP/JWT/database host. No agent is registered. The legacy agent/tool/continuation source remains for compatibility, but the desktop no longer calls its run endpoints.

## Voice contract

Authenticated `POST /menso/live/session` accepts `{"sdp": "..."}` and returns `{"session": {"id": "..."}, "transport": {"type": "webrtc", "sdp": "..."}}`.

The backend derives the subject from verified JWT middleware, requires `live:connect`, and creates `gpt-live-1` with client delegation. The OpenAI project key stays on the server. The Mac sends its product bearer only to the configured Menso server. No provider client-secret endpoint remains.

GPT-Live supplies transcript/delegation events. The Mac sends fresh user speech since the previous delegation and a bounded native candidate catalog to `POST /menso/actions/select`. TypeSafe's Choice primitive returns one candidate ID, `unclear`, or `unsupported`; Menso rejects unknown IDs, malformed probabilities, or low-confidence choices. The 0.80 confidence/probability threshold is an unevaluated abstention heuristic, not an execution permission.

Request: `{"utterance":"Open Example","candidates":[{"id":"action_0","kind":"open_application","description":"Open Example"}]}`.
Response: `{"status":"selected","candidate_id":"action_0"}` or a non-executable `unclear`/`unsupported` result with a null ID. This endpoint requires verified JWT identity and `actions:select`, `live:connect`, or the existing admin scope. It cannot return approval state, tool arguments, run IDs, or completion receipts. The Mac creates review cards and reports only its own verified execution results.

TypeSafe uses direct HTTP with the existing `httpx` dependency: [API contract](https://docs.typesafe.ai/api.md). The selector does not compose text or plan multi-step work; insertion candidates are exact transcript spans selected by ID.

## Setup

Configuration lives in `example.env`: OpenAI API key with GPT-Live access, `OPENAI_LIVE_MODEL=gpt-live-1`, `TYPESAFE_API_KEY`, `TYPESAFE_MODEL=jev-latest`, a private safety salt of at least 32 characters, Postgres, and asymmetric JWT verification with audience `menso-os`. Add the TypeSafe key to ignored `backend/.env`; never the app, source, or a committed file. A missing key returns HTTP 503 with an actionable client message. After configuration, the API must be recreated to load new environment variables, and the Mac app rebuilt/repackaged for the new bridge. Do not run those steps without authorization.

The existing `scripts/generate_local_auth.sh` creates ignored development credentials with `live:connect` and `actions:select`. Existing `live:connect` tokens remain valid; tokens with only `realtime:connect` must be reissued. No credentials were generated or rotated in this change.

Debug Mac builds can read the ignored local token. Release builds use Settings to verify and store a server URL, session UUID, token, and expiry in Keychain. Restart after connection changes.

Compose and Railway scaffolding remain. No services were started or deployed. The requirements lock is intentionally retained pending an authorized dependency-resolution pass.

## Continuation

No Agent is registered, and TypeSafe has no run/pause/continuation cycle. Legacy Agent `tools` and Workflow `step_requirements` types remain distinct for compatibility with saved envelopes; the new desktop composition does not start their delivery workers. No historical rows are deleted.

Earlier backend and GPT-Live checks predate TypeSafe. This migration and its new regression tests have not been run; see [implementation status](../docs/IMPLEMENTATION_STATUS.md).
