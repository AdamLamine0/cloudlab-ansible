#!/usr/bin/env bash
# deploy-delete-and-monitoring.sh
#
# The complete, ordered procedure for the delete-project feature and the
# Grafana "Monitoring" link. RUN ON THE kube VM (192.168.1.50), from the
# directory holding app.py.
#
#   ssh -J root@192.168.64.172 root@192.168.1.50
#   cd /root/signup-portal
#   ./deploy-delete-and-monitoring.sh --check
#   ./deploy-delete-and-monitoring.sh --all
#
# THE ORDER IS LOAD-BEARING and each stage is safe to stop after:
#
#   1. RBAC        grant n8n `delete` on three resource types. Nothing
#                  calls it yet, so this changes no behaviour.
#   2. WORKFLOWS   import + activate. `delete-project` is a new endpoint
#                  nothing reaches yet; the `my-projects` change adds a
#                  field the CURRENT portal ignores.
#   3. PORTAL      ./deploy.sh. Only now does a user-reachable delete
#                  button exist, on top of permissions and a workflow
#                  that already work.
#
# Running 3 before 1 is not dangerous, only useless: the button appears
# and every delete fails closed with a 403, reported honestly as "not
# deleted" rather than silently doing nothing.
#
# Usage:
#   --check        preflight + show current RBAC. CHANGES NOTHING.
#   --all          stages 1, 2, 3 in order, prompting before each.
#   --rbac         stage 1 only
#   --workflows    stage 2 only
#   --portal       stage 3 only (calls ./deploy.sh)
#   --rollback-rbac  remove the three delete verbs again
#   --yes          do not prompt (for a non-interactive run)
set -euo pipefail

# Absolute path by default, per Problem #87: non-interactive shells on
# kube get a PATH without /usr/local/bin. Overridable only so the
# preflight can be exercised off-cluster; do not override it on kube.
KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ROLE=n8n-provisioner
SA=system:serviceaccount:n8n:n8n
ASSUME_YES=0
STAGE=""

for arg in "$@"; do
  case "$arg" in
    --check|--all|--rbac|--workflows|--portal|--rollback-rbac) STAGE="$arg" ;;
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
  local a
  read -r -p "    $1 [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "    aborted"; exit 1; }
}

# ===========================================================  PREFLIGHT
preflight() {
  say "preflight"
  [[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"

  local missing=()
  # wfcheck.js cross-checks the reserved-name lists across THREE workflow
  # files, so provision and name-check must be present even though this
  # change does not touch them. Listed here so a missing one is a clear
  # "missing file" rather than a node stack trace out of preflight.
  for f in app.py signup-portal.yaml deploy.sh \
           n8n-workflow-delete-project.json n8n-workflow-my-projects.json \
           n8n-workflow-provision.json n8n-workflow-name-check.json \
           assets/bg-aurora.png assets/tt-logo.png assets/tt-mark.png; do
    [[ -f "$f" ]] || missing+=("$f")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '!! missing file(s):\n' >&2
    printf '     %s\n' "${missing[@]}" >&2
    die "copy them from the workstation first"
  fi
  note "all required files present"

  # The code ships as a ConfigMap with no build step, so nothing else
  # catches a syntax error before it is already running.
  python3 -c 'import ast; ast.parse(open("app.py").read())' \
    || die "app.py does not parse"
  note "app.py parses"

  python3 -c 'import json; [json.load(open(f)) for f in [
    "n8n-workflow-delete-project.json","n8n-workflow-my-projects.json"]]' \
    || die "a workflow file is not valid JSON"
  note "both workflow files parse"

  # Structural validation BEFORE import: unbound credentials, unreachable
  # nodes, missing alwaysOutputData. A node that declares a credential
  # type but binds none gets 401 and the run still reports success
  # (Problem #123).
  if command -v node >/dev/null 2>&1 && [[ -f tests/wfcheck.js ]]; then
    # Pass the path explicitly rather than relying on the default.
    node tests/wfcheck.js n8n-workflow-provision.json \
      || die "wfcheck failed - do not import"
    note "wfcheck passed"
  else
    note "wfcheck SKIPPED (node or tests/wfcheck.js not present here)"
  fi

  $KUBECTL get clusterrole "$ROLE" >/dev/null 2>&1 \
    || die "clusterrole/$ROLE not found - wrong cluster?"
  $KUBECTL get deploy/n8n -n n8n >/dev/null 2>&1 \
    || die "deploy/n8n not found in namespace n8n"
  note "cluster reachable, clusterrole and n8n deployment present"
}

