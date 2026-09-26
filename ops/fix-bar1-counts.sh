#!/usr/bin/env bash
# fix-bar1-counts.sh - make the two summary panels count BOTH platforms.
#
# RUN ON THE kube VM. Everything happens here; no local file is read, so a
# stale copy on the workstation cannot be the reason it does nothing.
#
# WHAT IT FIXES
#   "Your projects" counts only kube_deployment_created, so a Nomad-only
#   project is invisible to it (three active projects, the panel says two).
#   "Your projects, right now" additionally has its join inverted -
#   group_left(label_project) asks for that label from a bare count that
#   does not carry it - so it renders EMPTY rather than erroring, which
#   reads as "No projects yet".
#
# WHY IT IS ONE CHAINED SCRIPT
#   The earlier hand-run sequence had the patch and the apply as separate
#   unchained commands. A failing patch still fell through to the apply,
#   which then pushed whatever stale file happened to be on disk - and
#   that failure was invisible unless you watched the middle step. This
#   runs under `set -e`, so nothing downstream runs after a failure, and
#   every step prints the evidence for what it just did.
#
# PROOF IT LANDED, in order of strength:
#   1. the ConfigMap's resourceVersion CHANGES
#   2. kubectl apply says "configured", not "unchanged"
#   3. reading the object back shows the Nomad terms in panels 2 and 5
#
# Usage:
#   ./fix-bar1-counts.sh --check    read-only: what is live right now
#   ./fix-bar1-counts.sh --apply    patch and apply, with evidence at each step
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
NS=monitoring
CM=grafana-dashboard-my-usage
KEY=my-usage.json
WORK="${WORK:-/root/bar1-fix}"

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0
fi
[[ "$MODE" == "--check" || "$MODE" == "--apply" ]] \
  || { echo "unknown argument: $MODE (try --help)"; exit 2; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

mkdir -p "$WORK"

# Reports the nomad-term count in panels 2 and 5 of a dashboard JSON file.
report() {
  python3 - "$1" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    sys.exit("      could not parse: " + str(exc))
found = 0
for p in d.get("panels", []):
    if p.get("id") in (2, 5):
        found += 1
        expr = p["targets"][0]["expr"]
        # Distinct metric NAMES, not substring hits: the string "nomad_"
        # appears twice inside nomad_nomad_job_summary_running, which made
        # the printed number disagree with the note beside it.
        names = sorted(set(re.findall(r"nomad_[a-z0-9_]+", expr)))
        print("      panel %s (%s): %d nomad metric(s) %s"
              % (p["id"], p.get("title", "?"), len(names), names))
if found != 2:
    sys.exit("      REFUSING: expected panels 2 and 5, found " + str(found))
PY
}

say "STEP 1 - what is live right now"
RV_BEFORE="$($KUBECTL get configmap "$CM" -n "$NS" \
  -o go-template='{{.metadata.resourceVersion}}')"
[[ -n "$RV_BEFORE" ]] || die "could not read $CM in namespace $NS"
note "resourceVersion BEFORE: $RV_BEFORE"

$KUBECTL get configmap "$CM" -n "$NS" \
  -o go-template="{{index .data \"$KEY\"}}" > "$WORK/live.json"
note "dumped $(wc -c < "$WORK/live.json") bytes to $WORK/live.json"
report "$WORK/live.json"
note "0 nomad terms in both = the old version, as expected"

if [[ "$MODE" == "--check" ]]; then
  say "check only - nothing was changed"
  exit 0
fi

say "STEP 2 - patching panels 2 and 5"
note "Refuses rather than guessing if the panels are not where expected."
python3 - "$WORK/live.json" "$WORK/fixed.json" <<'PY'
import json, sys

d = json.load(open(sys.argv[1], encoding="utf-8"))

# One definition of "active", shared by both summary panels AND identical
# in shape to the CPU graphs, so a count can never disagree with the graph
# beside it. Each `or` arm is a separate source: container metrics, Nomad
# allocation metrics, then existence checks for a workload that exists but
# is not producing metrics yet (still building, crash-looping).
#
# An unknown metric name contributes an empty vector to `or` rather than
# erroring, so a wrong name here degrades instead of breaking the panel.
ACTIVE = (
"  (\n"
"      sum by (namespace) (\n"
"        rate(container_cpu_usage_seconds_total{container!=\"\",container!=\"POD\"}[5m])\n"
"      )\n"
"    or\n"
"      sum by (namespace) (nomad_client_allocs_cpu_total_percent)\n"
"    or\n"
"      sum by (namespace) (kube_deployment_created)\n"
"    or\n"
"      sum by (namespace) (nomad_nomad_job_summary_running)\n"
"  )\n"
# The METRIC goes on the left and kube_namespace_labels on the right,
# because group_left copies labels FROM THE RIGHT and that is the only
# side carrying label_project. The old table had this inverted, which
# renders empty rather than erroring.
"  * on (namespace) group_left(label_project)\n"
"    kube_namespace_labels{label_owner=\"${__user.login}\"}\n")

hit = 0
for p in d.get("panels", []):
    if p.get("id") == 2:
        p["targets"][0]["expr"] = "count(\n" + ACTIVE + ") or vector(0)"
        hit += 1
    if p.get("id") == 5:
        p["targets"][0]["expr"] = "count by (label_project) (\n" + ACTIVE + ")"
        hit += 1
if hit != 2:
    sys.exit("      REFUSING: expected to patch panels 2 and 5, patched " + str(hit))

json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("      patched 2 panel(s)")
PY

note "wrote $(wc -c < "$WORK/fixed.json") bytes to $WORK/fixed.json"
report "$WORK/fixed.json"
note "both should now read 2 nomad terms"

if cmp -s "$WORK/live.json" "$WORK/fixed.json"; then
  die "the patched file is IDENTICAL to the live one. Nothing would change;
    refusing to apply and claim success."
fi
note "the patched file differs from the live one, as it must"

say "STEP 3 - applying (watch this output)"
note "EXPECT: \"configmap/$CM configured\""
note "If it says \"unchanged\", the apply saw no difference and the fix did"
note "NOT land - stop and say so rather than moving on."
$KUBECTL create configmap "$CM" -n "$NS" \
  --from-file="$KEY=$WORK/fixed.json" \
  --dry-run=client -o yaml \
  | $KUBECTL label --local -f - grafana_dashboard=1 -o yaml \
  | $KUBECTL apply -f -

say "STEP 4 - proof, read back from the cluster"
RV_AFTER="$($KUBECTL get configmap "$CM" -n "$NS" \
  -o go-template='{{.metadata.resourceVersion}}')"
note "resourceVersion BEFORE: $RV_BEFORE"
note "resourceVersion AFTER : $RV_AFTER"
if [[ "$RV_BEFORE" == "$RV_AFTER" ]]; then
  die "resourceVersion did NOT change. The object was not modified."
fi
note "resourceVersion changed - the object really was written"

$KUBECTL get configmap "$CM" -n "$NS" \
  -o go-template="{{index .data \"$KEY\"}}" > "$WORK/after.json"
report "$WORK/after.json"

say "the two expressions now live in the cluster"
python3 - "$WORK/after.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for p in d.get("panels", []):
    if p.get("id") in (2, 5):
        print("=== panel %s: %s ===" % (p["id"], p.get("title", "?")))
        print(p["targets"][0]["expr"])
        print("")
PY

say "done"
note "The Grafana sidecar reloads within about a minute. Hard-refresh the"
note "browser, then 'Your projects' should read 3."
note "If it still reads 2 AFTER the expressions above show the Nomad terms,"
note "that is a data question, not a query one - send the panel output."
