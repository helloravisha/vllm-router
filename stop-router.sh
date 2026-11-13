#!/usr/bin/env bash
# Stops and removes the router container (the vLLM servers keep running).
set -euo pipefail
cd "$(dirname "$0")"
source ./router.env
pkill -f "docker logs -f $ROUTER_NAME" 2>/dev/null || true
if docker rm -f "$ROUTER_NAME" >/dev/null 2>&1; then echo "Router stopped"; else echo "Router wasn't running"; fi
