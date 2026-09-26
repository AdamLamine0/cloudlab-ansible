#!/usr/bin/env bash
# deploy.sh — deploy signup-portal onto k3s (.50)
#
# Run ON the kube VM, from a directory containing app.py and
# signup-portal.yaml.
#
#   ./deploy.sh                    code-only deploy (the common case)
#   ./deploy.sh --refresh-secret   also re-fetch svc-portal's password
#                                  from Vault and update the Secret
#   ./deploy.sh --help
#
# WHY THE SPLIT (Problem #109, and the reason deploy-novault.sh existed):
# fetching the password on every deploy coupled every code change to
# Vault's seal state, and `vault-0` reseals on every pod restart. Worse,
# it meant each deploy OVERWROTE a known-working Secret with Vault's
# copy — and `svc-portal`'s Vault value has drifted out of sync twice
# already (Problem #99). A code change has no business touching a
# credential, so by default it no longer does.
#
# Note on what is NOT automated here: this script cannot tell whether
# the stored credential is stale, because answering that requires
# reading Vault, which is the seal-dependent step being avoided. The
# refresh is therefore an explicit decision, not a detected one. Reach
# for --refresh-secret when the credential itself changed (a rotation,
# a re-sync after Problem #99) or when the Secret does not exist yet.
#
# Assumes:
#   - svc-portal's password is at cloudlab/svc-portal in Vault
#     (only read with --refresh-secret, or when the Secret is missing)
#   - FreeIPA CA cert exists at /root/dex-setup/freeipa-ca.crt
set -euo pipefail

KUBECTL=/usr/local/bin/kubectl          # absolute path, per Problem #87
CA_SRC=/root/dex-setup/freeipa-ca.crt
NS=signup
SECRET=signup-portal-ipa

REFRESH_SECRET=0
for arg in "$@"; do
  case "$arg" in
    --refresh-secret) REFRESH_SECRET=1 ;;
    -h|--help)
      awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"
      exit 0 ;;
    *) echo "unknown argument: $arg (try --help)"; exit 2 ;;
  esac
done

echo "==> preflight"
[[ -f app.py ]]              || { echo "app.py not found"; exit 1; }
[[ -f signup-portal.yaml ]]  || { echo "signup-portal.yaml not found"; exit 1; }
for a in bg-aurora.png tt-logo.png tt-mark.png; do
  [[ -f "assets/$a" ]] || { echo "assets/$a not found"; exit 1; }
done
[[ -f "$CA_SRC" ]]           || { echo "CA cert not at $CA_SRC"; exit 1; }

# Catch a syntax error here rather than in a CrashLoopBackOff: the code
# ships as a ConfigMap, so nothing else validates it before it runs.
python3 -c 'import ast,sys; ast.parse(open("app.py").read())' || {
  echo "app.py does not parse — refusing to deploy"; exit 1; }

echo "==> applying namespace"
$KUBECTL apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: signup
  labels:
    name: signup
    tier: platform
EOF

# --- the credential -------------------------------------------------------
# Default: leave it alone. Only read Vault when explicitly asked, or when
# there is genuinely no Secret to reuse.
if $KUBECTL get secret "$SECRET" -n "$NS" >/dev/null 2>&1; then
  SECRET_EXISTS=1
else
  SECRET_EXISTS=0
fi

if [[ $SECRET_EXISTS -eq 0 ]]; then
  echo "==> Secret $SECRET not found — a Vault fetch is required"
  REFRESH_SECRET=1
fi

# Session HMAC key. NOT from Vault, deliberately: it must be creatable
# during a code-only deploy, and it is not a shared credential — it only
# has to be secret and STABLE. Generated once and never regenerated,
# because rotating it silently logs every user out.
if $KUBECTL get secret signup-portal-session -n "$NS" >/dev/null 2>&1; then
  echo "==> reusing existing session key (rotating it logs everyone out)"
