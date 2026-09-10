# Menso AgentOS backend

This directory owns server orchestration: Agno Agents and Workflows, AgentOS APIs, Postgres/pgvector learning, verified JWT identity, and short-lived OpenAI Realtime client secrets. It never imports a CUA driver or receives macOS TCC authority. Native target recognition, approval, policy, execution, and verification stay in the signed Mac app.

The bootstrap follows Agno’s official `agentos-railway` repository at commit `9184a7e0ecb5e6c59d394281dac1a44f8107ae8e`. Agno is pinned to 2.8.5; upgrades require a continuation and auth re-audit.

## Runtime shape

- `menso` is the only public Agent. Its `MensoCuaToolkit` contains app-agnostic semantic functions for opening an application, focusing an exact window, inserting text into an exact accessibility field, and activating an exact semantic control. Every function uses Agno external execution.
- The backend may propose arguments, but it has no execution authority. Before starting a desktop-action run, the Mac persists the exact locally recognized target and complete expected operation. A changed model argument fails before execution.
- `agent-improvement` is admin-only. It resolves evidence from an owned AgentOS session or an owner-attributed eval, redacts and bounds it, requires human review, and publishes only sanitized learning. It cannot edit source, run evals, deploy, or alter tools.
- `deployment-check` is deterministic. `run-evals` is explicit and never runs at startup.
- `/menso/realtime/client-secret` mints a constrained ephemeral `gpt-realtime-2.1` secret only for a verified JWT with `realtime:connect`. The provider key stays server-side.

Voice delegation returns `{status, spoken_summary, display_payload, action_receipts}` plus optional run metadata. `operation_hint` is strictly `open_ended` or `desktop_action`; both route to `menso`. The second is admitted only with an exact Mac-owned action authority.

Only the public Agent and guarded operational Workflows are registered with AgentOS. The Studio registry deliberately refuses tool registration so AgentOS discovery cannot publish CUA capabilities.

## Continuation boundary

Agent, Team, and Workflow continuation contracts are distinct. Menso currently executes generic desktop actions through the Agent contract:

| Origin | Endpoint | Body | Rule |
|---|---|---|---|
| Agent external execution | `POST /agents/menso/runs/{run_id}/continue` | `tools` | Preserve every returned tool field and `tool_call_id`; set only the exact matching external tool result. |
| Workflow executor/review | `POST /workflows/{workflow_id}/runs/{run_id}/continue` | `step_requirements` | Preserve the complete array and mutate only the active requirement. |

The Mac stores exact continuation JSON before delivery. Non-admin AgentOS user isolation pins the verified JWT subject and checks run/session ownership; request bodies never establish `user_id` authority.

## Local development

Copy `example.env` to `.env`, add `OPENAI_API_KEY`, and choose a random `MENSO_SAFETY_IDENTIFIER_SALT` of at least 32 characters. Generate an ignored local RSA key, public JWKS, and 24-hour scoped Mac bearer token before starting Compose:

```bash
./scripts/generate_local_auth.sh
```

The generated files live under `.local-auth/`. Compose loads only `.local-auth/runtime.env`, which enables RS256 verification against the public JWKS. It does not load the private key or client token. To provision the Mac, copy `.local-auth/menso-local.jwt` into Menso's **Connections** screen and use the timestamp in `.local-auth/token-expiry.txt` as the expiry. Regenerate instead of extending an expired token; an optional first argument selects a lifetime from 1 through 168 hours.

```bash
docker compose up -d --build
```

Production also requires HTTPS `AGENTOS_PUBLIC_URL`, the expected `OS_ID` audience, private Postgres, and narrowly scoped tokens such as `agents:menso:read`, `agents:menso:run`, the product’s sessions/learnings scopes, and `realtime:connect`. Reserve `agent_os:admin` and `workflows:agent-improvement:run` for maintainers.

## Learning and retention

The public Agent uses user-scoped profile, memory, session context, proposed knowledge, and decision history. Recalled content is advisory. Do not retain third-party messages, screenshots, audio, coordinates, secrets, permissions, allowlists, or raw CUA evidence. The Curator publishes only human-reviewed sanitized lessons; source/tool/schema changes remain inert proposal data.

Setup, formatting, validation, eval, image, and Railway scripts are opt-in. No test, import, build, eval, or validation command has been run during this implementation.
