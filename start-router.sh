#!/usr/bin/env bash
# Starts the router in Docker in front of the vLLM servers in workers.txt (or: ./start-router.sh URL URL ...).
# API on :ROUTER_PORT, metrics on :METRICS_PORT, log in logs/router.log. Stop with ./stop-router.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./router.env
mkdir -p logs

if [[ $# -gt 0 ]]; then workers=("$@"); else
  [[ -f "$WORKERS_FILE" ]] || { echo "No $WORKERS_FILE - list your vLLM URLs there or pass them as arguments" >&2; exit 1; }
  workers=(); while IFS= read -r line; do line="${line%%#*}"; line="${line// /}"; [[ -n "$line" ]] && workers+=("$line"); done < "$WORKERS_FILE"
fi
[[ ${#workers[@]} -gt 0 ]] || { echo "No worker URLs" >&2; exit 1; }
docker image inspect "$ROUTER_IMAGE" >/dev/null 2>&1 || { echo "Image $ROUTER_IMAGE not found - run ./setup.sh first" >&2; exit 1; }

# Check every worker before starting: up, key accepted, model name, and (for cache_aware) the render endpoint
echo "Checking ${#workers[@]} worker(s):"
docker_urls=(); problems=0
for url in "${workers[@]}"; do
  base="${url%/}"; base="${base%/v1}"
  health=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$base/health" || true)
  models=$(curl -s -m 5 -H "Authorization: Bearer $VLLM_API_KEY" "$base/v1/models" || true)
  model=$(printf '%s' "$models" | python3 -c 'import json,sys
try: print(",".join(m["id"] for m in json.load(sys.stdin)["data"]))
except Exception: print("")' 2>/dev/null)
  render="-"
  if [[ "$POLICY" == cache_aware && -n "$model" ]]; then
    render=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' \
      "$base/v1/chat/completions/render" -d "{\"model\":\"${model%%,*}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" || true)
  fi
  printf '  %-28s health=%s model=%s render=%s\n' "$base" "$health" "${model:-?}" "$render"
  if [[ "$health" != 200 || -z "$model" ]]; then
    echo "    ✗ not reachable, or the API key ($VLLM_API_KEY) was refused" >&2; problems=1
  elif [[ "$render" == 403 ]]; then
    echo "    ⚠ started without --enable-scale-out: cache_aware can't read prompts from this worker (it still routes, without prefix matching)" >&2
  fi
  # Inside Docker, "localhost" is the container itself: use the host instead
  docker_urls+=("$(printf '%s' "$base" | sed -E 's#://(localhost|127\.0\.0\.1)([:/]|$)#://host.docker.internal\2#')")
done
[[ $problems == 0 ]] || { echo "Fix the worker(s) above, then run again." >&2; exit 1; }

docker rm -f "$ROUTER_NAME" >/dev/null 2>&1 || true
pkill -f "docker logs -f $ROUTER_NAME" 2>/dev/null || true
cmd=(docker run -d --name "$ROUTER_NAME" --add-host=host.docker.internal:host-gateway
     -p "127.0.0.1:$ROUTER_PORT:$ROUTER_PORT" -p "127.0.0.1:$METRICS_PORT:$METRICS_PORT"
     "$ROUTER_IMAGE" --host 0.0.0.0 --port "$ROUTER_PORT" --prometheus-host 0.0.0.0 --prometheus-port "$METRICS_PORT"
     --policy "$POLICY" --api-key "$VLLM_API_KEY" --worker-urls "${docker_urls[@]}")
echo "Starting: ${cmd[*]}"
"${cmd[@]}" >/dev/null
nohup docker logs -f "$ROUTER_NAME" > logs/router.log 2>&1 &

for i in $(seq 1 60); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 -H "Authorization: Bearer $VLLM_API_KEY" "http://127.0.0.1:$ROUTER_PORT/v1/models")" == 200 ]]; then
    echo "✓ Router ready: http://127.0.0.1:$ROUTER_PORT/v1 (policy $POLICY), metrics http://127.0.0.1:$METRICS_PORT/metrics"
    echo "  Log: logs/router.log   Test: ./test-router.sh   Stop: ./stop-router.sh"
    exit 0
  fi
  sleep 1
done
echo "✗ Router didn't answer within 60s - see logs/router.log or: docker logs $ROUTER_NAME" >&2
exit 1
