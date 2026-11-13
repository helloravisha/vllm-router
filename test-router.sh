#!/usr/bin/env bash
# End-to-end test of a running router, with curl (python3 only formats JSON). No gateway needed.
#   ./test-router.sh            uses router.env (port, API key, policy)
# Checks: router answers; a chat works; two requests sharing a ~800-word system prompt are routed
# (cache_aware: the 2nd must be a prefix hit); per-worker routing from the metrics endpoint.
set -uo pipefail
cd "$(dirname "$0")"
source ./router.env
R="http://127.0.0.1:$ROUTER_PORT"; M="http://127.0.0.1:$METRICS_PORT/metrics"
AUTH="Authorization: Bearer $VLLM_API_KEY"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@" 2>/dev/null; }
metric_sum() {   # metric_sum NAME LABEL=VALUE  -> summed value from /metrics
  curl -s -m 5 "$M" | python3 -c '
import re,sys
name, want = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
total = 0.0
for line in sys.stdin:
    m = re.match(r"^" + name + r"\{([^}]*)\}\s+(\S+)", line)
    if m and (not want or want in m.group(1)): total += float(m.group(2))
print(int(total))' "$@"
}

echo "1. Router answers on $R"
code=$(curl -s -o "$tmp/models.json" -w '%{http_code}' -m 5 -H "$AUTH" "$R/v1/models")
if [[ "$code" == 200 ]]; then MODEL=$(json "$tmp/models.json" 'd["data"][0]["id"]'); ok "GET /v1/models -> 200, model $MODEL"
else bad "GET /v1/models -> $code (is it running? ./start-router.sh)"; echo "Stopping: router not reachable"; exit 1; fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$R/v1/models")
[[ "$code" == 401 ]] && ok "without the API key -> 401 (key required, as on the workers)" || echo "  INFO  without the API key -> $code"

echo "2. One chat request"
cat > "$tmp/chat.json" <<J
{"model": "$MODEL", "max_tokens": 20, "temperature": 0, "messages": [{"role": "user", "content": "Say hello in five words."}]}
J
code=$(curl -s -o "$tmp/out.json" -w '%{http_code}' -m 120 -H "$AUTH" -H 'Content-Type: application/json' "$R/v1/chat/completions" -d @"$tmp/chat.json")
if [[ "$code" == 200 ]]; then ok "POST /v1/chat/completions -> 200: $(json "$tmp/out.json" 'd["choices"][0]["message"]["content"].strip()[:60]')"
else bad "POST /v1/chat/completions -> $code: $(head -c 200 "$tmp/out.json")"; fi

echo "3. Two requests sharing a long system prompt (different questions)"
python3 - "$MODEL" "$tmp" <<'PY'
import json, sys, time
model, tmp = sys.argv[1], sys.argv[2]
topics = ["moving averages", "relative strength", "volume", "earnings dates", "sector rotation", "volatility", "support and resistance",
          "news sentiment", "valuation", "risk management", "position sizing", "diversification", "dividends", "options", "macro data", "rates"]
system = f"(test run {time.time():.0f}) " + " ".join(
    "You are a careful financial research assistant. Cite the numbers you are given, never invent prices, separate facts from opinion. "
    f"Section {i+1} covers {t}: what it measures, why traders watch it, and its limits." for i, t in enumerate(topics))
for n, q in (("a", "What does RSI above 70 usually suggest?"), ("b", "Why do traders watch volume with price moves?")):
    json.dump({"model": model, "max_tokens": 40, "temperature": 0,
               "messages": [{"role": "system", "content": system}, {"role": "user", "content": q}]}, open(f"{tmp}/{n}.json", "w"))
print(f"  (shared system prompt: {len(system.split())} words)")
PY
hits0=$(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="prefix_hit"')
miss0=$(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="prefix_miss"')
nomatch0=$(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="missing_tokens"')
curl -s -m 5 "$M" | grep -E '^vllm_router_processed_requests_total' > "$tmp/before.txt"
for n in a b; do
  code=$(curl -s -o "$tmp/$n.out" -w '%{http_code} %{time_total}' -m 120 -H "$AUTH" -H 'Content-Type: application/json' "$R/v1/chat/completions" -d @"$tmp/$n.json")
  [[ "${code%% *}" == 200 ]] && ok "request $n -> 200 in ${code#* }s: $(json "$tmp/$n.out" 'd["choices"][0]["message"]["content"].strip()[:50]')" \
                             || bad "request $n -> $code: $(head -c 200 "$tmp/$n.out")"
done
hits=$(( $(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="prefix_hit"') - hits0 ))
miss=$(( $(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="prefix_miss"') - miss0 ))
nomatch=$(( $(metric_sum vllm_router_prefix_routing_decisions_total 'outcome="missing_tokens"') - nomatch0 ))

echo "4. Routing (from $M)"
curl -s -m 5 "$M" | grep -E '^vllm_router_processed_requests_total' > "$tmp/after.txt"
python3 - "$tmp" <<'PY'
import re, sys
def read(p):
    out = {}
    for line in open(p):
        m = re.match(r'^vllm_router_processed_requests_total\{worker="([^"]+)"\}\s+(\S+)', line)
        if m: out[m.group(1)] = float(m.group(2))
    return out
b, a = read(sys.argv[1] + "/before.txt"), read(sys.argv[1] + "/after.txt")
for w in sorted(a):
    print(f"  worker {w:<36} +{int(a[w] - b.get(w, 0))} in this test   ({int(a[w])} since start)")
PY
if [[ "$POLICY" == cache_aware ]]; then
  if [[ $nomatch -gt 0 ]]; then bad "cache_aware couldn't read the prompts ($nomatch x missing_tokens): start the workers with --enable-scale-out"
  elif [[ $hits -ge 1 ]]; then ok "cache_aware: prefix miss $miss, prefix hit $hits - the 2nd request went where its prefix was already cached"
  else bad "cache_aware: expected a prefix hit for the 2nd request (miss $miss, hit $hits)"; fi
else echo "  INFO  policy is $POLICY (prefix matching is only checked with cache_aware)"; fi

echo; echo "Result: $pass passed, $fail failed.   Status: ./status.sh   Stop: ./stop-router.sh"
[[ $fail == 0 ]]
