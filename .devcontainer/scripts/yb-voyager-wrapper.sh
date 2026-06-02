#!/usr/bin/env bash
# yb-voyager devcontainer wrapper.
#
# Key behaviours:
#   1. Normalises --export-dir to an absolute path (relative paths cause
#      confusing failures because the CWD differs between the shell and
#      the Docker container).
#   2. Creates the export-dir in THIS devcontainer process (mkdir -p) before
#      docker run, so --volumes-from sees it already populated.
#   3. Uses --net container:DC_ID to share the devcontainer's network namespace
#      (YugabyteDB on 127.0.0.1:5433, source DB by container name).
#   4. Uses --volumes-from DC_ID to inherit the workspace bind-mount as-is,
#      avoiding DooD bind-path translation issues on macOS.
#   5. Adds --platform linux/amd64 on arm64 hosts (yb-voyager is amd64-only).

set -euo pipefail

# ── 1. Fix Docker socket permissions ─────────────────────────────────────────
[ -S /var/run/docker.sock ] && sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# ── 2. Find Docker CLI via absolute path (bypasses bash PATH-cache misses) ────
DOCKER=""
for candidate in /usr/bin/docker /usr/local/bin/docker; do
    if [ -x "$candidate" ]; then DOCKER="$candidate"; break; fi
done
if [ -z "$DOCKER" ]; then
    echo "[yb-voyager] Docker CLI not found — downloading static binary..." >&2
    ARCH=$(uname -m)
    sudo curl -fsSL \
        "https://download.docker.com/linux/static/stable/${ARCH}/docker-24.0.7.tgz" \
        | sudo tar xz -C /usr/local/bin --strip-components=1 docker/docker
    DOCKER=/usr/local/bin/docker
fi

# ── 3. Workspace root (for resolving relative paths) ─────────────────────────
WS_ROOT=$(git rev-parse --show-toplevel 2>/dev/null \
          || echo "/workspaces/ybdb-vanguard")

# ── 4. Normalise args: make --export-dir absolute, mkdir it here ──────────────
# Doing mkdir in this (devcontainer) process ensures the directory exists on
# the bind-mounted filesystem before --volumes-from shares it with the container.
args=("$@")
for i in "${!args[@]}"; do
    case "${args[$i]}" in
        --export-dir|-e|--backup-dir|--archive-dir)
            j=$(( i + 1 ))
            dir="${args[$j]:-}"
            if [[ -n "$dir" && "$dir" != /* ]]; then
                # Relative path → make absolute from workspace root
                args[$j]="${WS_ROOT}/${dir}"
                echo "[yb-voyager] Resolved relative --export-dir: ${dir} → ${args[$j]}" >&2
            fi
            # Ensure the directory exists before the container checks it
            mkdir -p "${args[$j]}" 2>/dev/null || true
            ;;
    esac
done

# ── 5. Get devcontainer container ID ─────────────────────────────────────────
DC_ID=$(grep -oE '/docker/[0-9a-f]+' /proc/1/cpuset 2>/dev/null \
        | head -1 | cut -d/ -f3 || hostname)

# ── 6. Platform flag ──────────────────────────────────────────────────────────
PLATFORM_FLAG=()
[ "$(uname -m)" != "x86_64" ] && PLATFORM_FLAG=("--platform" "linux/amd64")

# ── 7. TTY flag ───────────────────────────────────────────────────────────────
TTY_FLAG=()
[ -t 1 ] && TTY_FLAG=("-it")

# ── 8. Run yb-voyager ─────────────────────────────────────────────────────────
exec "$DOCKER" run --rm \
    "${TTY_FLAG[@]}" \
    "${PLATFORM_FLAG[@]}" \
    --net "container:${DC_ID}" \
    --volumes-from "${DC_ID}" \
    -e "SOURCE_DB_PASSWORD=${SRC_SECRET:-}" \
    -e "TARGET_DB_PASSWORD=${TARGET_SECRET:-}" \
    -e "YB_VOYAGER_SEND_DIAGNOSTICS=${YB_VOYAGER_SEND_DIAGNOSTICS:-false}" \
    -w "${WS_ROOT}" \
    yugabytedb/yb-voyager:latest \
    yb-voyager "${args[@]}"
