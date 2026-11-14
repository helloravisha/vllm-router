#!/usr/bin/env bash
# Stops the router and the vLLM replicas that start-stack.sh started (servers you started yourself are left alone).
set -uo pipefail
cd "$(dirname "$0")"
source ./router.env
./stop-router.sh
shopt -s nullglob
for pidfile in logs/vllm-*.pid; do
  port=${pidfile#logs/vllm-}; port=${port%.pid}; pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null; then
    # serve.sh execs vllm, which starts worker processes: stop the whole group, then make sure the port is free
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 20); do lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 1; done
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      lsof -nP -t -iTCP:"$port" -sTCP:LISTEN | xargs kill -9 2>/dev/null
    fi
    echo "vLLM replica on :$port stopped"
  else
    echo "vLLM replica on :$port wasn't running"
  fi
  rm -f "$pidfile"
done
