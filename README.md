# vllm-router

Runs [vllm-router](https://pypi.org/project/vllm-router/) (the vLLM project's Rust load balancer) in front of one or
more **vLLM servers**, so clients use **one address** (`http://127.0.0.1:30000/v1`) instead of one port per server.
Self-contained: needs only Docker, the vLLM servers, `curl` and `python3`. No gateway required.

```
client ──▶ router :30000 ──┬──▶ vLLM :8000  (Qwen2.5-1.5B, replica 1)
   (curl, an app,          └──▶ vLLM :8010  (Qwen2.5-1.5B, replica 2)
    the LLM gateway)
           metrics :29000
```

## Quick start

Everything is described in **`stack.txt`**: which model, how many replicas, which routing policy, which ports.

```
model: Qwen/Qwen2.5-1.5B-Instruct     # a served-model-name from vllm-serving's configs
replicas: 2                           # vLLM copies: ports 8000, 8010, ... (the config's port, +10, ...)
policy: cache_aware                   # the other policies are listed in the file, commented out, one line each
router_port: 30000                    # clients and the LLM gateway connect here
metrics_port: 29000                   # Prometheus metrics
```

```bash
./setup.sh           # once: build the router image (~1 min). Needs vllm-serving cloned and set up
                     # (default ~/vllm-serving; set VLLM_SERVING_DIR in router.env)
# edit stack.txt
./start-stack.sh     # starts the replicas (with --enable-scale-out), waits until they answer, starts the router (~20 s)
./test-router.sh     # PASS / FAIL with curl
./status.sh          # workers and how requests were routed
./stop-stack.sh      # stops the router and the replicas start-stack.sh started (others are left alone)
```

To change model, replicas or policy: `./stop-stack.sh`, edit `stack.txt`, `./start-stack.sh`. For a single run an
environment variable overrides a line: `POLICY=round_robin ./start-stack.sh`. A replica port that already serves the
model is reused; a mistyped model name lists the available ones. Replica logs: `logs/vllm-<port>.log`.

`router.env` holds what rarely changes: the API key, the router image version, where vllm-serving is.

## Router only (vLLM already running elsewhere)

Use this instead of `start-stack.sh` when the vLLM servers are started some other way (another machine, Docker, by
hand). List them in `workers.txt` - all must serve the **same model** (`start-router.sh` refuses mixed models):

```bash
./setup.sh                 # build the router image (once; ~1 min)
# start the vLLM servers - e.g. with github.com/helloravisha/vllm-serving (note --enable-scale-out):
#   ./serve.sh configs/mac/qwen2.5-1.5b.yaml --enable-scale-out
#   ./serve.sh configs/mac/qwen2.5-1.5b.yaml --port 8010 --enable-scale-out
vi workers.txt             # one vLLM URL per line (http://127.0.0.1:8000, ...)
./start-router.sh          # checks every worker, starts the router, waits until it answers
./test-router.sh           # end-to-end test with curl: PASS / FAIL per step
./status.sh                # workers and how requests were routed
./stop-router.sh           # stop the router (the vLLM servers keep running)
```

Ports and policy still come from `stack.txt`. Addresses can also be given directly:
`./start-router.sh http://127.0.0.1:8000 http://127.0.0.1:8010`.

## Requirements

- **Docker.** vllm-router publishes Linux builds only (x86_64, arm64), so it runs in a container on a Mac too.
  It needs no GPU; the vLLM servers keep theirs.
- **vLLM servers that serve the same model.** The router doesn't route by model name: every worker gets any request.
- **The workers' API key** in `router.env` (`VLLM_API_KEY`, default `dummy`). Clients send the same key to the router
  (`Authorization: Bearer dummy`); without it the router answers 401.
- **For `cache_aware` (the default), start each vLLM server with `--enable-scale-out`.** The router tokenizes prompts
  through vLLM's `/v1/chat/completions/render` endpoint, which vLLM only offers with that flag (otherwise 403, and the
  router falls back to routing without prefix matching). `start-router.sh` checks this and warns.

