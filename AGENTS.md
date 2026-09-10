# Menso contributor instructions

- Preserve the trust boundary in `ARCHITECTURE.md`: the signed Mac app owns policy, approval, audio, and desktop execution; AgentOS owns orchestration and backend state.
- Never attach raw CUA tools to a model. Add only typed semantic actions with a local verification contract.
- Keep Agent, Team, and Workflow continuation payloads distinct. Workflow continuation must preserve the complete step-requirement envelope.
- Derive user identity from verified authentication. Never accept a caller-supplied `user_id` as authority.
- Do not run tests, builds, compilers, linters, formatters, validation scripts, or live smoke checks until the user explicitly asks.

