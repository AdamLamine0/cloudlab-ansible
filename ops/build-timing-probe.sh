#!/usr/bin/env bash
# build-timing-probe.sh - how long does a build really take, and when did
# the consumer start asking for the image?
#
# RUN ON THE kube VM. Read-only.
#
# WHAT THIS IS FOR
#   A freshly submitted project spends 20+ minutes in ImagePullBackOff
#   before succeeding on its own. The workflow wiring already shows WHY
#   (the deploy is not gated on the build finishing) but not HOW LONG
#   each part takes. This pulls the real timestamps:
#
#     t0  the Kaniko Job was created          (build starts)
#     t1  the Kaniko pod finished             (image pushed)
#     t2  the tenant's Deployment was created (pulling starts)
#     t3  the tenant's pod finally pulled     (recovery)
#
#   t2 - t0 tells you how far ahead the consumer ran.
#   t3 - t1 is the wasted time: how long the image existed before anything
#   noticed. That gap is backoff, not build time, and it is the part that
#   is fixable without making builds faster.
#
# Usage:
#   ./build-timing-probe.sh                 the most recent build
#   ./build-timing-probe.sh tenant-k8s      a specific tenant namespace
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
WANT_NS="${1:-}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0
fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

say "1. Kaniko builds, newest first, with real durations"
note "The build namespace admits only two concurrent builds (its quota),"
note "so a queued build waits for a slot. That wait is invisible to the"
note "tenant and counts against their 20 minutes."
$KUBECTL get jobs -n build -o json 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime

def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ") if s else None

try:
    items = json.load(sys.stdin)["items"]
except Exception:
    print("      could not list jobs in namespace build"); raise SystemExit
if not items:
    print("      no build jobs found (ttlSecondsAfterFinished is 3600, so")
    print("      anything older than an hour is already gone)")
    raise SystemExit

rows = []
for j in items:
    m = j["metadata"]; st = j.get("status", {})
    rows.append((m.get("creationTimestamp"), m["name"],
                 st.get("startTime"), st.get("completionTime"),
                 st.get("succeeded", 0), st.get("failed", 0),
                 (m.get("labels") or {}).get("tenant", "?")))
rows.sort(reverse=True)
print("      %-34s %-10s %9s %9s" % ("job", "tenant", "queued", "ran"))
for created, name, start, done, ok, bad, tenant in rows[:12]:
    c, s, d = ts(created), ts(start), ts(done)
    queued = int((s - c).total_seconds()) if c and s else None
    ran = int((d - s).total_seconds()) if s and d else None
    state = "ok" if ok else ("FAILED" if bad else "running")
    print("      %-34s %-10s %9s %9s  %s" % (
        name[:34], tenant[:10],
        (str(queued) + "s") if queued is not None else "-",
        (str(ran) + "s") if ran is not None else "-", state))
print("")
done = [r for r in rows if r[3]]
if done:
    durs = [int((ts(r[3]) - ts(r[2])).total_seconds()) for r in done if r[2]]
    if durs:
        print("      completed builds: n=%d  min=%ds  median=%ds  max=%ds" % (
            len(durs), min(durs), sorted(durs)[len(durs)//2], max(durs)))
'

say "2. the race: when was the tenant workload created vs the build?"
NSLIST="${WANT_NS:-$($KUBECTL get ns -l owner -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)}"
for NSX in $NSLIST; do
  $KUBECTL get deploy -n "$NSX" -o json 2>/dev/null | NSX="$NSX" python3 -c '
import json, os, sys
ns = os.environ["NSX"]
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    raise SystemExit
for dpl in items:
    m = dpl["metadata"]
    img = dpl["spec"]["template"]["spec"]["containers"][0].get("image", "?")
    print("      %-24s %-10s created=%s" % (ns, m["name"], m.get("creationTimestamp")))
    print("        image: " + img)
'
done
note ""
note 'Compare created above with the build queued/ran times in 1.'
note "A Deployment created BEFORE its image was pushed is the race."

say "3. how long did the pull keep failing after the image existed?"
note "Kubernetes backs off exponentially on a failed pull: 10s, 20s, 40s,"
note "80s, 160s, 320s, capped at 5 minutes. Once it reaches the cap, a"
note "pod can sit unready for up to 5 more minutes AFTER the image is"
note "actually available. That tail is not build time."
for NSX in $NSLIST; do
  ev="$($KUBECTL get events -n "$NSX" --sort-by=.lastTimestamp -o json 2>/dev/null || true)"
  printf '%s' "$ev" | NSX="$NSX" python3 -c '
import json, os, sys
ns = os.environ["NSX"]
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    raise SystemExit
pull = [e for e in items if "Pull" in (e.get("reason") or "")
        or "BackOff" in (e.get("reason") or "")]
if not pull:
    raise SystemExit
print("      " + ns + ":")
for e in pull[-8:]:
    print("        %-18s x%-4s %s  %s" % (
        e.get("reason"), e.get("count", 1),
        e.get("lastTimestamp"), (e.get("message") or "")[:70]))
'
done

say "4. what the registry actually holds"
note "An image that exists here while a pod is still backing off proves"
note "the remaining wait is backoff, not building."
$KUBECTL run reg-probe-$$ -n build --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s --max-time 10 "http://10.43.200.50:5000/v2/_catalog" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    repos = json.load(sys.stdin).get("repositories", [])
except Exception:
    print("      could not read the registry catalog"); raise SystemExit
print("      %d repositories" % len(repos))
for r in repos[:15]:
    print("        " + r)
' 2>/dev/null || note "(could not reach the registry)"

say "done - nothing was changed"
