#!/usr/bin/env bash
# Starts what stack.txt describes: N vLLM replicas of one model (via vllm-serving, with --enable-scale-out for
# cache-aware routing), waits until they answer, then the router in front. Stop with ./stop-stack.sh.
# A replica port that already serves the model is reused, not started twice.
set -euo pipefail
cd "$(dirname "$0")"
# What the caller set for this run (router.env fills the rest from stack.txt)
env_MODEL="${MODEL:-}"; env_REPLICAS="${REPLICAS:-}"; env_POLICY="${POLICY:-}"
env_ROUTER_PORT="${ROUTER_PORT:-}"; env_METRICS_PORT="${METRICS_PORT:-}"
source ./router.env
mkdir -p logs

fail() { echo "✗ $*" >&2; exit 1; }
one() {   # one KEY -> the single active value in stack.txt (environment variable wins); fails on 0 or 2+ lines
  local env_name="$2" n vals
  if [[ -n "${!env_name:-}" ]]; then echo "${!env_name}"; return; fi
  vals=$(stack_value "$1"); n=$(printf '%s' "$vals" | grep -c . || true)
  [[ $n -eq 1 ]] || fail "$STACK_FILE: expected exactly one active '$1:' line, found $n"
  echo "$vals"
}
[[ -f "$STACK_FILE" ]] || fail "No $STACK_FILE - it says which model, how many replicas and which policy"
MODEL=$(one model env_MODEL)
REPLICAS=$(one replicas env_REPLICAS)
POLICY=$(one policy env_POLICY)
ROUTER_PORT=$(one router_port env_ROUTER_PORT)
METRICS_PORT=$(one metrics_port env_METRICS_PORT)
export POLICY ROUTER_PORT METRICS_PORT

[[ "$REPLICAS" =~ ^[0-9]+$ && $REPLICAS -ge 1 && $REPLICAS -le 8 ]] || fail "replicas must be a number from 1 to 8 (got '$REPLICAS')"
case "$POLICY" in cache_aware|round_robin|power_of_two|random|consistent_hash|sticky_least_loaded) ;;
  *) fail "Unknown policy '$POLICY'. Use one of: cache_aware round_robin power_of_two random consistent_hash sticky_least_loaded" ;; esac
for p in "$ROUTER_PORT" "$METRICS_PORT"; do [[ "$p" =~ ^[0-9]+$ && $p -ge 1024 && $p -le 65535 ]] || fail "Ports must be 1024-65535 (got '$p')"; done
[[ "$ROUTER_PORT" != "$METRICS_PORT" ]] || fail "router_port and metrics_port must differ"

# The model's config in vllm-serving, found by name
serve="$VLLM_SERVING_DIR/serve.sh"
[[ -x "$serve" ]] || fail "serve.sh not found in VLLM_SERVING_DIR=$VLLM_SERVING_DIR (clone github.com/helloravisha/vllm-serving, run its setup.sh)"
platform=nvidia; [[ "$(uname -s)" == Darwin ]] && platform=mac
config=""; available=()
for f in "$VLLM_SERVING_DIR"/configs/$platform/*.yaml; do
  name=$(grep -m1 -E '^served-model-name:' "$f" | awk '{print $2}'); name=${name:-$(grep -m1 -E '^model:' "$f" | awk '{print $2}')}
  [[ -n "$name" ]] && available+=("$name")
  [[ "$name" == "$MODEL" ]] && config="configs/$platform/$(basename "$f")"
done
[[ -n "$config" ]] || { echo "✗ No config for model '$MODEL' in $VLLM_SERVING_DIR/configs/$platform/. Available:" >&2; printf '    %s\n' "${available[@]}" >&2; exit 1; }
base_port=$(grep -m1 -E '^port:' "$VLLM_SERVING_DIR/$config" | awk '{print $2}'); base_port=${base_port:-8000}
ports=(); for ((i=0; i<REPLICAS; i++)); do ports+=($((base_port + 10*i))); done

echo "Stack: $REPLICAS x $MODEL ($config) on ports ${ports[*]}, policy $POLICY, router :$ROUTER_PORT"
if [[ $platform == mac && $REPLICAS -ge 4 ]]; then
  echo "  ⚠ $REPLICAS replicas on a Mac: each reserves about 25% of GPU memory - they may not all start"
fi

answers() {   # answers PORT -> 0 if a vLLM server there serves $MODEL
  curl -s -m 2 -H "Authorization: Bearer $VLLM_API_KEY" "http://127.0.0.1:$1/v1/models" 2>/dev/null | grep -q "\"$MODEL\""
}

for port in "${ports[@]}"; do
  if answers "$port"; then echo "  :$port already serving $MODEL - reusing it"; continue; fi
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $port is taken by something else ($(lsof -nP -iTCP:"$port" -sTCP:LISTEN | awk 'NR==2{print $1, "pid", $2}')) - stop it or change the model's port"
  fi
  echo "  :$port starting (log: logs/vllm-$port.log)"
  # The whole background part writes to the log only (not to this terminal or a pipe), so
  # './start-stack.sh | tee ...' returns; exec makes the pid in the .pid file vLLM's own.
  (cd "$VLLM_SERVING_DIR" && exec nohup ./serve.sh "$config" --port "$port" --enable-scale-out) \
    < /dev/null > "logs/vllm-$port.log" 2>&1 &
  echo $! > "logs/vllm-$port.pid"
done

for port in "${ports[@]}"; do
  for i in $(seq 1 120); do
    answers "$port" && { echo "  ✓ :$port ready"; break; }
    if [[ -f "logs/vllm-$port.pid" ]] && ! kill -0 "$(cat "logs/vllm-$port.pid")" 2>/dev/null && ! answers "$port"; then
      echo "  ✗ :$port exited while starting - last lines of logs/vllm-$port.log:" >&2; tail -15 "logs/vllm-$port.log" >&2; exit 1
    fi
    [[ $i == 120 ]] && fail ":$port not ready after 240s (first start downloads the model) - see logs/vllm-$port.log"
    sleep 2
  done
done

urls=(); for port in "${ports[@]}"; do urls+=("http://127.0.0.1:$port"); done
./start-router.sh "${urls[@]}"
echo
echo "Stack up: $REPLICAS x $MODEL (${ports[*]}) behind http://127.0.0.1:$ROUTER_PORT/v1 (policy $POLICY)"
echo "  Gateway base_url for $MODEL: http://localhost:$ROUTER_PORT/v1"
echo "  Test: ./test-router.sh   Status: ./status.sh   Stop everything: ./stop-stack.sh"
