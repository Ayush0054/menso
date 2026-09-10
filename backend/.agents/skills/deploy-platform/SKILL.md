---
name: deploy-platform
description: Deploy the portable Menso backend to Railway with production security preflights.
---

# Deploy Menso

Deployment requires an explicit user request. Confirm pinned requirements, private persistent pgvector, production JWT verification, audience equal to `OS_ID`, HTTPS public URLs, a high-entropy safety salt, disabled eval/improvement schedules, and no `RUNTIME_ENV=dev`. Keep secrets out of terminal output. Deploy one replica initially, run only the checks the user authorizes, and never treat a successful build as proof that CUA or Slack execution works.
