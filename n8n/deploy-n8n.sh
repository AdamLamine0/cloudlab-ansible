#!/usr/bin/env bash
# deploy-n8n.sh — deploy the n8n provisioning layer onto k3s (.50)
#
# Run ON the kube VM, from a directory containing n8n.yaml.
#
#   ./deploy-n8n.sh                  deploy (generates secrets if absent)
#   ./deploy-n8n.sh --refresh-groq   also re-read the Groq key from Vault
#
# Secret discipline matches deploy.sh:
#   - n8n-encryption : generated ONCE, never rotated on deploy. Rotating
#                      it makes every stored n8n credential unreadable.
#   - n8n-auth       : generated ONCE. Editor UI basic auth.
#   - n8n-groq       : from Vault (cloudlab/groq), opt-in like the OIDC
#                      secret. Only needed so the key can be pasted into
#                      n8n's own credential store; workflows reference it
#                      BY CREDENTIAL NAME, never inline.
set -euo pipefail

KUBECTL=/usr/local/bin/kubectl          # Problem #87
NS=n8n
REFRESH_GROQ=0

for arg in "$@"; do
  case "$arg" in
    --refresh-groq) REFRESH_GROQ=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)"; exit 2 ;;
  esac
done

echo "==> preflight"
[[ -f n8n.yaml ]] || { echo "n8n.yaml not found"; exit 1; }
$KUBECTL apply --dry-run=client -f n8n.yaml >/dev/null || {
  echo "n8n.yaml does not validate — refusing to deploy"; exit 1; }

echo "==> applying namespace/RBAC/workload manifests"
$KUBECTL apply -f n8n.yaml

# --- secrets ---------------------------------------------------------------
if $KUBECTL get secret n8n-encryption -n "$NS" >/dev/null 2>&1; then
  echo "==> reusing existing encryption key (rotating it orphans all credentials)"
else
  echo "==> generating n8n encryption key (once, never again)"
  $KUBECTL create secret generic n8n-encryption -n "$NS" \
    --from-literal=key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
fi

if $KUBECTL get secret n8n-basicauth -n "$NS" >/dev/null 2>&1; then
  echo "==> reusing existing Editor UI credentials"
else
  N8N_PW="$(head -c 18 /dev/urandom | base64 | tr -d '\n/+=' | head -c 20)"
  echo "==> generating Editor UI credentials (enforced by Traefik, not n8n)"
  # Traefik's basicAuth middleware wants an htpasswd-format `users` key.
  # openssl passwd -apr1 is the portable way to make one without htpasswd.
  HASH="$(openssl passwd -apr1 "$N8N_PW")"
  $KUBECTL create secret generic n8n-basicauth -n "$NS" \
    --from-literal=users="admin:${HASH}"
  unset HASH
  echo
  echo "    ============================================================"
  echo "    n8n Editor UI login:  admin / $N8N_PW"
  echo "    SHOWN ONCE AND NOT RECOVERABLE — the Secret stores only a"
  echo "    one-way hash. Write it down now. To reset, delete the Secret"
  echo "    and re-run this script:"
  echo "      kubectl delete secret n8n-basicauth -n n8n && ./deploy-n8n.sh"
  echo
  echo "    Claim n8n's OWN owner account immediately on first visit —"
  echo "    until you do, anyone reaching the UI could claim it."
  echo "    ============================================================"
  echo
  unset N8N_PW
fi

if ! $KUBECTL get secret n8n-groq -n "$NS" >/dev/null 2>&1; then
  REFRESH_GROQ=1
fi

if [[ $REFRESH_GROQ -eq 1 ]]; then
  echo "==> checking Vault is unsealed"
  if $KUBECTL exec -n vault vault-0 -- vault status 2>/dev/null \
       | grep -q '^Sealed  *true'; then
    echo "Vault is SEALED. Unseal it, or re-run without --refresh-groq if"
    echo "the n8n-groq Secret already exists."
    exit 1
  fi
  echo "==> reading Groq API key from Vault (cloudlab/groq)"
  GROQ_KEY="$($KUBECTL exec -n vault vault-0 -- \
              vault kv get -field=api_key cloudlab/groq)"
  [[ -n "$GROQ_KEY" ]] || { echo "empty api_key at cloudlab/groq"; exit 1; }
  $KUBECTL create secret generic n8n-groq -n "$NS" \
    --from-literal=api_key="$GROQ_KEY" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  unset GROQ_KEY
  echo "    NOTE: this Secret exists so the key can be entered into n8n's"
  echo "    OWN encrypted credential store. Workflows must reference that"
  echo "    credential BY NAME. Never inline the key in workflow JSON —"
  echo "    workflow JSON is exportable and would leak it."
fi

echo "==> waiting for rollout"
$KUBECTL rollout status deployment/n8n -n "$NS" --timeout=180s

echo
echo "==> done"
$KUBECTL get pods,svc,ingress,pvc -n "$NS"
echo
echo "Editor UI:  http://n8n.cloudlab.internal/   (needs the DNS record"
echo "            and a Windows hosts entry — see Part 20)"
echo "Logs:       $KUBECTL logs -n $NS deploy/n8n -f"
