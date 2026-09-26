#!/usr/bin/env bash
# deploy-bar1.sh - the per-user Grafana default view, Kubernetes half only.
#
# RUN ON THE kube VM. Every stage shows a diff and prompts before applying.
#
# WHAT "BAR 1" IS, stated the same way the dashboard states it
#   A user who did nothing unusual sees only their own project's usage when
#   they open Grafana. The dashboard's queries filter on ${__user.login}
#   against the owner label already on tenant namespaces, and Dex users are
#   provisioned as Viewers so they cannot edit the query out.
#
# WHAT BAR 1 IS NOT
#   A security boundary. A Viewer keeps the datasources:query permission, so
#   Grafana's Explore and the /api/ds/query endpoint still return anyone's
#   series. Per-role Explore control is Grafana Enterprise RBAC; the only
#   OSS lever is [explore] enabled, which is GLOBAL and would remove Explore
#   from admin too - and would still not close the API path. That gap is
#   left OPEN and recorded, not silently mitigated. The enforced version is
#   Part 23 item 24 and this does not close it.
#
# NOMAD IS NOT INCLUDED. Nomad allocation metrics are not scraped by this
#   Prometheus at all, so there is nothing to filter. Recorded as its own
#   Part 23 item rather than guessed at (Problem #30: a guessed metric name
#   ships a panel that says "No data").
#
# Usage:
#   ./deploy-bar1.sh --audit-owners  who the owner labels actually belong to
#   ./deploy-bar1.sh --ksm           expose the owner label (diff, then apply)
#   ./deploy-bar1.sh --dashboard     provision the dashboard + home + Viewer
#   ./deploy-bar1.sh --verify        did the label and the dashboard land?
#   ./deploy-bar1.sh --all           the three stages, prompting before each
#   --yes    do not prompt
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
HELM="${HELM:-helm}"
NS=monitoring
LIVE_VALUES="${LIVE_VALUES:-/root/prometheus-values-live.yaml}"
CHART_VERSION="${CHART_VERSION:-88.2.0}"
DASH_JSON="${DASH_JSON:-grafana-bar1-dashboard.json}"

ASSUME_YES=0
STAGE=""
for arg in "$@"; do
  case "$arg" in
    --audit-owners|--ksm|--dashboard|--verify|--all) STAGE="$arg" ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)"; exit 2 ;;
  esac
