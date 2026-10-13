#!/usr/bin/env bash
set -euo pipefail

# Halogen Flash Server launcher for GMKtec EVO-X2 / Strix Halo
# Downloads weights (if missing) and starts the server with Docker + vision support.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${SCRIPT_DIR}/models"
IMAGE="ghcr.io/peonist-ai/halogen-flash-server:0.18.1"
PORT="8000"      # host port to publish
API_PORT="8731"  # container-side API port (image env HALOGEN_API_PORT; engine uses 8730 internally, loopback-only)
MAX_THINKING_TOKENS="8192"
CONTAINER_NAME="halogen-qwen3.8-flash-next"

echo "=== Halogen Flash Server ==="
echo "Models directory: ${MODELS_DIR}"
echo

# Ensure models directory exists
mkdir -p "${MODELS_DIR}"

# Download weights with uv (includes vision tower)
echo "Downloading / verifying model weights..."
uv run --with "huggingface_hub[cli]" hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir "${MODELS_DIR}"
echo "Download complete."
echo

# Resolve GPU group GIDs numerically from the host device nodes.
# Docker Engine 29 resolves --group-add *names* against the image's /etc/group
# (which lacks host groups like 'render') and fails with:
#   "Unable to find group render: no matching entries in group file"
# Passing numeric GIDs sidesteps the name lookup entirely.
GPU_GIDS=""
for dev in /dev/kfd /dev/dri/card* /dev/dri/renderD*; do
  if [[ -e "${dev}" ]]; then
    gid="$(stat -c '%g' "${dev}")"
    [[ " ${GPU_GIDS} " == *" ${gid} "* ]] || GPU_GIDS="${GPU_GIDS:+${GPU_GIDS} }${gid}"
  fi
done
echo "GPU device group GIDs: ${GPU_GIDS:-none found}"

# Fail fast on fragmented host memory: the engine reserves large contiguous
# chunks and can die after the slow weight-pinning step when the buddy
# allocator has too few 2 MiB blocks (order-9) free.
order9="$(awk '/zone Normal/{s+=$14} END{print s+0}' /proc/buddyinfo)"
if (( order9 < 5000 )); then
  echo "WARNING: only ${order9} contiguous 2 MiB blocks free (want thousands). The"
  echo "  kernel usually recovers these on its own within seconds; only if the engine"
  echo "  then dies at 'reserving the KV pool', as root run:"
  echo "    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'"
fi

GPU_GROUP_ADDS=()
for gid in ${GPU_GIDS}; do
  GPU_GROUP_ADDS+=(--group-add "${gid}")
done

# Start the container (Docker) with vision + max thinking tokens
echo "Starting Halogen Flash Server on port ${PORT} (vision enabled, max thinking ${MAX_THINKING_TOKENS})..."
exec docker run --rm -p "${PORT}:${API_PORT}" \
  --name "${CONTAINER_NAME}" \
  --device /dev/kfd --device /dev/dri \
  "${GPU_GROUP_ADDS[@]}" \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_VISION_TOWER=1 \
  -e HALOGEN_MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS}" \
  -v "${MODELS_DIR}:/models:ro" \
  "${IMAGE}"

