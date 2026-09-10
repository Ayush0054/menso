---
name: create-agent
description: Add a narrowly scoped Menso Agent while preserving public capability boundaries.
---

# Create a Menso Agent

First decide whether the task is an open-ended Agent task or an ordered, resumable Workflow. Prefer the existing Menso Agent for conversation and classification. A new action executor must be an internal singleton with one semantic external-execution tool, no learning/history, and no public AgentOS registration. Never give a public Agent Slack send. Update the safe registry only for read-only, least-privilege resources. Do not run validation or model probes without explicit permission.
