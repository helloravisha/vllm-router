#!/usr/bin/env bash
# Builds the router image. vllm-router ships Linux builds only (x86_64 and arm64), so it runs in Docker
# on a Mac; on Linux the same image works (or: pip install vllm-router into a venv).
set -euo pipefail
cd "$(dirname "$0")"
source ./router.env
command -v docker >/dev/null || { echo "Docker is required: https://docs.docker.com/get-docker/" >&2; exit 1; }
version="${ROUTER_IMAGE##*:}"
docker build -t "$ROUTER_IMAGE" --build-arg "VLLM_ROUTER_VERSION=$version" .
echo "Built $ROUTER_IMAGE. Next: list your vLLM servers in $WORKERS_FILE, then ./start-router.sh"
