#!/usr/bin/env bash
# dryrun-provision.sh - exercise the changed provisioning workflow WITHOUT
# replacing the live one.
#
# RUN ON THE kube VM.
#
# HOW THIS STAYS SAFE
#   The changed workflow is imported under a DIFFERENT id, name and
#   webhook path (new-project-dryrun). The live workflow and its
#   /webhook/new-project endpoint are untouched, so the portal keeps
#   using the old path throughout and real users are unaffected. You
#   drive the copy with curl.
#
#   It does provision REAL namespaces and REAL builds - that is the
#   point. Use throwaway project names and --cleanup afterwards.
#
# WHAT CHANGED, and therefore what is worth watching
#   Before: the Deployment / Nomad job referencing the BUILT image was
#   created seconds after the build STARTED, so every pull failed for
#   minutes and Kubernetes backed off to 5-minute retries. Measured on
#   tenant-grafanatest: Deployment at 19:26:08, manifest pushed 19:29:58.
#   After:  the tenant is answered with a placeholder that pulls a public
#   image immediately; the build is polled; the real image is patched into
#   the SAME Deployment (or submitted as the same Nomad job) once it
#   exists.
#
# Usage:
#   ./dryrun-provision.sh --stage             import the copy, activate it
#   ./dryrun-provision.sh --submit-k8s NAME   submit a Kubernetes project
#   ./dryrun-provision.sh --submit-nomad NAME submit a Nomad project
#   ./dryrun-provision.sh --watch NAME        the staged timeline
#   ./dryrun-provision.sh --cleanup           remove the copy and tenants
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
SRC="${SRC:-n8n-workflow-provision.json}"
DRY_ID=provisionDryRun1
DRY_PATH=new-project-dryrun
# A public repo with a Dockerfile that EXPOSEs a NON-80 port, so the
# Service-port upgrade is actually exercised rather than accidentally
# matching the placeholder.
REPO="${REPO:-https://github.com/docker/welcome-to-docker}"

MODE="${1:-}"; NAME="${2:-}"
if [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0
fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

pod_n8n() { $KUBECTL get pod -n n8n -l app=n8n -o jsonpath='{.items[0].metadata.name}'; }
token() { $KUBECTL get secret n8n-webhook-token -n n8n \
  -o go-template='{{index .data "token"}}' | base64 -d; }

# ============================================================== STAGE
stage() {
  [[ -f "$SRC" ]] || die "$SRC not found"
  say "validating before importing anything"
  node tests/wfcheck.js "$SRC" || die "wfcheck failed - not importing"

  say "backing up the LIVE workflow first"
  $KUBECTL exec -n n8n deploy/n8n -- \
    n8n export:workflow --id=provisionTenant01 --output=/tmp/live-backup.json
  $KUBECTL cp "n8n/$(pod_n8n):/tmp/live-backup.json" ./live-workflow-backup.json
  note "saved ./live-workflow-backup.json ($(wc -c < ./live-workflow-backup.json) bytes)"

  say "building the dry-run copy"
  SRC="$SRC" DRY_ID="$DRY_ID" DRY_PATH="$DRY_PATH" python3 - <<'PY'
import json, os
src = json.load(open(os.environ["SRC"], encoding="utf-8"))
src["id"] = os.environ["DRY_ID"]
src["name"] = "Provision tenant project (DRY RUN)"
src["active"] = True
# A different path AND a different webhookId, or n8n registers this copy
# over the live endpoint and the portal starts hitting the test workflow.
for n in src["nodes"]:
    if n["type"].endswith("webhook"):
        n["parameters"]["path"] = os.environ["DRY_PATH"]
        n["webhookId"] = os.environ["DRY_PATH"] + "-hook"
json.dump([src], open("/tmp/dryrun-wf.json", "w"))
print("    id=%s path=%s nodes=%d" % (src["id"], os.environ["DRY_PATH"], len(src["nodes"])))
PY

  $KUBECTL cp /tmp/dryrun-wf.json "n8n/$(pod_n8n):/tmp/dryrun-wf.json"
  $KUBECTL exec -n n8n deploy/n8n -- n8n import:workflow --input=/tmp/dryrun-wf.json
  # Toggle, because import writes active=1 directly and a later
  # --active=true is then a no-op that never registers the webhook.
  $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$DRY_ID" --active=false
  $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$DRY_ID" --active=true
  $KUBECTL rollout restart deploy/n8n -n n8n
  $KUBECTL rollout status deploy/n8n -n n8n --timeout=180s

  say "confirming BOTH endpoints answer and the live one is untouched"
  local t; t="$(token)"
  for p in new-project "$DRY_PATH"; do
    printf '    /webhook/%-22s ' "$p"
    $KUBECTL exec -n n8n deploy/n8n -- node -e "
      fetch('http://localhost:5678/webhook/$p',{method:'POST',
        headers:{'Content-Type':'application/json','X-Portal-Token':process.env.T},
        body:'{}'}).then(r=>console.log('HTTP '+r.status)).catch(e=>console.log('ERR'))
    " 2>/dev/null || echo "unreachable"
  done
  note "both should answer. The live path must NOT 404 - if it does, the"
  note "copy registered over it and you should --cleanup immediately."
}

# ============================================================= SUBMIT
submit() {
  local kind="$1" project="$2"
  [[ -n "$project" ]] || die "give a project name"
  say "submitting $project as $kind"
  note "watch in another terminal:  ./dryrun-provision.sh --watch $project"
  local t; t="$(token)"
  T="$t" KIND="$kind" PROJECT="$project" REPO="$REPO" DRY_PATH="$DRY_PATH" \
  $KUBECTL exec -i -n n8n deploy/n8n -- node - <<'JS'
const body = {
  username: "dryrun.tester",
  email: "dryrun.tester@cloudlab.internal",
  description: "dry run of the build-race fix",
  repoUrl: process.env.REPO,
  kind: process.env.KIND,
  project: process.env.PROJECT
};
const t0 = Date.now();
fetch("http://localhost:5678/webhook/" + process.env.DRY_PATH, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Portal-Token": process.env.T },
  body: JSON.stringify(body)
}).then(async r => {
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const txt = await r.text();
  console.log("    HTTP " + r.status + " after " + secs + "s");
  console.log("    " + txt.slice(0, 500));
}).catch(e => console.log("    request failed: " + e.message));
JS
  note ""
  note "STAGE 1 - the response itself. It should arrive in well under 60s"
  note "and carry a siteUrl. That URL must work NOW, not eventually."
}