show_verbs() {
  echo "    --- what $SA can do right now ---"
  local v
  for v in "delete deployments.apps" "delete services" \
           "delete ingresses.networking.k8s.io" \
           "delete namespaces" "delete resourcequotas" \
           "delete rolebindings.rbac.authorization.k8s.io" \
           "patch deployments.apps" "patch services" \
           "patch ingresses.networking.k8s.io" \
           "get ingresses.networking.k8s.io"; do
    printf '    %-48s ' "$v:"
    $KUBECTL auth can-i $v --as="$SA" -n default || true
  done
}

show_rules() {
  echo "    --- live rules on clusterrole/$ROLE ---"
  # A HEREDOC, not `python3 -c '...'`. The obvious one-liner form breaks:
  # the code needs single quotes (r['resources']) inside a single-quoted
  # shell string, and the shell silently strips them, so python receives
  # {,.join(r[resources])} and dies with a SyntaxError at runtime.
  # `bash -n` does NOT catch it, because adjacent quoted segments are
  # legal shell - it is only wrong once python sees it.
  $KUBECTL get clusterrole "$ROLE" -o json > /tmp/n8n-role.show.json
  python3 - /tmp/n8n-role.show.json <<'PY'
import json, sys
for i, r in enumerate(json.load(open(sys.argv[1]))["rules"]):
    groups = ",".join(r.get("apiGroups") or [""]) or "(core)"
    res = ",".join(r["resources"])
    print(f"    [{i}] {groups:28} {res:22} {sorted(r['verbs'])}")
PY
}

# ============================================================  STAGE 1
rbac_mutate() {   # $1 = add | remove
  local op="$1"
  $KUBECTL get clusterrole "$ROLE" -o json > /tmp/n8n-role.before.json

  # BY RESOURCE NAME, never by index. The repo's n8n.yaml and the live
  # role disagree about rule ORDER (the live one has ingresses and
  # endpointslices rules added imperatively and never backported), so an
  # index-based patch would grant the verb on whatever happens to sit at
  # that position - rolebindings, in the repo's ordering.
  OP="$op" python3 > /tmp/n8n-role.after.json <<'PY'
import json, os, sys
op = os.environ["OP"]
role = json.load(open("/tmp/n8n-role.before.json"))

WANT = [(("apps",), "deployments"),
        (("", None), "services"),
        (("networking.k8s.io",), "ingresses")]

def matches(rule, groups, res):
    # EXACT single-resource match. A rule bundling several resources
    # would take the verb for ALL of them, and tenant-full-access bundles
    # `secrets` with `deployments` - a loose match there would hand out
    # `delete secrets`. Refusing to match a bundled rule is the safe
    # failure.
    rg = rule.get("apiGroups") or [""]
    return rule.get("resources") == [res] and any(
        (g or "") in [x or "" for x in rg] for g in groups)

changed = 0
for groups, res in WANT:
    found = [r for r in role["rules"] if matches(r, groups, res)]
    if len(found) != 1:
        sys.exit(f"REFUSING: expected exactly one rule for {res}, found {len(found)}")
    r = found[0]
    if op == "add" and "delete" not in r["verbs"]:
        r["verbs"].append("delete"); changed += 1
    if op == "remove" and "delete" in r["verbs"]:
        r["verbs"].remove("delete"); changed += 1

# Belt and braces, whatever we just did.
for r in role["rules"]:
    for forbidden in ("namespaces", "resourcequotas", "rolebindings", "secrets"):
        if forbidden in r.get("resources", []) and "delete" in r["verbs"]:
            sys.exit(f"REFUSING: {forbidden} would carry delete")

role["metadata"].pop("resourceVersion", None)
role["metadata"].pop("creationTimestamp", None)
role["metadata"].pop("uid", None)
json.dump(role, sys.stdout, indent=2)
sys.stderr.write(f"    {op}: {changed} rule(s) would change\n")
PY

  echo "    --- rule diff ---"
  diff <(python3 -c 'import json;[print(",".join(r.get("apiGroups") or [""]), r["resources"], sorted(r["verbs"])) for r in json.load(open("/tmp/n8n-role.before.json"))["rules"]]') \
       <(python3 -c 'import json;[print(",".join(r.get("apiGroups") or [""]), r["resources"], sorted(r["verbs"])) for r in json.load(open("/tmp/n8n-role.after.json"))["rules"]]') \
       || true

  confirm "apply this ClusterRole change?"
  $KUBECTL apply -f /tmp/n8n-role.after.json
}