`start-router.sh` rewrites `localhost` / `127.0.0.1` worker URLs to `host.docker.internal` (inside the container,
localhost is the container itself) and adds `--add-host=host.docker.internal:host-gateway` so this also works on Linux.

## Try it by hand (curl)

```bash
K="Authorization: Bearer dummy"
curl -s -H "$K" http://127.0.0.1:30000/v1/models
curl -s -H "$K" -H 'Content-Type: application/json' http://127.0.0.1:30000/v1/chat/completions \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","max_tokens":30,"messages":[{"role":"user","content":"Hi"}]}'
curl -s -H "$K" http://127.0.0.1:30000/workers                      # workers and health
curl -s http://127.0.0.1:29000/metrics | grep -E 'processed_requests_total|prefix_routing_decisions_total'
```

## Policies

| Policy | Picks the worker by |
|---|---|
| `cache_aware` (default) | the longest cached prompt prefix (faster, cheaper for shared system prompts / conversations) |
| `round_robin` | taking turns |
| `power_of_two` | the less busy of two random workers |
| `random`, `consistent_hash`, `sticky_least_loaded`, `kv_aware` | see `docker run --rm vllm-router:0.1.17 --help` |

## Tested (Mac, vLLM 0.32.0, vllm-router 0.1.17, 2 x Qwen2.5-1.5B-Instruct)

- `test-router.sh`: 6/6 pass. A shared ~550-word system prompt: request 1 `prefix_miss`, request 2 `prefix_hit`,
  both on the same worker.
- `round_robin`: 4 requests split 2 / 2 across the workers.
- **A replica dies:** killed :8010 during 12 requests (`round_robin`): all 12 returned 200 in ~0.2 s - the router
  retried the 8 sends that hit the dead replica on :8000 (`vllm_router_retries_total`). Its health metric only notices
  after the next health check (every 60 s); the retries are what protect requests.
- **Behind the LLM gateway:** with the model's `base_url` at `http://localhost:30000/v1`, gateway `/tool-plan` calls go
  through the router (3.0 s -> 2.1 s -> 1.9 s as the long prompt got cached), and with Ollama stopped the gateway's
  fallback was answered by vLLM through the router.

**Known limits with vLLM workers (vllm-router 0.1.17):**
- The router asks workers for their load at `/get_load` - an SGLang endpoint vLLM doesn't have (404) - so it reports
  `load: -1` and can't balance by load. With `cache_aware`, a prompt with **no** cached prefix goes to the first
  worker, so at low traffic most requests land on one replica. Prefix hits work as intended. If you need an even
  spread, use `round_robin` or `power_of_two`.
- Workers show `model_id: "unknown"` in `/workers`; harmless while all workers serve the same model.

## Using it behind the LLM gateway (optional)

Point the vLLM model's `base_url` in the gateway's Model Registry at the router: `http://127.0.0.1:30000/v1`.
The gateway then sends that model's calls through the router; nothing else changes.

## Next: Kubernetes and upgrades

Plans for GKE (service discovery instead of `workers.txt`, Secrets, metrics), the upgrade checklist and open items:
[docs/ROADMAP.md](docs/ROADMAP.md).

## Files

```
setup.sh          build the router image
stack.txt         what to run: model, replicas, policy, ports
start-stack.sh    vLLM replicas (via vllm-serving) + router, one command, from stack.txt
stop-stack.sh     stop the router and the replicas start-stack.sh started
router.env        API key, image version, where vllm-serving is (rarely changed)
workers.txt       vLLM servers for start-router.sh when they run elsewhere
start-router.sh   check workers, start the router (Docker), wait until ready; log in logs/router.log
test-router.sh    end-to-end test with curl (PASS / FAIL)
status.sh         router, workers, routing counts
stop-router.sh    stop the router
Dockerfile        python:3.12-slim + vllm-router
docs/ROADMAP.md   Kubernetes plan, upgrade checklist, open items
```
