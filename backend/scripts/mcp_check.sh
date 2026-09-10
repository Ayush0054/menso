#!/bin/bash
set -e

echo "This smoke check invokes a model and is intentionally never run automatically."
echo "When explicitly authorized, connect an authenticated MCP client to http://localhost:8000/mcp"
echo "and call run_agent with agent_id=menso. Production requires an appropriate JWT or service token."
