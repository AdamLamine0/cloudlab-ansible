#!/usr/bin/env bash
# nomad-label-check.sh - is the Nomad namespace a queryable Prometheus label?
#
# RUN ON THE kube VM. Read-only.
#
# THE QUESTION
#   Nomad jobs carry no owner identity: the job ID is the constant
#   "starter" and there is no Meta block. The ONLY possible join key is
#   the namespace, which is the same string as the Kubernetes namespace
#   (tenant-PROJECT). So per-user Nomad panels are possible if, and only
#   if, that namespace survives as a real Prometheus label on a real
#   allocation series.
#
#   The earlier probe returned "metric not present yet", which is
#   ambiguous between three very different situations:
#
#     A. the metric NAME is different in this Nomad version
#     B. no Nomad allocation is running, so no alloc series exist at all
#     C. the series exist but the label is called something else
#        (Prometheus renames a colliding label to exported_namespace)
#
#   Only C answers the question. A and B mean "ask again with better
#   input", not "no". This distinguishes them.
#
# Usage:
#   ./nomad-label-check.sh                      discover, no assumptions
#   ./nomad-label-check.sh tenant-restaurant-schmitt   also test that exact matcher
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
NS=monitoring
WANT_NS="${1:-}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0
fi

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

POD="$($KUBECTL get pod -n "$NS" -l app.kubernetes.io/name=prometheus \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$POD" ]] || POD="prometheus-monitoring-kube-prometheus-prometheus-0"
note "prometheus pod: $POD"

promq() {
  $KUBECTL exec -n "$NS" "$POD" -c prometheus -- \
    wget -qO- --post-data="query=$1" \
    "http://localhost:9090/api/v1/query" 2>/dev/null || true
}
promget() {
  $KUBECTL exec -n "$NS" "$POD" -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/$1" 2>/dev/null || true
}

# ------------------------------------------------- A: the real metric names
say "A. which nomad allocation metric names actually exist?"
note "From Prometheus, not guessed. Problem #30 is what guessing costs."
promget 'label/__name__/values' | python3 -c '
import json, sys
try:
    names = json.load(sys.stdin)["data"]
except Exception:
    print("      could not read metric names"); raise SystemExit
alloc = sorted(n for n in names if n.startswith("nomad_") and "alloc" in n)
print("      nomad_*alloc* metric names: " + str(len(alloc)))
for n in alloc:
    print("        " + n)
if not alloc:
    print("      NONE. publish_allocation_metrics is probably off on the")
    print("      Nomad agent, even though other nomad_* metrics flow.")
    print("      That is a DIFFERENT gap from the label question.")
'

# --------------------------------------------- B: is anything running at all?
say "B. are there any live allocation series right now?"
note "If no Nomad tenant is running, there are no series to inspect and"
note "the label question CANNOT be answered. That is not a no."
promq 'count({__name__=~"nomad_client_allocs_.*"})' | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("data", {}).get("result", [])
if res:
    print("      live allocation series: " + str(res[0]["value"][1]))
else:
    print("      ZERO allocation series.")
    print("      -> Deploy a Nomad-backed tenant project and run this again.")
    print("         Until something is actually running on Nomad, this")
    print("         question has no answer either way.")
' 2>/dev/null || note "(query failed)"

# ------------------------------------------- C: what labels do they carry?
say "C. the FULL label set on a real allocation series"
note "This is the decisive check. Looking for namespace, or whatever"
note "Prometheus renamed it to."
promq '{__name__=~"nomad_client_allocs_.*"}' | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("data", {}).get("result", [])
if not res:
    print("      no series to inspect (see B)")
    raise SystemExit
print("      sample series (" + str(len(res)) + " total):")
for r in res[:3]:
    m = r["metric"]
    print("        " + m.get("__name__", "?"))
    for k, v in sorted(m.items()):
        if k == "__name__":
            continue
        print("          " + k + " = " + str(v)[:60])
    print("          value = " + str(r.get("value")))
    print("")
keys = set()
for r in res:
    keys.update(r["metric"].keys())
print("      every label seen across all series:")
print("        " + ", ".join(sorted(keys)))
cands = [k for k in keys if "namespace" in k.lower()]
print("")
if cands:
    print("      NAMESPACE-LIKE LABELS PRESENT: " + ", ".join(sorted(cands)))
    vals = sorted({r["metric"].get(cands[0], "") for r in res} - {""})
    print("      distinct values of " + cands[0] + ":")
    for v in vals[:12]:
        print("        " + v)
    print("")
    print("      -> A join is possible. Use " + cands[0] + " as the key.")
else:
    print("      NO namespace-like label on any allocation series.")
    print("      -> Per-user Nomad filtering is NOT possible without a")
    print("         job-spec change (adding Meta to the Nomad job), which")
    print("         is a separate task. Do not extend the dashboard.")
'

# --------------------------------------------- D: the exact matcher, if given
if [[ -n "$WANT_NS" ]]; then
  say "D. the exact query you asked about"
  for LBL in namespace exported_namespace; do
    for M in nomad_client_allocs_cpu_total_percent nomad_client_allocs_memory_rss; do
      Q="${M}{${LBL}=\"${WANT_NS}\"}"
      printf '    %-64s ' "$Q"
      promq "$Q" | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("data", {}).get("result", [])
if res:
    print("-> " + str(len(res)) + " series, first value=" + str(res[0]["value"][1]))
else:
    print("-> no data")
' 2>/dev/null || echo "-> query failed"
    done
  done
  note ""
  note "A line with real series and a value is a definitive YES."
  note "All four showing no data, while section C listed a namespace-like"
  note "label, means the metric name is wrong - use the names from A."
fi

say "done - nothing was changed"
