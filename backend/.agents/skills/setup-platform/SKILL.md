---
name: setup-platform
description: Configure the Menso AgentOS backend without weakening its client/server trust boundary.
---

# Setup Menso backend

Read `README.md`, `AGENTS.md`, `example.env`, and `app/main.py`. Explain the required OpenAI, Postgres, JWT audience/key, public HTTPS URL, and safety-identifier salt settings. Never copy Mac Slack tokens or Accessibility credentials into the backend. Do not start containers, import the app, or run checks until the user explicitly authorizes it. When authorized, use the portable Compose path before any Railway action.
