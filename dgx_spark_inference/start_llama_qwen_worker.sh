#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$HOME/llama-stack"
MODEL_DIR="$ROOT/models"
MOUNT="/models"                       # container-side root of the bind mount

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
IMAGE="${IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda}"

MODEL_FILE="${MODEL_FILE:-qwen3.5-35b-a3b-q6k.gguf}"   # filename only; host vs container roots differ below
ALIAS="${ALIAS:-qwen-worker}"                            # served API id; must equal models.yml key

[[ -f "$MODEL_DIR/$MODEL_FILE" ]] || {
    echo "Missing model on host: $MODEL_DIR/$MODEL_FILE" >&2; ls -l "$MODEL_DIR" >&2; exit 1; }

docker info >/dev/null 2>&1 || { echo "Docker is unavailable" >&2; exit 1; }

docker rm -f llama-stack >/dev/null 2>&1 || true

# Direct mode: one model, loaded at startup. No router flags (--models-preset /
# --models-autoload / --models-max are router-only and abort this binary), no models.ini bind.
ARGS=(
    --host "$HOST"
    --port 8080
    --model "$MOUNT/$MODEL_FILE"      # container path, not $MODEL_DIR
    --alias "$ALIAS"
    --n-gpu-layers 999
    --flash-attn on
    --cache-type-k q8_0
    --cache-type-v q8_0
    --batch-size 2048
    --ubatch-size 512
    --temperature 0.3
    --top-p 0.9
    --ctx-size 65536
    --parallel 2          # direct mode reserved 4 slots; 65536 x 4 = ~27 GB, x1 = ~6.8 GB
    --cache-reuse 512
)

docker run -d \
    --name llama-stack \
    --restart unless-stopped \
    --gpus all \
    --ipc=host \
    -p "$PORT:8080" \
    --mount "type=bind,src=$MODEL_DIR,dst=$MOUNT,readonly" \
    "$IMAGE" \
    "${ARGS[@]}"

BASE="http://localhost:$PORT"

ready() { curl -fsS -m 10 "$BASE/health" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; }
alive() { docker exec llama-stack true >/dev/null 2>&1; }

echo "Waiting for $MOUNT/$MODEL_FILE to load ..."
for _ in {1..240}; do
    ready && break
    alive || { echo "START FAILED: llama-server exited before serving (see docker logs -f llama-stack)" >&2; exit 1; }
    echo "loading .."; sleep 5s
done
ready || { echo "START FAILED: /health never returned ok" >&2; exit 1; }

# First inference after load is cold (measured 40.8 s vs 1.4-4.9 s warm); pay it here.
curl -fsS -m 300 -o /dev/null "$BASE/v1/chat/completions" -H 'Content-Type: application/json' \
     -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"warm\"}],\"max_tokens\":1}" \
  || { echo "WARMUP FAILED: first inference" >&2; exit 1; }

curl -fsS "$BASE/v1/models" |
  jq -r '.data[] | "served id: \(.id)  n_ctx=\(.meta.n_ctx // "n/a")  ftype=\(.meta.ftype // "n/a")  size=\(.meta.size // "n/a")"'

echo "llama.cpp server started (direct, no router)"
echo "API:    http://localhost:$PORT/v1"
echo "Health: http://localhost:$PORT/health"
echo "Logs:   docker logs -f llama-stack"

