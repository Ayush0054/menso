# Operations

The portable image uses Postgres task persistence. Railway-specific commands remain under `scripts/railway/`. The application has one Menso Agent; no scheduler, operational workflow, learning curator, or public MCP service is started.

Production requires asymmetric JWT verification, the correct OS audience, HTTPS, a private database, OpenAI project access to GPT-Live, and a private `MENSO_SAFETY_IDENTIFIER_SALT` of at least 32 characters.

Product credentials need `agents:menso:run` and `live:connect`. Reissue older credentials through the trusted issuer. Do not grant admin scopes to fix product authentication failures.

The current dependency lock is retained as a superset while removed feature dependencies are no longer requested by pyproject. Resolve and validate dependencies only after explicit authorization.

No deployment or live API calls were made for the desktop/GPT-Live simplification.