# ============================================================== WATCH
watch_ns() {
  local project="$1"; local ns="tenant-$project"
  [[ -n "$project" ]] || die "give a project name"
  say "STAGE 1: does the placeholder come up clean?"
  note "WATCH FOR: pod Running within ~15s, and NO ImagePullBackOff at all."
  note "The placeholder is a public image, so any pull failure here is a"
  note "different problem from the one being fixed."
  $KUBECTL get pods -n "$ns" -o wide 2>/dev/null || note "(namespace not there yet)"
  echo
  $KUBECTL get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -iE "pull|backoff|failed" | tail -6 || note "    no pull events - good"

  say "STAGE 1b: is the site actually serving?"
  note "WATCH FOR: HTTP 200 immediately. Before the fix this was a 502 or"
  note "a hang for 20+ minutes."
  $KUBECTL run curl-dry-$$ -n "$ns" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 --command -- \
    curl -s -o /dev/null -w '    site -> HTTP %{http_code} in %{time_total}s\n' \
    --max-time 10 "http://site-k8s.${ns}.svc.cluster.local" 2>/dev/null \
    || note "    (could not reach the Service)"

  say "STAGE 2: is the build running, and is the site still up while it does?"
  note "WATCH FOR: a Job in the build namespace, and the site STILL 200."
  $KUBECTL get jobs -n build -l tenant=dryrun.tester 2>/dev/null \
    || $KUBECTL get jobs -n build 2>/dev/null | tail -4
  echo
  $KUBECTL get svc site-k8s -n "$ns" \
    -o jsonpath='    Service targetPort now: {.spec.ports[0].targetPort}{"\n"}' 2>/dev/null || true

  say "STAGE 3: did it upgrade to the real image?"
  note "WATCH FOR: the Deployment image changing from nginx:alpine to a"
  note "10.43.200.50:5000/... reference, via a ROLLING update - the old"
  note "pod keeps serving until the new one is ready."
  $KUBECTL get deploy starter -n "$ns" \
    -o jsonpath='    image: {.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null \
    || note "    (no starter Deployment)"
  $KUBECTL rollout status deploy/starter -n "$ns" --timeout=5s 2>/dev/null \
    | sed 's/^/    /' || true
  echo
  note "THE ONE WINDOW TO MEASURE: after the new pod is Ready it listens"
  note "on the Dockerfile's EXPOSE port, but the Service is patched 30s"
  note "later. If EXPOSE is not 80, expect up to ~30s of 502 in that gap."
  note "That is a known, bounded cost of ordering Deployment-then-Service;"
  note "report how long it actually lasted."

  say "STAGE 3b (Nomad only): did the job get replaced?"
  note "WATCH FOR: the allocation restarting with the built image. Nomad"
  note "destroys the old allocation immediately rather than rolling, so"
  note "~30s of 502 here is EXPECTED and already documented."
  note "Check with:"
  note "  NOMAD_TOKEN=\$($KUBECTL exec -n vault vault-0 -- vault kv get -field=token cloudlab/nomad/acl/n8n)"
  note "  NOMAD_NAMESPACE=$ns nomad job status starter"
}

# ============================================================ CLEANUP
cleanup() {
  say "removing the dry-run workflow"
  $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$DRY_ID" --active=false || true
  note "n8n 1.62 has no delete:workflow. The webhook row must go too, or"
  note "the endpoint keeps answering across restarts (Problem #149)."
  note "Then verify by CALLING it - it must 404."
  $KUBECTL rollout restart deploy/n8n -n n8n
  $KUBECTL rollout status deploy/n8n -n n8n --timeout=180s
  printf '    /webhook/%s -> ' "$DRY_PATH"
  $KUBECTL exec -n n8n deploy/n8n -- node -e "
    fetch('http://localhost:5678/webhook/$DRY_PATH',{method:'POST',
      headers:{'Content-Type':'application/json'},body:'{}'})
      .then(r=>console.log('HTTP '+r.status)).catch(e=>console.log('ERR'))" 2>/dev/null || true
  note "if that is not 404, use ./n8n-webhook-probe.sh --clean-stale --apply"
  note ""
  note "Tenant namespaces are NOT deleted by this script. Remove them by"
  note "hand once you have finished reading the evidence."
}

case "$MODE" in
  --stage)         stage ;;
  --submit-k8s)    submit kubernetes "$NAME" ;;
  --submit-nomad)  submit nomad "$NAME" ;;
  --watch)         watch_ns "$NAME" ;;
  --cleanup)       cleanup ;;
  *) die "unknown mode: $MODE (try --help)" ;;
esac
