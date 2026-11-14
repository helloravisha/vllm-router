#!/usr/bin/env bash
# Starts the whole vLLM side in one go: one vLLM replica per port in REPLICA_PORTS (all serving MODEL_CONFIG,
# with --enable-scale-out for cache-aware routing), waits until they answer, then starts the router in front.
#   ./start-stack.sh
#   REPLICA_PORTS="8000 8010 8020" ./start-stack.sh
# A port where a vLLM server already answers is reused, not started twice. Stop with ./stop-stack.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./router.env
mkdir -p logs

serve="$VLLM_SERVING_DIR/serve.sh"
[[ -x "$serve" ]] || { echo "serve.sh not found in VLLM_SERVING_DIR=$VLLM_SERVING_DIR (clone github.com/helloravisha/vllm-serving and run its setup.sh)" >&2; exit 1; }
[[ -f "$VLLM_SERVING_DIR/$MODEL_CONFIG" ]] || { echo "Model config not found: $VLLM_SERVING_DIR/$MODEL_CONFIG" >&2; exit 1; }
model=$(grep -m1 '^served-model-name:' "$VLLM_SERVING_DIR/$MODEL_CONFIG" | awk '{print $2}')
model=${model:-$(grep -m1 '^model:' "$VLLM_SERVING_DIR/$MODEL_CONFIG" | awk '{print $2}')}
echo "Model: $model ($MODEL_CONFIG), replicas on: $REPLICA_PORTS"

answers() {   # answers PORT -> 0 if a vLLM server there serves $model
  curl -s -m 2 -H "Authorization: Bearer $VLLM_API_KEY" "http://127.0.0.1:$1/v1/models" 2>/dev/null | grep -q "\"$model\""
}

started=()
for port in $REPLICA_PORTS; do
  if answers "$port"; then
    echo "  :$port already serving $model - reusing it"
    continue
  fi
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  ✗ port $port is taken by something else ($(lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR==2{print $1, "pid", $2}'))" >&2; exit 1
  fi
  echo "  :$port starting (log: logs/vllm-$port.log)"
  # The whole background part writes to the log only (not to this terminal or a pipe), so
  # './start-stack.sh | tee ...' returns; exec makes the pid in the .pid file vLLM's own.
  (cd "$VLLM_SERVING_DIR" && exec nohup ./serve.sh "$MODEL_CONFIG" --port "$port" --enable-scale-out) \
    < /dev/null > "logs/vllm-$port.log" 2>&1 &
  echo $! > "logs/vllm-$port.pid"
  started+=("$port")
done

for port in $REPLICA_PORTS; do
  for i in $(seq 1 120); do
    answers "$port" && { echo "  ✓ :$port ready"; break; }
    if [[ -f "logs/vllm-$port.pid" ]] && ! kill -0 "$(cat "logs/vllm-$port.pid")" 2>/dev/null; then
      echo "  ✗ :$port exited while starting - last lines of logs/vllm-$port.log:" >&2; tail -15 "logs/vllm-$port.log" >&2; exit 1
    fi
    [[ $i == 120 ]] && { echo "  ✗ :$port not ready after 240s - see logs/vllm-$port.log" >&2; exit 1; }
    sleep 2
  done
done

urls=(); for port in $REPLICA_PORTS; do urls+=("http://127.0.0.1:$port"); done
./start-router.sh "${urls[@]}"
echo
echo "Stack up: ${#urls[@]} x $model behind http://127.0.0.1:$ROUTER_PORT/v1"
echo "  Gateway base_url for $model: http://localhost:$ROUTER_PORT/v1"
echo "  Test: ./test-router.sh   Status: ./status.sh   Stop everything: ./stop-stack.sh"
