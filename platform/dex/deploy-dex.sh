#!/usr/bin/env bash
# deploy-dex.sh — deploy Dex with every secret injected from Vault.
#
# NOTHING secret lives in values.yaml. Both the LDAP bindPW and the
# signup-portal OIDC client secret are placeholders there and are
# replaced at deploy time from Vault.
#
# Requires Vault UNSEALED. vault-0 reseals on every restart (including a
# host reboot, which shows up as a SandboxChanged event and a pod that is
# Running 0/1 with a failing readiness probe — that is a SEALED vault,
# not a crashing one).
set -euo pipefail

VAULT_NS=vault
PORTAL_CLIENT_INDEX=2      # see the warning below
GRAFANA_CLIENT_INDEX=$(python3 -c "
import re,sys
s=open('/root/dex-setup/values.yaml').read()
ids=re.findall(r'^\s*-\s*id:\s*(\S+)', s[s.index('staticClients:'):], re.M)
print(ids.index('grafana'))")
ACTUAL_GRAFANA=$(python3 -c "
import re
s=open('/root/dex-setup/values.yaml').read()
ids=re.findall(r'^\s*-\s*id:\s*(\S+)', s[s.index('staticClients:'):], re.M)
print(ids[$GRAFANA_CLIENT_INDEX])")
[ "$ACTUAL_GRAFANA" = "grafana" ] || { echo "grafana index moved"; exit 1; }
GRAFANA_SECRET=$(kubectl exec -n vault vault-0 -- \
  vault kv get -field=client_secret cloudlab/grafana-oidc)

echo "=== Fetching dex-bind password from Vault ==="
BIND_PW=$(kubectl exec -n $VAULT_NS vault-0 -- \
          vault kv get -field=password cloudlab/dex-bind)

if [ -z "$BIND_PW" ]; then
  echo "!! Failed to read secret from Vault. Is vault-0 unsealed? (kubectl get pods -n vault)"
  exit 1
fi

echo "=== Fetching signup-portal OIDC client secret from Vault ==="
PORTAL_SECRET=$(kubectl exec -n $VAULT_NS vault-0 -- \
                vault kv get -field=client_secret cloudlab/signup-portal-oidc)

if [ -z "$PORTAL_SECRET" ]; then
  echo "!! Failed to read cloudlab/signup-portal-oidc from Vault."
  echo "   Is vault-0 unsealed, and does that path exist?"
  exit 1
fi

# ---------------------------------------------------------------------
# WARNING — POSITIONAL INDEX, NOT A NAME.
#
# `--set-string config.staticClients[N].secret=...` targets the client by
# its POSITION in values.yaml, not by its id. Helm gives no way to select
# a list element by field value.
#
# So if anyone reorders, inserts, or removes a client in values.yaml's
# staticClients list WITHOUT updating PORTAL_CLIENT_INDEX above, this
# script will silently overwrite the WRONG client's secret. The most
# likely damage: writing the portal's secret over `nomad`'s, which breaks
# `nomad login` for every tenant with no error at deploy time — it fails
# later, at login, looking like a Nomad problem.
#
# The guard below verifies that position really is signup-portal before
# deploying. Keep it. If it ever fails, fix the index rather than
# deleting the check.
# ---------------------------------------------------------------------
ACTUAL_ID=$(awk '/^  - id:/{n++; if (n=='"$((PORTAL_CLIENT_INDEX+1))"') {print $3; exit}}' \
            /root/dex-setup/values.yaml)
if [ "$ACTUAL_ID" != "signup-portal" ]; then
  echo "!! staticClients[$PORTAL_CLIENT_INDEX] is '$ACTUAL_ID', not 'signup-portal'."
  echo "   The client list in values.yaml changed. Update PORTAL_CLIENT_INDEX"
  echo "   in this script to match, then re-run. Refusing to deploy: this"
  echo "   would otherwise overwrite the wrong client's secret."
  exit 1
fi
echo "    index guard OK: staticClients[$PORTAL_CLIENT_INDEX] is signup-portal"

echo "=== Deploying Dex with secrets from Vault (not from any file) ==="
helm upgrade dex dex/dex -n dex \
  -f /root/dex-setup/values.yaml \
  --set-string "config.connectors[0].config.bindPW=${BIND_PW}" \
  --set-string "config.staticClients[${PORTAL_CLIENT_INDEX}].secret=${PORTAL_SECRET}" \
  --set-string "config.staticClients[$GRAFANA_CLIENT_INDEX].secret=${GRAFANA_SECRET}"

echo "=== Waiting for Dex to come back healthy ==="
kubectl rollout status deployment/dex -n dex --timeout=120s

echo "=== Done. bindPW and the portal client secret both came from Vault. ==="
