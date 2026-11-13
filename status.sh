#!/usr/bin/env bash
# Shows whether the router runs, its workers, and how requests were routed (changes nothing).
set -uo pipefail
cd "$(dirname "$0")"
source ./router.env
if ! docker ps --format '{{.Names}}' | grep -qx "$ROUTER_NAME"; then echo "Router: not running (start with ./start-router.sh)"; exit 0; fi
echo "Router: running on :$ROUTER_PORT (container $ROUTER_NAME, $(docker inspect -f '{{.Config.Image}}' "$ROUTER_NAME"))"
curl -s -m 5 -H "Authorization: Bearer $VLLM_API_KEY" "http://127.0.0.1:$ROUTER_PORT/workers" | python3 -c '
import json,sys
for w in json.load(sys.stdin)["workers"]:
    print("  worker %-36s healthy=%s" % (w["url"], w["is_healthy"]))' 2>/dev/null || echo "  (workers unavailable)"
echo "Routing so far (since the router started):"
curl -s -m 5 "http://127.0.0.1:$METRICS_PORT/metrics" | python3 -c '
import re,sys
for line in sys.stdin:
    m = re.match(r"^vllm_router_(processed_requests_total|prefix_routing_decisions_total)\{([^}]*)\}\s+(\S+)", line)
    if m:
        labels = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(2)))
        what = labels.get("worker") or labels.get("outcome")
        print("  %-34s %-40s %s" % (m.group(1), what, m.group(3)))'
