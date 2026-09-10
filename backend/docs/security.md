# Security and authority notes

Menso splits orchestration from execution. AgentOS authenticates, scopes, persists, and resumes runs. The signed Mac app observes native state, applies local allowlists and approval policy, performs CUA, verifies outcomes, and keeps TCC privileges. An external-execution tool requirement is a request—not evidence that an action occurred.

Production authorization uses one expected audience (`OS_ID`), RS256 by default, and per-user run/session isolation. Normal product JWTs should use per-resource scopes. `/menso/auth/context` and the Realtime route require decoded JWT claims and reject PAT/internal credentials; the Realtime route additionally requires `realtime:connect`, hashes the verified subject with a private high-entropy salt for OpenAI's safety identifier, and returns only the provider's ephemeral `value`, `expires_at`, and constrained `session` object.

Realtime delegation has only two routing hints: `open_ended` and `desktop_action`. Both map to the public Menso Agent. A desktop action is admitted only when the Mac already holds an exact native target and exact semantic operation. Unknown or ambiguous operations must be clarified; Realtime text cannot invent a target or register a new action.

All desktop content and model output are untrusted. The public Agent sees only semantic core actions and never sees raw CUA MCP. The Mac captures exact application/window/element authority and the complete expected operation before starting the run, then rejects different model arguments before execution.

A verified bearer JWT establishes user identity, not device proof-of-possession by itself. The production issuer/pairing service must mint product tokens only after validating the signed Mac's device registration, or add a DPoP/mTLS-equivalent request proof. This repository does not yet implement that external registration/attestation service, so operators must not describe possession of an ordinary bearer token as proof that a paired device made the request.

Never log bearer tokens, provider responses containing secret values, raw Realtime subjects, raw CUA evidence, or unredacted third-party content. Prefer opaque evidence references and normalized action status/error codes. Rotate JWT keys, OpenAI credentials, and the safety salt through the deployment secret manager; rotating the safety salt intentionally changes upstream pseudonymous identifiers.
