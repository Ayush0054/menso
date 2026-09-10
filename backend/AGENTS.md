# Backend agent instructions

This package is the Menso server trust domain. Preserve these invariants:

- Never import or add a backend CUA driver. CUA methods are Agno external-execution declarations only.
- The public Menso Agent may use only the app-agnostic semantic actions registered by `MensoCuaToolkit`; never expose raw CUA primitives, shell/browser tools, or secrets through the public Agent.
- Never publish `MensoCuaToolkit` or any integration Toolkit through the AgentOS Studio registry. Code-defined Agents retain their reviewed tool instances.
- Keep direct Agent continuation (`tools`) separate from Workflow continuation (`step_requirements`). Preserve original identifiers and the full append-only Workflow envelope.
- Derive user authority from the verified JWT subject. Production uses audience verification and `user_isolation=True` and must fail closed without a verification source.
- Keep executor Agents fixed, singleton, one-tool, and free of LearningMachine/history/knowledge.
- Learning may personalize context or emit reviewed proposals; it cannot edit source, add tools, change policy, run evals, or deploy.
- Keep portable packages free of Railway imports. Railway behavior belongs under `scripts/railway/` and `railway.json`.
- Do not run tests, builds, linters, formatters, imports, compilers, validation, evals, containers, or deploy commands until the user explicitly asks.

When Agno APIs are changed, verify against the exact pinned official source before editing and update the pin/lock deliberately.
