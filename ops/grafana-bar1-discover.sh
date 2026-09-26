#!/usr/bin/env bash
# grafana-bar1-discover.sh - find the REAL metric names before writing a
# dashboard that depends on them.
#
# RUN ON THE kube VM. Completely read-only.
#
# WHY THIS EXISTS
#   Problem #30: a Grafana panel shipped with the guessed metric name
#   `nomad_nomad_leader`, which does not exist in this Nomad version, and
#   the panel showed "No data". Guessing metric names is a mistake this
#   codebase has already made and written down.
#
#   A per-user dashboard needs three things this repo has NO record of:
#     1. whether kube-state-metrics exposes the namespace `owner` label
#        (it does NOT by default - it needs --metric-labels-allowlist),
#     2. the real Nomad allocation CPU/memory metric names in THIS version,
#     3. whether anything on the Nomad side carries the owner/project
#        identity at all, which is what the filter would key on.
#
#   Without 1, the Kubernetes half cannot filter by user. Without 2 and 3,
#   the Nomad half cannot be written at all. Answer these first.
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
NS=monitoring

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0
fi
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

POD="$($KUBECTL get pod -n "$NS" -l app.kubernetes.io/name=prometheus \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$POD" ]] || POD="prometheus-monitoring-kube-prometheus-prometheus-0"
note "prometheus pod: $POD"

# Query Prometheus from inside its own pod, so no port-forward is needed.
promq() {
  $KUBECTL exec -n "$NS" "$POD" -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/$1" 2>/dev/null || true
}

say "1. does kube-state-metrics expose the namespace 'owner' label?"
note "This is the join key for the whole Kubernetes half. kube-state-metrics"
note "v2 does NOT expose arbitrary object labels unless started with"
note "--metric-labels-allowlist=namespaces=[owner,project]."
out="$(promq 'query?query=kube_namespace_labels')"
if printf '%s' "$out" | grep -q 'label_owner'; then
  note "YES - label_owner is present. The join can work:"
  printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("data",{}).get("result",[])[:8]:
    m=r["metric"]
    print("      namespace=" + m.get("namespace","?") +
          "  label_owner=" + m.get("label_owner","(absent)") +
          "  label_project=" + m.get("label_project","(absent)"))' 2>/dev/null || true
else
  note "NO - kube_namespace_labels carries no label_owner."
  note "The dashboard CANNOT filter Kubernetes usage by user until"
  note "kube-state-metrics is restarted with:"
  note "    --metric-labels-allowlist=namespaces=[owner,project]"
  note "That is a values change + restart, not a dashboard change."
  printf '%s' "$out" | head -c 300 | sed 's/^/      /'
fi

say "2. which Nomad allocation metrics actually exist here?"
note "Not guessed. These are the names Prometheus is really storing."
promq 'label/__name__/values' | python3 -c '
import json,sys
try: names=json.load(sys.stdin)["data"]
except Exception: names=[]
nomad=[n for n in names if n.startswith("nomad_")]
alloc=[n for n in nomad if "alloc" in n]
cpu=[n for n in alloc if "cpu" in n]
mem=[n for n in alloc if "memory" in n or "rss" in n]
print(f"      nomad_* metrics present: {len(nomad)}")
print(f"      alloc-scoped           : {len(alloc)}")
for label, xs in (("CPU", cpu), ("MEMORY", mem)):
    print(f"      {label}:")
    for n in sorted(xs)[:10]:
        print("        " + n)
    if not xs:
        print("        (NONE - the Nomad half cannot be written)")
' 2>/dev/null || note "(could not read metric names)"

say "3. do Nomad metrics carry any owner/project identity?"
note "A filter needs a label tying an allocation to a platform user."
for m in nomad_client_allocs_cpu_total_percent nomad_client_allocs_memory_rss; do
  r="$(promq "query?query=$m")"
  if printf '%s' "$r" | grep -q '"result":\[\]'; then
    note "$m -> no series"
  elif printf '%s' "$r" | grep -q '"result"'; then
    note "$m -> labels on the first series:"
    printf '%s' "$r" | python3 -c '
import json,sys
d=json.load(sys.stdin)
res=d.get("data",{}).get("result",[])
if res:
    for k,v in sorted(res[0]["metric"].items()):
        print("        " + k + " = " + str(v)[:50])
else:
    print("        (no series)")' 2>/dev/null || true
  else
    note "$m -> not present"
  fi
done

say "4. Grafana version, and whether Explore can be limited per role"
$KUBECTL exec -n "$NS" deploy/monitoring-grafana -c grafana -- \
  grafana-server -v 2>/dev/null | sed 's/^/    /' || \
  $KUBECTL get deploy monitoring-grafana -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' | sed 's/^/    image: /'
note "Per-ROLE Explore control is Grafana Enterprise (RBAC). In OSS the"
note "only lever is [explore] enabled, which is GLOBAL - it would remove"
note "Explore from admin too. See the report for what that does and does"
note "not buy."

say "5. is there live tenant data to check a filter against?"
$KUBECTL get ns -l owner --show-labels --no-headers 2>/dev/null \
  | awk '{print "    " $1 "  " $NF}' | head -10 \
  || note "(no namespaces carry an owner label)"

say "done - nothing was changed"