else
  echo "==> no session key yet — generating one"
  $KUBECTL create secret generic signup-portal-session -n "$NS" \
    --from-literal=key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
fi

# The Dex client secret lives in Vault, so it follows the same opt-in
# rule as the FreeIPA password: only read on --refresh-secret, or when
# there is no Secret to reuse.
if ! $KUBECTL get secret signup-portal-oidc -n "$NS" >/dev/null 2>&1; then
  echo "==> Secret signup-portal-oidc not found — a Vault fetch is required"
  REFRESH_SECRET=1
fi

if [[ $REFRESH_SECRET -eq 1 ]]; then
  echo "==> checking Vault is unsealed"
  if $KUBECTL exec -n vault vault-0 -- vault status 2>/dev/null \
       | grep -q '^Sealed  *true'; then
    echo
    echo "Vault is SEALED, so the password cannot be fetched."
    if [[ $SECRET_EXISTS -eq 1 ]]; then
      echo "The existing $SECRET Secret is still in place, so if this is"
      echo "a code-only change, re-run WITHOUT --refresh-secret."
    else
      echo "There is no existing Secret to fall back on — unseal Vault:"
      echo "  $KUBECTL exec -n vault vault-0 -- vault operator unseal"
      echo "  (one command at a time, 3 of 5 keys — Problems #101/#102)"
    fi
    exit 1
  fi

  echo "==> fetching svc-portal password from Vault"
  IPA_PW="$($KUBECTL exec -n vault vault-0 -- \
            vault kv get -field=password cloudlab/svc-portal)"
  [[ -n "$IPA_PW" ]] || { echo "empty password from Vault"; exit 1; }

  echo "==> creating/updating svc-portal Secret"
  $KUBECTL create secret generic "$SECRET" -n "$NS" \
    --from-literal=password="$IPA_PW" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  unset IPA_PW

  echo "==> fetching signup-portal OIDC client secret from Vault"
  OIDC_SECRET="$($KUBECTL exec -n vault vault-0 -- \
                 vault kv get -field=client_secret cloudlab/signup-portal-oidc)"
  [[ -n "$OIDC_SECRET" ]] || {
    echo "empty client_secret from Vault at cloudlab/signup-portal-oidc"; exit 1; }
  $KUBECTL create secret generic signup-portal-oidc -n "$NS" \
    --from-literal=client_secret="$OIDC_SECRET" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  unset OIDC_SECRET
  echo "    NOTE: this must match the client secret Dex is running with."
  echo "    If login starts failing with 'invalid_client', re-run"
  echo "    /root/dex-setup/deploy-dex.sh so both sides read the same"
  echo "    Vault value."
else
  echo "==> reusing existing $SECRET Secret (no Vault read)"
  echo "    pass --refresh-secret to re-fetch the credential"
fi

# The console's shared secret for n8n's webhook. Copied from the n8n
# namespace rather than generated, because BOTH ends must agree and n8n
# owns the original. Not from Vault: it is an internal handshake between
# two of our own pods, not a stored credential.
if $KUBECTL get secret n8n-webhook-token -n n8n >/dev/null 2>&1; then
  WT="$($KUBECTL get secret n8n-webhook-token -n n8n \
        -o jsonpath='{.data.token}' | base64 -d)"
  if [[ -n "$WT" ]]; then
    $KUBECTL create secret generic console-n8n -n "$NS" \
      --from-literal=token="$WT" \
      --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
    echo "==> console-n8n Secret synced from the n8n namespace"
  fi
  unset WT
else
  echo "!! n8n-webhook-token not found in namespace n8n."
  echo "   The console will refuse to start without it. Deploy n8n first"
  echo "   (/root/n8n-setup/deploy-n8n.sh)."
  exit 1
fi

echo "==> creating/updating FreeIPA CA ConfigMap"
$KUBECTL create configmap signup-portal-ca -n "$NS" \
  --from-file=freeipa-ca.crt="$CA_SRC" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> building the code+assets ConfigMap"
