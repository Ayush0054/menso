# Continuation examples

These are wire-contract notes, not standalone requests. Copy the complete pause payload returned by AgentOS and mutate only the exact active result field. Never synthesize IDs or translate between continuation kinds.

## Direct Agent external execution

Start `POST /agents/menso/runs` with authenticated multipart fields `message`, stable `session_id`, `stream=false`, and optional `background=true`.

On `RunPaused`, accept only a registered `MensoCuaToolkit` function. Match its complete application/window/element arguments and semantic operation to authority captured and persisted by the Mac before the run. Execute locally, require observable verification, and set the matching returned tool object's `result` to a JSON string matching `ExternalExecutionResult`. Preserve every other tool field and the original `tool_call_id`.

```text
POST /agents/menso/runs/{run_id}/continue
Content-Type: multipart/form-data

tools=<complete updated tools JSON array>
session_id=<original session_id>
stream=false
```

Do not submit Workflow `step_requirements` to this endpoint.

## Generic Workflow continuation

Workflow continuation remains supported as a separate AgentOS transport contract. Preserve the complete append-only `step_requirements` array. Resolve only its active final requirement. For executor HITL, set the matching executor’s `external_execution_result` and nested `tool_execution.result` to the same typed JSON string; for review, mutate only the documented review fields.

```text
POST /workflows/{workflow_id}/runs/{run_id}/continue
Content-Type: multipart/form-data

step_requirements=<complete updated step_requirements JSON array>
session_id=<original session_id>
stream=false
```

Generic CUA authority is currently granted only to direct `menso` Agent runs. An unregistered Workflow cannot create desktop authority merely by returning a compatible-looking requirement.

Completed output is normalized for voice as `{status, spoken_summary, display_payload, action_receipts}`. Raw pause envelopes, credentials, and CUA evidence are never spoken or forwarded to the live model.
