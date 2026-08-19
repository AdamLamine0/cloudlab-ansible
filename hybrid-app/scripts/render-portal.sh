#!/usr/bin/env bash
# Render the tenant-agnostic portal manifest for one tenant.
#
#   ./render-portal.sh user1 > /tmp/portal-user1.yaml
#   kubectl apply -f /tmp/portal-user1.yaml
#
# Writes to stdout only. Nothing is applied here on purpose — this is
# the artifact the CI/CD phase will later apply on its own.
set -euo pipefail

TENANT="${1:-}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/k8s/portal.yaml"

case "$TENANT" in
  user1) PROBE_PORT=28001; OTHER=user2 ;;
  user2) PROBE_PORT=28002; OTHER=user1 ;;
  *)
    echo "usage: $(basename "$0") <user1|user2>" >&2
    echo "  (ports are assigned per tenant: user1=28001, user2=28002)" >&2
    exit 2
    ;;
esac

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

sed -e "s/__TENANT__/${TENANT}/g" \
    -e "s/__OTHER_TENANT__/${OTHER}/g" \
    -e "s/__PROBE_PORT__/${PROBE_PORT}/g" \
    "$SRC"
