#!/usr/bin/env bash
# nomad-metrics-discover.sh - why are there no nomad_* metrics?
#
# RUN ON THE kube VM. Completely read-only. Nothing is configured,
# restarted, or applied.
#
# THERE IS A CONTRADICTION TO RESOLVE FIRST
#   grafana-bar1-discover.sh reported ZERO nomad_* metrics in Prometheus.
#   But the handoff records BOTH a working scrape job (Part 11,
#   `job_name: nomad` against 192.168.1.51:4646) AND working Nomad
#   dashboards, including the panel fixed in Problem #30 to use
#   `nomad_raft_leader_oldestLogAge`.
#
#   Those cannot both be true now. Either something regressed, or the
#   earlier measurement was wrong. Layer 0 below settles that before
#   anything else, because "add a scrape config" would be the wrong fix
#   for a scrape config that already exists and has stopped working.
#
# THE FOUR LAYERS, checked in order, cheapest first:
#   0. Is there really nothing? Re-ask Prometheus directly.
#   1. Does the Nomad AGENT have telemetry enabled? Read the LIVE agent
#      config via /v1/agent/self, not a file on disk.
#   2. Is Prometheus scraping it, and is that target UP?
#   3. Does the endpoint itself return real metrics right now?
#   4. Do Nomad allocations carry any OWNER identity to filter on?
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
NS=monitoring
NOMAD="${NOMAD_ADDR:-http://192.168.1.51:4646}"

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
    wget -qO- "http://localhost:9090/api/v1/$1" 2>/dev/null || true
}

# ============================================================== LAYER 0
say "0. is there really nothing? asking Prometheus directly"
promq 'label/__name__/values' | python3 -c '
import json, sys
try:
    names = json.load(sys.stdin)["data"]
except Exception:
    print("      could not read metric names at all"); raise SystemExit
nomad = sorted(n for n in names if n.startswith("nomad_"))
print("      total metric names in Prometheus: " + str(len(names)))
print("      nomad_* names:                    " + str(len(nomad)))
for n in nomad[:25]:
    print("        " + n)
if len(nomad) > 25:
    print("        ... and " + str(len(nomad) - 25) + " more")
if not nomad:
    print("      CONFIRMED: no nomad_* metrics. Continue to layer 1.")
else:
    print("      The earlier zero-metric reading was WRONG, or this just")
    print("      recovered. Nomad metrics ARE present. Skip to layer 4.")
'

say "0b. the metric Problem #30 fixed - does it have data right now?"
promq 'query?query=nomad_raft_leader_oldestLogAge' | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("data", {}).get("result", [])
if res:
    for r in res[:3]:
        print("      " + json.dumps(r.get("metric", {})) + "  value=" + str(r.get("value")))
    print("      -> the Nomad scrape IS working. The gap is elsewhere.")
else:
    print("      no series. Consistent with the scrape being broken or off.")
' 2>/dev/null || note "(query failed)"

# ============================================================== LAYER 1
say "1. does the Nomad AGENT have telemetry enabled?"
note "Read from the LIVE agent, not a config file. A file on disk may not"
note "be what the running agent loaded."
$KUBECTL run nomad-probe-$$ -n "$NS" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s --max-time 10 "$NOMAD/v1/agent/self" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("      could not read /v1/agent/self (ACLs? unreachable?)")
    raise SystemExit
tel = (d.get("config") or {}).get("Telemetry") or {}
if not tel:
    print("      NO Telemetry stanza in the running agent config.")
    print("      -> THIS IS THE ROOT CAUSE. Nothing downstream matters.")
else:
    for k in sorted(tel):
        if "prometheus" in k.lower() or "disable" in k.lower() or "interval" in k.lower():
            print("        " + k + " = " + json.dumps(tel[k]))
    pm = tel.get("PrometheusMetrics")
    if pm:
        print("      -> prometheus_metrics is ON. Continue to layer 2.")
    else:
        print("      -> prometheus_metrics is OFF or absent.")
        print("         THIS IS THE ROOT CAUSE. Fix: add to the Nomad agent")
        print("         config on .51")
        print("             telemetry {")
        print("               prometheus_metrics         = true")
        print("               publish_allocation_metrics = true")
        print("               publish_node_metrics       = true")
        print("             }")
        print("         RESTARTING NOMAD IS A DIFFERENT RISK PROFILE than")
        print("         restarting Dex or Grafana: it can disturb running")
        print("         tenant allocations. Plan it deliberately.")
' 2>/dev/null || note "(could not reach the Nomad agent from a pod)"

# ============================================================== LAYER 2
say "2. is Prometheus scraping Nomad, and is that target UP?"
promq 'targets' | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("      could not read targets"); raise SystemExit
act = d.get("data", {}).get("activeTargets", [])
hits = [t for t in act if "nomad" in json.dumps(t.get("labels", {})).lower()
        or "4646" in (t.get("scrapeUrl") or "")]