stage_rbac() {
  say "STAGE 1 of 3 - RBAC"
  note "granting delete on: apps/deployments, services, networking.k8s.io/ingresses"
  note "NOT granting: namespaces, resourcequotas, rolebindings (Problem #138)"
  echo
  echo "    === BEFORE ==="
  show_verbs
  rbac_mutate add
  echo
  echo "    === AFTER ==="
  show_verbs
  echo
  note "EXPECTED: yes on deployments/services/ingresses delete,"
  note "          no  on namespaces/resourcequotas/rolebindings delete."
  note "Anything else means stop and investigate."

  # Assert it rather than leaving it to the eye.
  local ok=1
  for r in deployments.apps services ingresses.networking.k8s.io; do
    [[ "$($KUBECTL auth can-i delete $r --as=$SA -n default)" == "yes" ]] || ok=0
  done
  for r in namespaces resourcequotas rolebindings.rbac.authorization.k8s.io; do
    [[ "$($KUBECTL auth can-i delete $r --as=$SA -n default)" == "no" ]] || ok=0
  done
  [[ $ok -eq 1 ]] || die "RBAC is not in the expected state. Run --rollback-rbac and re-read the rules."
  note "VERIFIED: three yes, three no."
}

# ============================================================  STAGE 2
import_one() {   # $1 = file, $2 = workflow id, $3 = human name
  local file="$1" id="$2" label="$3"
  note "importing $label ($id)"

  # n8n import:workflow wants a JSON ARRAY; the repo files are single
  # objects. Both carry a stable top-level id, so a re-import UPDATES in
  # place instead of creating a duplicate with a second webhook.
  python3 - "$file" "/tmp/wf-${id}.json" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
assert isinstance(w, dict) and w.get("id"), "workflow needs a top-level id"
json.dump([w], open(sys.argv[2], "w"))
PY

  $KUBECTL cp "/tmp/wf-${id}.json" "n8n/${N8N_POD}:/tmp/wf-${id}.json"
  $KUBECTL exec -n n8n deploy/n8n -- n8n import:workflow --input="/tmp/wf-${id}.json"

  # DEACTIVATE, THEN ACTIVATE. Not redundant: the workflow JSON carries
  # `active: true`, and import:workflow writes that straight into the
  # row. A following `--active=true` then sees the workflow is ALREADY
  # active and does nothing - so the activation path that writes
  # webhook_entity never runs, and the workflow lists as active while
  # its production webhook 404s. Toggling forces that path to run.
  $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$id" --active=false
  $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$id" --active=true
}

stage_workflows() {
  say "STAGE 2 of 3 - n8n workflows"
  confirm "import and activate both workflows?"

  N8N_POD="$($KUBECTL get pod -n n8n -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$N8N_POD" ]] || die "could not find the n8n pod"
  note "n8n pod: $N8N_POD"

  import_one n8n-workflow-delete-project.json deleteProject001 "Delete Project (stop routing)"
  import_one n8n-workflow-my-projects.json    myProjectsRead01 "My Projects (read-only)"

  # Activation does not register the webhook until n8n restarts.
  say "restarting n8n so the webhooks register"
  $KUBECTL rollout restart deploy/n8n -n n8n
  $KUBECTL rollout status deploy/n8n -n n8n --timeout=180s

  verify_webhooks
}

verify_webhooks() {
  say "verifying by CALLING the endpoints"
  note "'Successfully imported' is not evidence (Problem #123), and an"
  note "active flag is not evidence the webhook exists (Problem #149)."

  local token
  token="$($KUBECTL get secret n8n-webhook-token -n n8n -o jsonpath='{.data.token}' | base64 -d)"
  [[ -n "$token" ]] || die "could not read n8n-webhook-token from namespace n8n"

  N8N_POD="$($KUBECTL get pod -n n8n -l app=n8n -o jsonpath='{.items[0].metadata.name}')"

  # The verification runs INSIDE the pod, from a file, so no quoting has
  # to survive a shell, a kubectl exec and a node -e all at once.
  cat > /tmp/verify-hooks.js <<'JS'
const token = process.env.PORTAL_TOKEN;

async function call(path, body) {
  const r = await fetch('http://localhost:5678/webhook/' + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Portal-Token': token },
    body: JSON.stringify(body)
  });
  const raw = await r.text();
  let j = null;
  try { j = JSON.parse(raw); } catch (e) { j = null; }

  // UNWRAP A SINGLE-ITEM ARRAY. n8n's two responder modes return
  // different shapes: `respondWith: json` gives an object, while
  // `respondWith: allIncomingItems` gives an ARRAY of item json.
  // my-projects uses the latter, so reading .projects off the response
  // directly yields undefined and this check reported a perfectly good
  // workflow as broken - and then called die(), blocking the deploy.
  //
  // This is the same unwrap app.py already does in list_projects() and
  // check_name():  if isinstance(body, list): body = body[0] if body else {}
  if (Array.isArray(j)) j = j.length ? j[0] : {};

  return { status: r.status, json: j, raw: raw };
}

