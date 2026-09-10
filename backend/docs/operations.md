# Operations

The image is portable; Railway-specific commands live only under `scripts/railway/`. Postgres must include pgvector and persistent storage. Run one API replica initially because the built-in scheduler is enabled and Workflow pause behavior should be observed before introducing distributed scheduler coordination.

Readiness is available through the `deployment-check` Workflow. Its checks do not execute models or CUA. The `run-evals` Workflow does use models and is disabled on the schedule by default. `agent-improvement` is always registered disabled and is started only as an explicit, verified maintainer run with ownership-bound evidence.

Production startup fails when JWT verification is absent. Also treat a missing OpenAI credential, HTTPS public URL, Realtime HMAC salt, private database connectivity, or duplicated component ID as a deployment failure. The Railway bootstrap helper requires an inline verification key because it cannot upload a host `JWT_JWKS_FILE`; use the file setting only when the file is mounted or baked into the deployed image. Keep `.env.production` out of version control and use the Railway environment sync script only from a trusted terminal.
