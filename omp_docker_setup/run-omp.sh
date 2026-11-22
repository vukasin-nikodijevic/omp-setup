#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
PROJECT="$(pwd -P)"
OMP_HOME="${HOME}/.omp"
IMAGE="${IMAGE:-omp-sandbox:local}"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.omp-sandbox"

# Rebuild the sandbox image only when BUILD_OMP=1
if [[ "${BUILD_OMP:-0}" == "1" ]]; then
    if [[ ! -f "$DOCKERFILE" ]]; then
        echo "Missing Dockerfile: $DOCKERFILE" >&2
        exit 1
    fi
    echo "Building $IMAGE from $DOCKERFILE..."
    docker build --no-cache --pull -t "$IMAGE" -f "$DOCKERFILE" "$SCRIPT_DIR"
fi

# Ensure image exists before trying to run
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image '$IMAGE' not found locally. Run with BUILD_OMP=1 first." >&2
    exit 1
fi

mkdir -p "$OMP_HOME"

# Prevent accidentally mounting $HOME or / as workspace
if [[ "$PROJECT" == "$HOME" || "$PROJECT" == "/" ]]; then
    echo "Refusing to mount $PROJECT as /workspace. Run inside a specific project directory." >&2
    exit 1
fi

exec docker run --rm -it \
  --read-only \
  --user "$(id -u):$(id -g)" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=512 \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=4g \
  --tmpfs /home/agent:rw,exec,nosuid,nodev,size=4g,uid=$(id -u),gid=$(id -g) \
  --mount "type=bind,src=${PROJECT},dst=/workspace" \
  --mount "type=bind,src=${OMP_HOME},dst=/home/agent/.omp" \
  --workdir /workspace \
  -e HOME=/home/agent \
  -e PATH="/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  "$IMAGE" "$@"

