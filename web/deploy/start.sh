#!/bin/sh
# Run on Ubuntu from the staged web directory. Never touches database mounts or volumes.
set -eu
cd "$(dirname "$0")/.."
test -f dist/index.html
test -f compose.yaml
if ! command -v docker >/dev/null || ! command -v tailscale >/dev/null; then
    echo 'Docker and Tailscale must already be installed.' >&2
    exit 1
fi
# Refuse to replace another service already registered at Tailscale HTTPS port 443.
serve_config=$(tailscale serve status --json)
case "$serve_config" in
  *'"443"'*)
    echo 'Tailscale already has a service on port 443. Review its configuration before deploying.' >&2
    exit 1
    ;;
esac
sudo docker compose -p sync-task-web config --quiet
sudo docker compose -p sync-task-web build web
sudo docker compose -p sync-task-web up -d --no-deps web
attempt=0
until curl --fail --silent --output /dev/null http://127.0.0.1:8081/; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 15 ]; then
        echo 'Web service did not start. Check: sudo docker compose -p sync-task-web logs --tail=50 web' >&2
        exit 1
    fi
    sleep 2
done
sudo tailscale serve --bg --https=443 http://127.0.0.1:8081
tailscale serve status
printf '\nWeb app started. PocketBase and AI containers and their volumes were not modified.\n'
