# vllm-router (Rust load balancer for vLLM) in a small Linux image. It ships Linux builds only
# (x86_64 and arm64), so this runs the same on a Mac (Docker), Linux and Kubernetes.
FROM python:3.12-slim
ARG VLLM_ROUTER_VERSION=0.1.17
RUN pip install --no-cache-dir "vllm-router==${VLLM_ROUTER_VERSION}"
ENTRYPOINT ["vllm-router"]