print("      active targets total: " + str(len(act)))
if not hits:
    print("      NO target matching nomad. The scrape config is missing or")
    print("      not loaded. -> fix layer 2.")
for t in hits:
    print("        health=" + str(t.get("health")) +
          "  url=" + str(t.get("scrapeUrl")))
    if t.get("lastError"):
        print("          lastError: " + str(t.get("lastError"))[:140])
    print("          lastScrape: " + str(t.get("lastScrape")))
'

# ============================================================== LAYER 3
say "3. does the endpoint return real metrics right now?"
note "Fetched from inside the cluster, the way Prometheus reaches it."
$KUBECTL run nomad-metrics-$$ -n "$NS" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s --max-time 10 "$NOMAD/v1/metrics?format=prometheus" 2>/dev/null \
  | python3 -c '
import sys
body = sys.stdin.read()
if not body.strip():
    print("      EMPTY response.")
elif body.lstrip().startswith("{"):
    print("      got JSON, not Prometheus text. That is what Nomad returns")
    print("      when prometheus_metrics is not enabled:")
    print("        " + body[:200])
else:
    lines = [l for l in body.splitlines() if l and not l.startswith("#")]
    names = sorted({l.split("{")[0].split(" ")[0] for l in lines})
    nomad = [n for n in names if n.startswith("nomad_")]
    print("      " + str(len(lines)) + " sample lines, " +
          str(len(nomad)) + " distinct nomad_* metrics")
    alloc = [n for n in nomad if "alloc" in n]
    print("      allocation-scoped (what a per-user view needs):")
    for n in alloc[:15]:
        print("        " + n)
    if not alloc:
        print("        NONE. publish_allocation_metrics is probably off.")
    for l in lines:
        if "allocs" in l and ("cpu" in l or "memory" in l):
            print("      a real sample line, with its labels:")
            print("        " + l[:220])
            break
' 2>/dev/null || note "(could not reach the metrics endpoint from a pod)"

# ============================================================== LAYER 4
say "4. do Nomad allocations carry any OWNER identity?"
note "THE REPO ALREADY ANSWERS HALF OF THIS, and the answer is no:"
note "  the provisioner builds its Nomad job with ID/Name 'starter' (a"
note "  CONSTANT, identical for every tenant) and NO Meta block at all."
note "  Namespace is tenant-PROJECT - which identifies the PROJECT,"
note "  not the user who owns it."
note ""
note "So the only possible join is namespace -> owner, via the Kubernetes"
note "namespace labels, because the Nomad namespace name and the k8s"
note "namespace name are the same string. That only works if Nomad's"
note "metrics carry the namespace as a surviving Prometheus label."
note ""
note "Checking a REAL registered job, not the template on disk:"
for NSX in $($KUBECTL get ns -l owner -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
  out="$($KUBECTL run nomad-job-$$ -n "$NS" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 --command -- \
    curl -s --max-time 8 "$NOMAD/v1/job/starter?namespace=$NSX" 2>/dev/null || true)"
  printf '%s' "$out" | python3 -c '
import json, os, sys
ns = os.environ["NSX"]
try:
    j = json.load(sys.stdin)
except Exception:
    raise SystemExit
if not isinstance(j, dict) or not j.get("ID"):
    raise SystemExit
print("      namespace " + ns + ": job ID=" + str(j.get("ID")) +
      "  Meta=" + json.dumps(j.get("Meta")))
tg = (j.get("TaskGroups") or [{}])[0]
print("        TaskGroup Meta=" + json.dumps(tg.get("Meta")) +
      "  Task Meta=" + json.dumps((tg.get("Tasks") or [{}])[0].get("Meta")))
' 2>/dev/null || true
  NSX="$NSX"
done
note ""
note "And whether the namespace survives as a Prometheus LABEL:"
promq 'query?query=nomad_client_allocs_memory_rss' | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("data", {}).get("result", [])
if not res:
    print("      no nomad_client_allocs_memory_rss series to inspect")
else:
    print("      labels on a real allocation series:")
    for k, v in sorted(res[0]["metric"].items()):
        print("        " + k + " = " + str(v)[:60])
    m = res[0]["metric"]
    for cand in ("namespace", "exported_namespace"):
        if cand in m:
            print("      -> " + cand + " IS present. A join to")
            print("         kube_namespace_labels on that value is possible.")
            break
    else:
        print("      -> NO namespace label. Per-user filtering would need a")
        print("         job-spec change (Meta on the Nomad job), which is a")
        print("         separate task.")
' 2>/dev/null || note "(metric not present yet)"

say "done - nothing was changed"
