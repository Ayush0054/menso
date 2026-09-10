#!/bin/bash
set -e
railway status >/dev/null
railway up --service menso-agentos -d