done
[[ -n "$STAGE" ]] || { awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 2; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local a; read -r -p "    $1 [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "    aborted"; exit 1; }
}
[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

# ================================================== AUDIT THE OWNER LABELS
# The dashboard keys entirely off the owner label. Before trusting it, find
# out whose labels those actually are - this lab has accumulated a lot of
# test accounts, and a namespace carrying owner=<something> is not evidence
# that <something> is a real, intentional platform user.
audit_owners() {
  say "every distinct owner label value, with evidence"
  $KUBECTL get ns -L owner,project,tenant -o json > /tmp/bar1-ns.json
  $KUBECTL get pods -A -o json > /tmp/bar1-pods.json 2>/dev/null || echo '{"items":[]}' > /tmp/bar1-pods.json

  python3 - /tmp/bar1-ns.json /tmp/bar1-pods.json <<'PY'
import json, sys

# Test accounts this project's own handoff records as created for tests and
# pending cleanup. Matching one is a strong hint the namespace is residue.
KNOWN_TEST = {
    "ainomad01", "ainomad02", "casetest01", "emptyuser01", "nameuser01",
    "nameuser02", "owner01", "owner02", "selfserve01", "selfserve02",
    "selfserve03", "svctest01", "testuseradam2", "user1", "user2",
    "testportal3",
}
TEST_PREFIXES = ("dextest", "testuser", "tesuser", "selfserve", "nameuser",
                 "casetest", "ainomad", "svctest", "emptyuser", "owner0",
                 "testportal", "probe", "tmp", "test")

ns = json.load(open(sys.argv[1]))["items"]
pods = json.load(open(sys.argv[2]))["items"]

live = {}
for p in pods:
    n = p["metadata"]["namespace"]
    live[n] = live.get(n, 0) + 1

rows = []
for n in ns:
    m = n["metadata"]
    labels = m.get("labels") or {}
    owner = labels.get("owner") or labels.get("tenant")
    if not owner:
        continue
    rows.append({
        "ns": m["name"],
        "owner": owner,
        "project": labels.get("project") or "(none - legacy)",
        "created": (m.get("creationTimestamp") or "")[:10],
        "pods": live.get(m["name"], 0),
        "legacy": "owner" not in labels,
    })

if not rows:
    print("    NO namespace carries an owner or tenant label.")
    print("    The dashboard would show nothing for everyone. Stop here.")
    raise SystemExit(1)

owners = {}
for r in rows:
    owners.setdefault(r["owner"], []).append(r)

print(f"    {len(rows)} namespace(s) across {len(owners)} distinct owner value(s)")
print()
suspect = []
for owner in sorted(owners):
    rs = owners[owner]
    low = owner.lower()
    flag = ""
    if low in KNOWN_TEST:
        flag = "  <== KNOWN TEST ACCOUNT (handoff cleanup list)"
    elif any(low.startswith(p) for p in TEST_PREFIXES):
        flag = "  <== name matches a test pattern"
    elif not any(r["pods"] for r in rs):
        flag = "  <== no running pods in any of its namespaces"
    if flag:
        suspect.append(owner)
    print(f"    {owner}{flag}")
    for r in sorted(rs, key=lambda x: x["ns"]):
        tag = " [legacy: tenant label only]" if r["legacy"] else ""
        print(f"        {r['ns']:34} project={r['project']:16} "
              f"created={r['created']}  pods={r['pods']}{tag}")
    print()

print(f"    {len(owners) - len(suspect)} owner value(s) look like real users;"
      f" {len(suspect)} flagged")
if suspect:
    print()
    print("    FLAGGED, confirm each by hand before trusting the dashboard's")
    print("    per-user view - a flag is a hint, not a verdict:")
    for s in suspect:
        print(f"      {s}")
    print()
    print("    Check whether the FreeIPA account still exists (run on freeipa,")
    print("    after kinit admin):")
    for s in suspect:
        print(f"      ipa user-show {s}")
    print()
    print("    A namespace whose owner has no FreeIPA account can never be")
    print("    seen by anyone through this dashboard: nobody can log in as")
    print("    that user, so its usage is invisible but still counted against")
    print("    the cluster. That is residue to clean up, not a dashboard bug.")
PY
  note "nothing was changed"
}

# ============================================ EXPOSE THE LABEL TO PROMETHEUS
ksm() {
  say "kube-state-metrics: expose the namespace owner and project labels"
  note "kube-state-metrics v2 does NOT surface arbitrary object labels."
  note "Without this the join key kube_namespace_labels{label_owner=...}"
  note "does not exist and every panel is empty for everyone."

  # THE LIVE VALUES, never the stale file on disk.
  $HELM get values monitoring -n "$NS" -o yaml > "$LIVE_VALUES"
  note "read live values into $LIVE_VALUES ($(wc -c < "$LIVE_VALUES") bytes)"
  grep -q "additionalScrapeConfigs" "$LIVE_VALUES" \
    || note "WARNING: no additionalScrapeConfigs in the LIVE values - check before applying"

  cp -a "$LIVE_VALUES" "$LIVE_VALUES.bak.$(date +%Y%m%d%H%M%S)"
  LIVE_VALUES="$LIVE_VALUES" python3 - <<'PY'
import os
path = os.environ["LIVE_VALUES"]
src = open(path, encoding="utf-8", newline="").read()

if "metricLabelsAllowlist" in src:
    print("    metricLabelsAllowlist already present - not adding it twice")
    raise SystemExit(0)

BLOCK = ("kube-state-metrics:\n"
         "  metricLabelsAllowlist:\n"
         "    - namespaces=[owner,project,tenant]\n")

lines = src.splitlines()
out, done = [], False
for i, ln in enumerate(lines):
    if ln.rstrip() == "kube-state-metrics:" and not done:
        out.append(ln)
        out.append("  metricLabelsAllowlist:")
        out.append("    - namespaces=[owner,project,tenant]")
        done = True
        continue
    out.append(ln)
if not done:
    out.append("")
    out.extend(BLOCK.rstrip("\n").split("\n"))
open(path, "w", encoding="utf-8", newline="").write("\n".join(out) + "\n")
print("    added metricLabelsAllowlist for namespaces")
PY

  say "diff"
  diff "$(ls -t "$LIVE_VALUES".bak.* | head -1)" "$LIVE_VALUES" || true
  confirm "apply this with helm (chart pinned to $CHART_VERSION)?"
  $HELM upgrade monitoring prometheus-community/kube-prometheus-stack \
    -n "$NS" --version "$CHART_VERSION" -f "$LIVE_VALUES"
  $KUBECTL rollout status deploy/monitoring-kube-state-metrics -n "$NS" --timeout=180s
  note "kube-state-metrics restarted; the label appears after the next scrape"
}

# ==================================================== THE DASHBOARD ITSELF
dashboard() {
  say "provisioning the dashboard"
  [[ -f "$DASH_JSON" ]] || die "$DASH_JSON not found"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DASH_JSON" \
    || die "$DASH_JSON is not valid JSON"
  note "$DASH_JSON parses"

  # The sidecar picks up any ConfigMap carrying this label, which is the
  # pattern the existing dashboards already use.
  $KUBECTL create configmap grafana-dashboard-my-usage -n "$NS" \
    --from-file=my-usage.json="$DASH_JSON" \
    --dry-run=client -o yaml \
    | $KUBECTL label --local -f - grafana_dashboard=1 -o yaml \
    | $KUBECTL apply -f -
  note "ConfigMap grafana-dashboard-my-usage applied"

  say "Grafana settings: Viewer role for Dex users, and the home dashboard"
  note "role_attribute_path forces Viewer so a user cannot edit the filter"
  note "out of the query. default_home_dashboard_path makes this the first"
  note "thing a Dex user sees."
  note "NOTE: the home dashboard is ORG-WIDE. Admin's DATA is unaffected -"
  note "the filter lives in the query, and admin's other dashboards are"
  note "untouched - but admin's LANDING PAGE changes too. Grafana has no"
  note "per-role home dashboard; per-team is the alternative if that"
  note "matters."

  $HELM get values monitoring -n "$NS" -o yaml > "$LIVE_VALUES"
  cp -a "$LIVE_VALUES" "$LIVE_VALUES.bak.$(date +%Y%m%d%H%M%S)"
  LIVE_VALUES="$LIVE_VALUES" python3 - <<'PY'
import os
path = os.environ["LIVE_VALUES"]
src = open(path, encoding="utf-8", newline="").read()
lines = src.splitlines()

want = {
    "role_attribute_path": "      role_attribute_path: \"'Viewer'\"",
    "default_home_dashboard_path": None,
}
if "role_attribute_path" in src and "default_home_dashboard_path" in src:
    print("    both settings already present")
    raise SystemExit(0)

out = []
added_role = "role_attribute_path" in src
added_home = "default_home_dashboard_path" in src
for ln in lines:
    out.append(ln)
    if not added_role and ln.strip() == "auth.generic_oauth:":
        out.append("      # Dex users are VIEWERS. Not a security boundary -")
        out.append("      # it stops them editing the filter out of the panel.")
        out.append("      role_attribute_path: \"'Viewer'\"")
        added_role = True
    if not added_home and ln.strip() == "grafana.ini:":
        out.append("    dashboards:")
        out.append("      default_home_dashboard_path: /tmp/dashboards/my-usage.json")
        added_home = True

if not added_role:
    print("    WARNING: no auth.generic_oauth block found - is SSO applied?")
if not added_home:
    print("    WARNING: no grafana.ini block found - is SSO applied?")
open(path, "w", encoding="utf-8", newline="").write("\n".join(out) + "\n")
PY

  say "diff"
  diff "$(ls -t "$LIVE_VALUES".bak.* | head -1)" "$LIVE_VALUES" || true
  confirm "apply?"
  $HELM upgrade monitoring prometheus-community/kube-prometheus-stack \
    -n "$NS" --version "$CHART_VERSION" -f "$LIVE_VALUES"
  $KUBECTL rollout status deploy/monitoring-grafana -n "$NS" --timeout=300s
}

# ================================================================= VERIFY
verify() {
  say "1. does Prometheus now carry the owner label?"
  local pod
  pod="$($KUBECTL get pod -n "$NS" -l app.kubernetes.io/name=prometheus \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || pod="prometheus-monitoring-kube-prometheus-prometheus-0"
  local out
  out="$($KUBECTL exec -n "$NS" "$pod" -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=kube_namespace_labels' 2>/dev/null || true)"
  if printf '%s' "$out" | grep -q label_owner; then
    note "YES - label_owner is present. Distinct values:"
    printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
vals=sorted({r["metric"].get("label_owner","") for r in d.get("data",{}).get("result",[])} - {""})
for v in vals: print("      " + v)
print("      (" + str(len(vals)) + " distinct owner value(s))")' 2>/dev/null || true
  else
    note "NO - still absent. The dashboard will be empty for everyone."
    note "Re-check the --ksm stage and wait one scrape interval."
  fi

  say "2. is the dashboard registered?"
  $KUBECTL get configmap grafana-dashboard-my-usage -n "$NS" >/dev/null 2>&1 \
    && note "ConfigMap present" || note "ConfigMap MISSING"

  say "3. what Grafana is actually running with"
  $KUBECTL exec -n "$NS" deploy/monitoring-grafana -c grafana -- \
    sh -c 'grep -E "role_attribute_path|default_home_dashboard_path" /etc/grafana/grafana.ini' \
    2>/dev/null | sed 's/^/    /' || note "    (could not read grafana.ini)"

  say "WHAT THIS CANNOT VERIFY - do these by hand"
  cat <<'EOF'
    1. Log in as two different real users. Each must see ONLY their own
       project(s), by name, and the numbers must match something real.
    2. admin/<set at install time; see Vault> still sees full, unfiltered cluster data.
    3. As a Viewer, open Explore and run an arbitrary query. Report what
       happens. EXPECTED: it still works and shows everyone's data. That
       gap is known, left open, and recorded - it is what separates this
       from Part 23 item 24.
EOF
}

case "$STAGE" in
  --audit-owners) audit_owners ;;
  --ksm)          ksm ;;
  --dashboard)    dashboard ;;
  --verify)       verify ;;
  --all)          audit_owners; ksm; dashboard; verify ;;
esac
