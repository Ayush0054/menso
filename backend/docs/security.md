# Security and authority

AgentOS authenticates, scopes, persists, and resumes tasks. The signed Mac owns local target recognition, policy, approval, execution, and verification. An external-execution requirement is a request, not evidence that an action occurred.

Production authorization uses an expected `OS_ID` audience, asymmetric verification, and user isolation. `/menso/auth/context` and `/menso/live/session` require decoded, verified JWT claims and reject internal/PAT credentials. Live creation requires `live:connect`; the verified subject is HMACed with a private salt for OpenAI's safety identifier.

The backend forwards a constrained server-owned `gpt-live-1` client-delegation configuration and the client's bounded SDP offer to OpenAI. Only the session ID and SDP answer return to the Mac. The provider key is never returned.

Transcripts and model output are untrusted. The Mac may bind one locally prepared semantic operation to a delegation. It verifies all model arguments and asks the user before execution. Results are checked against local receipts before the voice model receives them.

An ordinary bearer JWT establishes account identity, not signed-device proof. Device attestation/registration remains external deployment work. Do not describe a bearer token as proof of a paired device.

Never log bearer tokens, provider keys, raw CUA evidence, SDP bodies, or unredacted third-party content. Preserve exact continuation identifiers and payloads. See the repository security document for crash/retry limitations.
