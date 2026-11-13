# Roadmap: Kubernetes, upgrades and open items

Notes for moving this router from a laptop to GKE, and for upgrading it later. Nothing here is built or tested yet,
unless it says so. Today's setup (Docker on one machine, `workers.txt`) is described in the [README](../README.md).

## 1. Kubernetes (GKE)

```
gateway ──▶ Service vllm-router:30000 ──▶ router pods (Deployment, 1-2 replicas)
                                              │  service discovery (pod labels)
                                              ├──▶ vLLM pod  app=vllm-qwen  (replica 1)
                                              └──▶ vLLM pod  app=vllm-qwen  (replica 2) ...
Prometheus ──▶ :29000/metrics on the router pods
```

**Router**
- A `Deployment` (1-2 replicas) and a `Service` on port 30000, using the same image as here (`Dockerfile`), pushed
  to the team's registry (e.g. Artifact Registry) with the version as its tag.
- **No `workers.txt`:** the router finds vLLM pods itself and follows them as they scale, crash or restart:
  `--service-discovery --selector app=vllm-qwen --service-discovery-port 8000 --service-discovery-namespace <ns>`.
  The router's ServiceAccount needs RBAC to `get` / `list` / `watch` pods in that namespace.
- Same flags as `start-router.sh`: `--host 0.0.0.0 --port 30000 --prometheus-host 0.0.0.0 --prometheus-port 29000
  --policy cache_aware`.
- **API key from a `Secret`** (env var -> `--api-key`), not `router.env`.
- Readiness / liveness probes on the router's `/health`.
- Metrics: let Prometheus scrape port 29000 (annotations or a `PodMonitor`).
- No GPU needed: put it on the default CPU node pool, not the GPU pool.

**vLLM pods**
- Started with **`--enable-scale-out`** (the router tokenizes prompts through vLLM's render endpoint; without it
  `cache_aware` can't match prefixes - see the README).
- The **same API key** as the router (same `Secret`).
- One label per model (e.g. `app=vllm-qwen`): every pod behind one router selector must serve the same model.
  Several models -> one selector (or one router) per model.
- The `k8s/` manifests in github.com/helloravisha/vllm-serving are the starting point.

**Gateway**
- The model's `base_url` in the gateway's Model Registry becomes the router's Service:
  `http://vllm-router.<ns>.svc.cluster.local:30000/v1`.

**To decide when we get there:** one router per model or one shared router; router replicas (the cache-aware prefix
tree lives in each router's memory, so 2+ router replicas each learn their own); TLS / network policy between gateway,
router and vLLM.

## 2. Upgrading the router

The version is pinned: `ROUTER_IMAGE=vllm-router:0.1.17` in `router.env`, `VLLM_ROUTER_VERSION` in `Dockerfile`.

1. Read the release notes of the new version (PyPI `vllm-router`, GitHub `vllm-project/router`).
2. Build it alongside the old one: `ROUTER_IMAGE=vllm-router:<new> ./setup.sh`.
3. Start it and test: `ROUTER_IMAGE=vllm-router:<new> ./start-router.sh && ./test-router.sh` (must pass 6/6).
4. Re-check the known limits (below) - a newer router or vLLM may fix them:
   `curl -s -H "Authorization: Bearer dummy" http://127.0.0.1:30000/workers` (is `model_id` still `unknown`? is
   `load` still `-1`?).
5. Check `--help` for renamed or removed flags used in `start-router.sh`.
6. Update the version in `router.env` and `Dockerfile`, and the "Tested" section of the README.

**When upgrading vLLM:** re-run `./test-router.sh`. The router depends on vLLM's `/v1/chat/completions/render`
(with `--enable-scale-out`), `/health` and `/v1/models`.

## 3. Open items

| Item | Why | Status |
|---|---|---|
| Load balancing with vLLM workers | The router asks workers for `/get_load` (SGLang); vLLM has no such endpoint (404), so `cache_aware` can't balance by load and sends un-cached prompts to the first worker | Open: re-check on upgrades; meanwhile `round_robin` / `power_of_two` spread evenly |
| `model_id: "unknown"` per worker | The router doesn't learn the model name from vLLM | Open; harmless while every worker serves the same model |
| Mac: keep the router running | Today it's a container you start by hand | Optional: `--restart unless-stopped` |
| Gateway through the router | Point the gateway's vLLM `base_url` at the router and re-run its tool-plan / synthesize / fallback tests | Next |
| Kubernetes manifests | Section 1 above | When testing on GKE |