(async () => {
  let bad = 0;

  // A BLANK username must be refused without querying anything. This is
  // the fail-closed path, and it proves the endpoint is live at the same
  // time as proving it refuses.
  const del = await call('delete-project', { username: '', project: '' });
  const okDel = del.status === 200 && del.json
             && del.json.owned === false && del.json.deleted === false;
  console.log('    delete-project  HTTP ' + del.status +
              '  owned=' + (del.json && del.json.owned) +
              '  deleted=' + (del.json && del.json.deleted) +
              (okDel ? '   OK' : '   UNEXPECTED'));
  if (!okDel) { bad++; console.log('      raw: ' + del.raw.slice(0, 200)); }

  const mp = await call('my-projects', { username: '' });
  const okMp = mp.status === 200 && mp.json && Array.isArray(mp.json.projects)
            && mp.json.projects.length === 0;
  console.log('    my-projects     HTTP ' + mp.status +
              '  projects=' + (mp.json && Array.isArray(mp.json.projects)
                               ? mp.json.projects.length : 'n/a') +
              (okMp ? '   OK' : '   UNEXPECTED'));
  if (!okMp) { bad++; console.log('      raw: ' + mp.raw.slice(0, 200)); }

  // A wrong token must be rejected by n8n's header auth, not by us.
  const r = await fetch('http://localhost:5678/webhook/delete-project', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Portal-Token': 'wrong' },
    body: '{}'
  });
  const okAuth = r.status === 403 || r.status === 401;
  console.log('    bad token       HTTP ' + r.status +
              (okAuth ? '   OK (refused)' : '   UNEXPECTED - should be 401/403'));
  if (!okAuth) bad++;

  process.exit(bad ? 1 : 0);
})();
JS

  $KUBECTL cp /tmp/verify-hooks.js "n8n/${N8N_POD}:/tmp/verify-hooks.js"
  if $KUBECTL exec -n n8n deploy/n8n -- env PORTAL_TOKEN="$token" \
       node /tmp/verify-hooks.js; then
    note "both webhooks answer, and both fail closed on a blank username."
  else
    die "webhook verification FAILED. Do not deploy the portal yet.

    Diagnose with the probe. There is no sqlite3 CLI in the n8n image;
    it reads n8n's own bundled sqlite3 node module instead:

      ./n8n-webhook-probe.sh

    An EMPTY webhook_entity, or a missing row for an active workflow,
    means registration never happened (Problem #149 from the other
    side). Then:

      ./n8n-webhook-probe.sh --reregister"
  fi
}

# ============================================================  STAGE 3
stage_portal() {
  say "STAGE 3 of 3 - portal"
  note "code-only deploy. Does NOT read Vault and does NOT touch any credential."
  confirm "run ./deploy.sh now?"
  ./deploy.sh
  say "post-deploy checks"
  $KUBECTL get pods -n signup
  note "the new route must reach the CONSOLE pod, not the signup pod:"
  $KUBECTL get ingress signup-portal -n signup \
    -o jsonpath='{range .spec.rules[0].http.paths[*]}    {.path} -> {.backend.service.name}{"\n"}{end}'
  echo
  note "a pod running is not evidence the credential works (see deploy.sh)."
  note "Log in, delete a throwaway project, and confirm it comes back as"
  note "'Arrete' with its link removed rather than disappearing."
}

# ==============================================================  DRIVER
case "$STAGE" in
  --check)
    preflight
    say "current RBAC (nothing has been changed)"
    show_rules
    show_verbs
    ;;
  --rbac)          preflight; stage_rbac ;;
  --workflows)     preflight; stage_workflows ;;
  --portal)        preflight; stage_portal ;;
  --rollback-rbac)
    say "removing the three delete verbs"
    rbac_mutate remove
    show_verbs
    ;;
  --all)
    preflight
    stage_rbac
    stage_workflows
    stage_portal
    say "done - all three stages complete"
    ;;
esac
