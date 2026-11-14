# vllm-router

One address (`http://127.0.0.1:30000/v1`) in front of several vLLM servers running the same model, using
[vllm-router](https://pypi.org/project/vllm-router/). Needs Docker, [vllm-serving](https://github.com/helloravisha/vllm-serving),
`curl` and `python3` - no gateway required.

## How to run

1. **Once:** install vLLM and build the router
   ```bash
   (cd ~/vllm-serving && ./setup.sh)     # vLLM - skip if already done
   ./setup.sh                            # the router image (~1 min)
   ```
2. **Say what to run** in `stack.txt`
   ```
   model: Qwen/Qwen2.5-1.5B-Instruct
   replicas: 2
   policy: cache_aware
   ```
3. **Start everything** (vLLM replicas + router, ~20 s)
   ```bash
   ./start-stack.sh
   ```
4. **Test it**
   ```bash
   ./test-router.sh                      # PASS / FAIL
   ```
5. **Stop everything**
   ```bash
   ./stop-stack.sh
   ```

To change model, replicas or policy: stop, edit `stack.txt`, start again. `./status.sh` shows the workers and how
requests were routed at any time.

---

## More details

### stack.txt

| Line | Meaning |
|---|---|
| `model:` | a `served-model-name` from vllm-serving's `configs/mac/` (`configs/nvidia/` on Linux); a wrong name lists the available ones |
| `replicas:` | how many vLLM copies; ports are the config's port, then +10, +20 (8000, 8010, ...). On a Mac 2-3 is a sensible maximum |
| `policy:` | how the router picks a replica; the other choices are in the file, commented out, one line each |
| `router_port:` | where clients and the gateway connect (default 30000) |
| `metrics_port:` | Prometheus metrics (default 29000) |

An environment variable overrides a line for one run: `POLICY=round_robin ./start-stack.sh`.
`router.env` holds what rarely changes: the API key (`dummy`), the router image version, where vllm-serving is.

### Calling the router (curl)

```bash
K="Authorization: Bearer dummy"           # the vLLM servers' API key; the router needs it too
curl -s -H "$K" http://127.0.0.1:30000/v1/models
curl -s -H "$K" -H 'Content-Type: application/json' http://127.0.0.1:30000/v1/chat/completions \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","max_tokens":30,"messages":[{"role":"user","content":"Hi"}]}'
curl -s http://127.0.0.1:29000/metrics | grep -E 'processed_requests_total|prefix_routing_decisions_total'
```

**Always send `"model"`, even through the router.** The router only picks a replica and forwards the request body
unchanged; the vLLM replica checks `"model"` against the model it serves (a wrong name gets 404 "model does not
exist"). Use the exact `model:` from `stack.txt` - `/v1/models` above shows it. Apps that call the LLM gateway
instead don't need this: the gateway fills in `"model"` from its registry.

### Using it behind the LLM gateway

Set the model's `base_url` on the gateway's Model Registry page to `http://localhost:30000/v1`. Nothing else changes.

### Router only (vLLM already running elsewhere)

List the servers in `workers.txt` (all must serve the same model), then `./start-router.sh`, `./test-router.sh`,
`./stop-router.sh`. Start those servers with `--enable-scale-out` for `cache_aware`.

### Good to know

- **`cache_aware` needs `--enable-scale-out` on vLLM** (the router reads prompts through vLLM's render endpoint).
  `start-stack.sh` adds it; `start-router.sh` warns when it's missing.
- **A prompt with nothing cached goes to the first replica:** the router can't read load from vLLM (it asks
  `/get_load`, which vLLM doesn't have). Cache hits work. For an even spread use `policy: round_robin`.
- The router runs in Docker because it publishes Linux builds only; it needs no GPU.

### Tested (Mac, vLLM 0.32.0, vllm-router 0.1.17, 2 x Qwen2.5-1.5B-Instruct)

- `test-router.sh` 6/6; shared long prompt: miss, then hit on the same replica.
- `round_robin`: even 2 / 2 split.
- A replica killed during 12 requests: all 12 answered (the router retried on the other replica).
- Behind the LLM gateway: `/tool-plan` through the router (3.0 s -> 1.9 s as the prompt got cached), and gateway
  fallback to vLLM through the router when Ollama was down.

### Files

```
stack.txt         what to run: model, replicas, policy, ports
start-stack.sh    start replicas + router         stop-stack.sh    stop them
test-router.sh    end-to-end test (curl)          status.sh        workers and routing counts
setup.sh          build the router image          Dockerfile       the image
router.env        API key, image version, vllm-serving location
start-router.sh / stop-router.sh / workers.txt   router only, for vLLM started elsewhere
docs/ROADMAP.md   Kubernetes plan, upgrade checklist, open items
```
