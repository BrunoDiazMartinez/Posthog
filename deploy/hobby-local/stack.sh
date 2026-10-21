#!/usr/bin/env bash
# Prod-like PostHog hobby stack, runnable locally (Docker Desktop / Linux / macOS).
#
# Reproduces what bin/deploy-hobby does, without apt/sudo/telemetry:
#   stack/posthog                  -> checkout of THIS repo (committed HEAD, LF endings)
#   stack/docker-compose.yml       -> docker-compose.hobby.yml (unmodified)
#   stack/.env, compose/, share/   -> same files the installer writes
#
# Usage: deploy/hobby-local/stack.sh <setup|up|down|logs|status|sync|reset> [args]
#   DOMAIN=localhost (default)  -> Caddy serves https://localhost with its internal CA
#   POSTHOG_APP_TAG=latest      -> pin to a real tag/commit for reproducible tests
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$HERE/stack"
DC=(docker compose --project-name posthog-hobby-local --project-directory "$STACK" -f "$STACK/docker-compose.yml" -f "$STACK/docker-compose.local.yml")

cmd_setup() {
    mkdir -p "$STACK/compose" "$STACK/share"

    # Repo checkout the compose file expects at ./posthog (mounts + rust build contexts).
    # core.autocrlf=false + core.eol=lf (autocrlf alone is not enough with `* text=auto`) so files bind-mounted into Linux containers keep LF endings.
    if [ ! -e "$STACK/posthog/.git" ]; then
        git -C "$REPO" -c core.autocrlf=false -c core.eol=lf -c core.longpaths=true \
            worktree add --detach "$STACK/posthog" HEAD
    fi

    cp "$STACK/posthog/docker-compose.base.yml" "$STACK/docker-compose.base.yml"
    cp "$STACK/posthog/docker-compose.hobby.yml" "$STACK/docker-compose.yml"
    cp "$STACK/posthog/.env.services" "$STACK/.env.services"

    # Host-only tweaks, kept out of the prod compose. temporal-ui (admin UI) moves off 8081,
    # which Windows security agents (e.g. macmnsvc.exe) commonly hold.
    cat > "$STACK/docker-compose.local.yml" <<'LOCAL'
services:
    temporal-ui:
        ports: !override
            - '127.0.0.1:18081:8080'
LOCAL

    # Generated once; regenerating would invalidate encrypted data (same rule as the installer).
    if [ -f "$STACK/.env" ]; then
        echo "Existing .env found, preserving it"
    else
        cat > "$STACK/.env" <<ENV
POSTHOG_SECRET=$(openssl rand -hex 28)
ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)
BROWSERLESS_SECRET=$(openssl rand -hex 32)
INTERNAL_REQUEST_TOKEN=$(openssl rand -hex 32)
DOMAIN=${DOMAIN:-localhost}
TLS_BLOCK=
REGISTRY_URL=${REGISTRY_URL:-posthog/posthog}
CADDY_TLS_BLOCK=
CADDY_HOST="${DOMAIN:-localhost}, http://, https://"
POSTHOG_APP_TAG=${POSTHOG_APP_TAG:-latest}
ENV
        [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> "$STACK/.env"
        [ -n "${OPENAI_API_KEY:-}" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$STACK/.env"
    fi

    # Entrypoint scripts mounted at /compose (copied verbatim from bin/deploy-hobby).
    printf '#!/bin/bash\n./compose/wait\n./bin/migrate\n./bin/docker-server\n' > "$STACK/compose/start"
    printf '#!/bin/bash\n./bin/temporal-django-worker\n' > "$STACK/compose/temporal-django-worker"
    cat > "$STACK/compose/wait" <<'WAIT'
#!/usr/bin/env python3

import socket
import time

def loop():
    print("Waiting for ClickHouse and Postgres to be ready")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('clickhouse', 9000))
        print("Clickhouse is ready")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('db', 5432))
        print("Postgres is ready")
    except ConnectionRefusedError as e:
        time.sleep(5)
        loop()

loop()
WAIT
    chmod +x "$STACK/compose/"*

    if [ ! -f "$STACK/share/GeoLite2-City.mmdb" ]; then
        echo "Downloading GeoIP database"
        curl -fL 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > "$STACK/share/GeoLite2-City.mmdb"
        echo "{\"date\": \"$(date +%Y-%m-%d)\"}" > "$STACK/share/GeoLite2-City.json"
    fi
    echo "Setup done. Next: $0 up"
}

cmd_up() {
    [ -f "$STACK/.env" ] || cmd_setup
    # Same flags as the installer: pull published images, never build locally.
    # Retried like the installer: large image pulls occasionally die with "unexpected EOF".
    for attempt in 1 2 3; do
        "${DC[@]}" up -d --no-build --pull always && break
        [ "$attempt" -lt 3 ] || { echo "Failed to start stack after 3 attempts" >&2; exit 1; }
        echo "Attempt $attempt failed, retrying in 30s..."; sleep 30
    done
    local url="https://$(grep '^DOMAIN=' "$STACK/.env" | cut -d= -f2)"
    echo "Waiting for $url/_health (first boot: ~5-10 min for migrations)"
    for _ in $(seq 1 120); do
        [ "$(curl -sk -o /dev/null -w '%{http_code}' "$url/_health")" = 200 ] && { echo "UP: $url"; return; }
        sleep 5
    done
    echo "Timed out. Inspect with: $0 logs web" >&2
    exit 1
}

# Pull committed repo changes into the stack's checkout and refresh the copied compose files.
cmd_sync() {
    git -C "$STACK/posthog" -c core.autocrlf=false -c core.eol=lf checkout --detach "$(git -C "$REPO" rev-parse HEAD)"
    cp "$STACK/posthog/docker-compose.base.yml" "$STACK/docker-compose.base.yml"
    cp "$STACK/posthog/docker-compose.hobby.yml" "$STACK/docker-compose.yml"
    cp "$STACK/posthog/.env.services" "$STACK/.env.services"
}

case "${1:-}" in
    setup)  cmd_setup ;;
    up)     cmd_up ;;
    down)   "${DC[@]}" stop ;;
    logs)   shift; "${DC[@]}" logs -f --tail 100 "$@" ;;
    status) "${DC[@]}" ps ;;
    sync)   cmd_sync ;;
    reset)  # DESTRUCTIVE: removes containers AND data volumes
        read -r -p "Delete all containers and data volumes? [y/N] " a
        [ "$a" = y ] && "${DC[@]}" down -v ;;
    *) sed -n 2,13p "$0"; exit 1 ;;
esac