# app.py and the three page images ride in ONE ConfigMap, mounted at /app.
# `kubectl create configmap --from-file` puts the text under `data` and
# the PNGs under `binaryData` by itself, which is why this is generated
# rather than hand-written: ~270KB of inline base64 in signup-portal.yaml
# would be undiffable and trivial to corrupt.
#
# TWO SEPARATE LIMITS apply here, and the tighter one is not the famous
# one:
#
#   1MiB   the ConfigMap object itself. We are at ~379KB, well under.
#   256KB  metadata.annotations, TOTAL, per object. Client-side
#          `kubectl apply` stores a full copy of the object in the
#          `kubectl.kubernetes.io/last-applied-configuration` annotation,
#          so a 379KB ConfigMap blows the annotation limit even though
#          the object is legal. That is the failure this script hit:
#          `metadata.annotations: Too long: may not be more than 262144
#          bytes`, with the 1MiB check passing cleanly just above it.
#
# The fix is SERVER-SIDE APPLY, which tracks ownership in `managedFields`
# and never writes that annotation. The size check below therefore still
# measures the 1MiB budget, which is a real ceiling for the assets; it is
# just not what failed.
#
# `--dry-run=client -o yaml` lets us measure the rendered object before
# sending it, so an oversize payload fails here with a clear message
# instead of being rejected by the API server.
$KUBECTL create configmap signup-portal-code -n "$NS" \
  --from-file=app.py \
  --from-file=assets/bg-aurora.png \
  --from-file=assets/tt-logo.png \
  --from-file=assets/tt-mark.png \
  --dry-run=client -o yaml > /tmp/signup-portal-code.yaml

CM_BYTES=$(wc -c < /tmp/signup-portal-code.yaml)
echo "    ConfigMap object: $CM_BYTES bytes (object limit 1048576; annotation limit 262144, not hit: server-side apply)"
if [[ "$CM_BYTES" -gt 1048576 ]]; then
  echo "    ConfigMap exceeds the 1MiB limit and would be REFUSED."
  echo "    Shrink assets/ before deploying."
  exit 1
fi
# SERVER-SIDE, for this ConfigMap only. See the note above: client-side
# apply cannot carry an object this size, because it copies the whole
# thing into an annotation capped at 256KB.
#
# --force-conflicts is needed for the FIRST server-side apply of an
# object that was previously applied client-side: its fields are still
# owned by the synthetic `before-first-apply` manager, and SSA reports a
# conflict rather than silently taking them. deploy.sh is the only thing
# that ever writes this ConfigMap, so taking ownership is correct here
# and not a way of ignoring a real disagreement.
$KUBECTL apply --server-side --force-conflicts \
  --field-manager=deploy.sh \
  -f /tmp/signup-portal-code.yaml

# Belt and braces. kubectl should drop the stale last-applied annotation
# when it migrates the object to server-side apply, but if it does not,
# what is left behind is a ~100KB copy of a PREVIOUS app.py, which is
# both misleading to read and dead weight. Removing it is idempotent and
# must never fail the deploy, hence the `|| true`.
$KUBECTL annotate configmap signup-portal-code -n "$NS" \
  kubectl.kubernetes.io/last-applied-configuration- >/dev/null 2>&1 || true

echo "==> applying signup-portal"
$KUBECTL apply -f signup-portal.yaml

echo "==> restarting BOTH halves to pick up any code change"
# One ConfigMap feeds both deployments, so a code change must roll both.
for d in signup-portal console; do
  $KUBECTL rollout restart deployment/$d -n "$NS"
done
for d in signup-portal console; do
  $KUBECTL rollout status deployment/$d -n "$NS" --timeout=120s
done

echo
echo "==> done"
$KUBECTL get pods,svc,ingress -n "$NS"
echo
echo "Logs:  $KUBECTL logs -n $NS deploy/signup-portal -f"
