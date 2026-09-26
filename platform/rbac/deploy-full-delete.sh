#!/usr/bin/env bash
# deploy-full-delete.sh - grant n8n `delete` on NAMESPACES, with a guardrail.
#
# RUN ON THE kube VM.
#
# WHAT THIS CHANGES, and why it is different in kind from the last grant
#   The delete feature shipped as "stop routing": remove the Ingress,
#   Service and Deployment, keep the namespace. This grant makes
#   Supprimer a real teardown - the namespace and everything in it.
#
#   `delete` on deployments/services/ingresses was a narrow widening of a
#   grant n8n already had on those same three types. `delete` on
#   namespaces is not: it is a single cascading operation with no undo
#   that removes the quota, the RoleBinding, every Secret, every PVC and
#   every workload inside, and RBAC has no way to scope it to names
#   matching `tenant-*`.
#
#   RBAC `resourceNames` cannot express a prefix, so there is no rule
#   shape that says "only tenant namespaces". With this grant alone, the
#   n8n service account can delete `kube-system`, `vault`, `dex` or
#   `monitoring`. That is what Problem #131 withheld, and the reasoning
#   has not changed - what changes is that the operation is now wanted.
#
# THE GUARDRAIL, and why it is not optional in spirit
#   What RBAC cannot express, admission can. This cluster runs Kubernetes
#   1.36, so ValidatingAdmissionPolicy is built in - no policy engine, no
#   new controller, no new failure surface of its own. The policy here
#   refuses any namespace DELETE by the n8n service account unless the
#   namespace is named `tenant-*` AND carries `provisioned-by: n8n`,
#   which n8n itself sets at creation.
#
#   Apply --guardrail FIRST, then --rbac, then --test. Guardrail before
#   grant means the permission never exists unguarded; test after grant
#   because the test impersonates the account and needs the permission
#   to exist for its results to mean anything.
#
# Usage:
#   ./deploy-full-delete.sh --check       what n8n can do now. CHANGES NOTHING.
#   ./deploy-full-delete.sh --guardrail   install the admission policy FIRST
#   ./deploy-full-delete.sh --rbac        then grant delete on namespaces
#   ./deploy-full-delete.sh --test        prove the guardrail actually refuses
#   ./deploy-full-delete.sh --workflows  import the manager, then the deleter
#   ./deploy-full-delete.sh --diagnose NS  why was a delete refused?
#   ./deploy-full-delete.sh --backfill-labels  label legacy tenant namespaces
#   ./deploy-full-delete.sh --rollback    remove both, in the safe order
#   --yes    do not prompt
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
ROLE=n8n-provisioner
SA=system:serviceaccount:n8n:n8n
POLICY=n8n-namespace-delete-guard

ASSUME_YES=0
STAGE=""
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --check|--guardrail|--rbac|--test|--workflows|--rollback|--diagnose|--backfill-labels) STAGE="$arg" ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"; exit 0 ;;
    # An unknown DASHED token is a typo and must fail. A bare word is a
    # POSITIONAL argument - --diagnose takes a namespace. The parser used
    # to reject every non-flag token, so a documented two-word form could
    # never be typed: the help said --diagnose NS and the parser refused
    # NS.
    -*) echo "unknown option: $arg (try --help)"; exit 2 ;;
    *) if [[ -n "$TARGET" ]]; then
         echo "unexpected extra argument: $arg (try --help)"; exit 2
       fi
       TARGET="$arg" ;;
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

verbs() {
  echo "    --- what $SA can do right now ---"
  local v
  for v in "delete namespaces" "delete deployments.apps" "delete services" \
           "delete ingresses.networking.k8s.io" "delete resourcequotas" \
           "delete rolebindings.rbac.authorization.k8s.io" "delete secrets" \
           "create namespaces" "get namespaces"; do
    printf '    %-48s ' "$v:"
    $KUBECTL auth can-i $v --as="$SA" -n default || true
  done
  printf '    %-48s ' "guardrail policy installed:"
  if $KUBECTL get validatingadmissionpolicy "$POLICY" >/dev/null 2>&1; then
    echo yes
  else
    echo NO
  fi
}

# ======================================================== THE GUARDRAIL
guardrail() {
  say "installing the admission guardrail FIRST"
  note "RBAC cannot scope a namespace delete to names matching tenant-*."
  note "This can. It refuses any namespace DELETE by n8n unless the"
  note "namespace is named tenant-* AND carries provisioned-by: n8n."
  note ""
  note "failurePolicy is Fail: if the policy cannot be evaluated, the"
  note "delete is REFUSED rather than allowed. Fail-closed, like the"
  note "workflow's own ownership check."

  cat > /tmp/n8n-ns-guard.yaml <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: n8n-namespace-delete-guard
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["DELETE"]
        resources:   ["namespaces"]
  matchConditions:
    # Only constrains n8n. A human admin deleting a namespace is
    # unaffected by this policy.
    - name: only-the-n8n-service-account
      expression: "request.userInfo.username == 'system:serviceaccount:n8n:n8n'"
  validations:
    - expression: >-
        oldObject.metadata.name.startsWith('tenant-')
      message: "n8n may only delete namespaces named tenant-*"
    - expression: >-
        has(oldObject.metadata.labels) &&
        'provisioned-by' in oldObject.metadata.labels &&
        oldObject.metadata.labels['provisioned-by'] == 'n8n'
      message: "n8n may only delete namespaces it provisioned (provisioned-by=n8n)"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: n8n-namespace-delete-guard
spec:
  policyName: n8n-namespace-delete-guard
  validationActions: ["Deny"]
YAML

  say "the policy to be applied"
  cat /tmp/n8n-ns-guard.yaml | sed 's/^/    /'
  confirm "apply this admission policy?"
  $KUBECTL apply -f /tmp/n8n-ns-guard.yaml
  note "installed. Now --rbac, then --test. The test impersonates the"
  note "service account, so it needs the grant to exist before its"
  note "results mean anything - see the note in --test."
}

# ============================================================== THE RBAC
rbac() {
  say "granting delete on namespaces"
  $KUBECTL get validatingadmissionpolicy "$POLICY" >/dev/null 2>&1 \
    || die "the guardrail is NOT installed. Run --guardrail first, so the
    permission never exists unguarded. Override deliberately if you must."

  echo "    === BEFORE ==="
  verbs
  $KUBECTL get clusterrole "$ROLE" -o json > /tmp/n8n-role.before.json

  # BY RESOURCE NAME, never by index, and requiring an EXACT
  # single-resource match so a bundled rule cannot take the verb too.
  python3 - <<'PY' > /tmp/n8n-role.after.json
import json, sys

role = json.load(open("/tmp/n8n-role.before.json"))

found = [r for r in role["rules"]
         if r.get("resources") == ["namespaces"]
         and (r.get("apiGroups") or [""]) in ([""], [], [None])]
if len(found) != 1:
    sys.exit("REFUSING: expected exactly one core/namespaces rule, found "
             + str(len(found)))
rule = found[0]
if "delete" in rule["verbs"]:
    sys.stderr.write("    delete already present on namespaces\n")
else:
    rule["verbs"].append("delete")
    sys.stderr.write("    added delete to the namespaces rule\n")

# These must still NOT carry delete. A namespace delete cascades to them
# anyway; a DIRECT grant would let n8n strip a quota or a binding from a
# namespace it is leaving in place.
for r in role["rules"]:
    for forbidden in ("resourcequotas", "rolebindings", "secrets"):
        if forbidden in r.get("resources", []) and "delete" in r["verbs"]:
            sys.exit("REFUSING: " + forbidden + " would carry a direct delete")

role["metadata"].pop("resourceVersion", None)
role["metadata"].pop("creationTimestamp", None)
role["metadata"].pop("uid", None)
json.dump(role, sys.stdout, indent=2)
PY

  say "the ClusterRole diff"
  diff <(python3 -c 'import json;[print(",".join(r.get("apiGroups") or [""]), r["resources"], sorted(r["verbs"])) for r in json.load(open("/tmp/n8n-role.before.json"))["rules"]]') \
       <(python3 -c 'import json;[print(",".join(r.get("apiGroups") or [""]), r["resources"], sorted(r["verbs"])) for r in json.load(open("/tmp/n8n-role.after.json"))["rules"]]') \
       || true

  confirm "apply this ClusterRole change?"
  $KUBECTL apply -f /tmp/n8n-role.after.json
  echo "    === AFTER ==="
  verbs

  [[ "$($KUBECTL auth can-i delete namespaces --as=$SA -n default)" == "yes" ]] \
    || die "delete namespaces is still refused - the apply did not take"
  note "VERIFIED: delete on namespaces is granted, and guarded."
}

# =============================================================== THE TEST
test_guard() {
  say "proving the guardrail actually refuses"
  note "A grant you have not tested the limits of is a grant you do not"
  note "know the shape of. This creates two throwaway namespaces and has"
  note "n8n try to delete both."

  # WITHOUT THE RBAC GRANT THIS TEST IS MEANINGLESS, and worse than
  # meaningless: every delete is refused by RBAC before admission is
  # consulted at all, so case 1 fails and case 2 "passes" for entirely
  # the wrong reason. Run this AFTER --rbac.
  if [[ "$($KUBECTL auth can-i delete namespaces --as=$SA -n default)" != "yes" ]]; then
    die "delete on namespaces is not granted yet, so every case below would
    be refused by RBAC before the guardrail is ever reached - case 2 would
    look like a pass and prove nothing. Run --rbac first, then --test."
  fi

  local ok_ns="tenant-guardtest-$$" bad_ns="guardtest-notours-$$"
  confirm "create two throwaway namespaces and attempt deletes as n8n?"

  $KUBECTL create namespace "$ok_ns" >/dev/null
  $KUBECTL label namespace "$ok_ns" provisioned-by=n8n >/dev/null
  $KUBECTL create namespace "$bad_ns" >/dev/null
  note "created $ok_ns (tenant-*, provisioned-by=n8n)"
  note "created $bad_ns (neither)"

  say "1. n8n deleting a namespace it provisioned - should SUCCEED"
  if $KUBECTL delete namespace "$ok_ns" --as="$SA" --timeout=30s; then
    note "allowed, as intended"
  else
    note "REFUSED - the guardrail is too strict or the RBAC is missing"
  fi

  say "2. n8n deleting a namespace it did NOT provision - should be REFUSED"
  if $KUBECTL delete namespace "$bad_ns" --as="$SA" --timeout=30s 2>&1; then
    die "ALLOWED. The guardrail is NOT working. Roll back the RBAC now:
    ./deploy-full-delete.sh --rollback"
  else
    note "refused, as intended"
  fi

  say "3. the one that matters - n8n deleting kube-system"
  note "Dry run only. Nothing is actually deleted."
  $KUBECTL delete namespace kube-system --as="$SA" --dry-run=server 2>&1 \
    | sed 's/^/    /' || true
  note "EXPECT a denial mentioning the policy. If this is allowed, stop"
  note "and roll back immediately."

  $KUBECTL delete namespace "$bad_ns" --ignore-not-found >/dev/null 2>&1 || true
  note "cleaned up"
}

rollback() {
  say "rollback - RBAC first, then the guardrail"
  note "This order matters: removing the guardrail first would leave the"
  note "permission briefly unguarded."
  confirm "remove delete-on-namespaces and the admission policy?"
  $KUBECTL get clusterrole "$ROLE" -o json > /tmp/n8n-role.before.json
  python3 - <<'PY' > /tmp/n8n-role.after.json
import json, sys
role = json.load(open("/tmp/n8n-role.before.json"))
for r in role["rules"]:
    if r.get("resources") == ["namespaces"] and "delete" in r["verbs"]:
        r["verbs"].remove("delete")
        sys.stderr.write("    removed delete from the namespaces rule\n")
role["metadata"].pop("resourceVersion", None)
role["metadata"].pop("creationTimestamp", None)
role["metadata"].pop("uid", None)
json.dump(role, sys.stdout, indent=2)
PY
  $KUBECTL apply -f /tmp/n8n-role.after.json
  $KUBECTL delete validatingadmissionpolicybinding "$POLICY" --ignore-not-found
  $KUBECTL delete validatingadmissionpolicy "$POLICY" --ignore-not-found
  verbs
}

diagnose() {
  local ns="$1"
  [[ -n "$ns" ]] || die "give a namespace, e.g. --diagnose tenant-demo-k8s"
  say "why can n8n not delete $ns ?"

  $KUBECTL get ns "$ns" -o json > /tmp/diag-ns.json 2>/dev/null     || die "$ns not found"

  note "its labels:"
  python3 - /tmp/diag-ns.json <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["metadata"]
labels = m.get("labels") or {}
for k in sorted(labels):
    print("      " + k + " = " + str(labels[k]))
if not labels:
    print("      (none at all)")
print("")
print("      created: " + str(m.get("creationTimestamp")))
print("")
print("      the guardrail requires BOTH of:")
name_ok = m["name"].startswith("tenant-")
lab_ok = labels.get("provisioned-by") == "n8n"
print("        name starts with tenant-      : " + ("PASS" if name_ok else "FAIL"))
print("        provisioned-by == n8n         : " + ("PASS" if lab_ok else "FAIL"))
if name_ok and not lab_ok:
    print("")
    print("      -> THE LABEL IS WHY. This namespace predates the")
    print("         provisioned-by convention. It is still an n8n tenant:")
    for k in ("owner", "tenant", "project"):
        if k in labels:
            print("           it carries " + k + "=" + labels[k])
    print("         Fix with --backfill-labels (adds the label to tenant-*")
    print("         namespaces that already carry owner or tenant).")
PY

  say "what the API server actually says, server-side dry run"
  note "This is the decision itself, not an inference from the labels."
  $KUBECTL delete namespace "$ns" --as="$SA" --dry-run=server 2>&1 | sed 's/^/    /' || true
}

backfill_labels() {
  say "backfilling provisioned-by=n8n onto legacy tenant namespaces"
  note "ONLY namespaces that are named tenant-* AND already carry an owner"
  note "or tenant label - i.e. provably created by n8n, just before the"
  note "provisioned-by convention existed. Nothing else is touched."
  note "This runs as YOU, not as n8n: n8n has no patch on namespaces."

  local targets
  targets="$($KUBECTL get ns -o json | python3 -c '
import json, sys
out = []
for n in json.load(sys.stdin)["items"]:
    m = n["metadata"]; lab = m.get("labels") or {}
    if not m["name"].startswith("tenant-"):
        continue
    if lab.get("provisioned-by") == "n8n":
        continue
    if "owner" in lab or "tenant" in lab:
        out.append(m["name"])
print(" ".join(out))')"

  if [[ -z "$targets" ]]; then
    note "nothing to backfill - every tenant namespace already has the label"
    return 0
  fi
  note "would label:"
  for t in $targets; do note "    $t"; done
  confirm "add provisioned-by=n8n to those?"
  for t in $targets; do
    $KUBECTL label namespace "$t" provisioned-by=n8n --overwrite
  done
  note "done. Re-run --diagnose on one to confirm it now passes."
}


verify_source() {
  # CHECK THE FILE BEFORE SENDING IT, not the cluster afterwards.
  # A stale copy of the workflow JSON on this box imports cleanly, reports
  # "Successfully imported", and leaves the OLD behaviour live. The import
  # is not lying - it faithfully imported the wrong file.
  local file="$1" want="$2"
  [[ -f "$file" ]] || die "$file not found on this box"
  if ! grep -q -- "$want" "$file"; then
    die "$file on THIS BOX does not contain [$want] - it is the OLD version.
    Importing it would succeed and change nothing. Copy the current file
    from the workstation first:
      scp $file kube:$(pwd)/"
  fi
  note "$(basename "$file"): contains [$want] - source is the new version"
}

verify_live() {
  local id="$1" want="$2" notwant="$3" f="/tmp/live-$1.json"
  $KUBECTL exec -n n8n deploy/n8n -- n8n export:workflow --id="$id" --output="$f" >/dev/null
  $KUBECTL exec -n n8n deploy/n8n -- cat "$f" > "$f.local"
  if grep -q -- "$want" "$f.local"; then
    note "$id: contains [$want] - the new code is live"
  else
    die "$id does NOT contain [$want]. The import did not land and the old
    version is still what runs. Do not test the feature until this passes."
  fi
  if [[ -n "$notwant" ]] && grep -q -- "$notwant" "$f.local"; then
    die "$id still contains [$notwant], which exists only in the OLD version.
    Something reverted, or the import was partial."
  fi
}

workflows() {
  say "importing the two workflows"
  note "ORDER: the namespace MANAGER first. The delete workflow calls it by"
  note "ID with action=delete, and the old two-node version has no delete"
  note "branch - it would fall through to its create path."
  for f in n8n-workflow-nomad-namespace.json n8n-workflow-delete-project.json; do
    [[ -f "$f" ]] || die "$f not found"
  done
  if command -v node >/dev/null 2>&1 && [[ -f tests/wfcheck.js ]]; then
    node tests/wfcheck.js n8n-workflow-provision.json || die "wfcheck failed"
    note "wfcheck passed"
  fi
  say "checking the SOURCE files before sending anything"
  verify_source n8n-workflow-delete-project.json namespaceStatus
  verify_source n8n-workflow-nomad-namespace.json "Delete the Nomad namespace"

  confirm "import both workflows and activate them?"

  N8N_POD="$($KUBECTL get pod -n n8n -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$N8N_POD" ]] || die "no n8n pod found"

  import_one n8n-workflow-nomad-namespace.json nomadNsCreator01
  import_one n8n-workflow-delete-project.json deleteProject001

  $KUBECTL rollout restart deploy/n8n -n n8n
  $KUBECTL rollout status deploy/n8n -n n8n --timeout=180s
  note "restarted; the webhook re-registers on activation"

  say "PROOF - reading the workflows back out of n8n"
  note "import:workflow printing Successfully imported is not evidence."
  note "Each fingerprint below exists in exactly ONE version, so it says",
  note "Each fingerprint below exists in exactly ONE version, so it says"
  verify_live deleteProject001 namespaceStatus routingStopped
  verify_live nomadNsCreator01 "Delete the Nomad namespace" ""
  note "verified by reading them back, not by the import message"
}

import_one() {
  local file="$1" id="$2"
  note "importing $id"

  # ACTIVATION IS NOT UNIVERSAL. A workflow is activated so n8n will
  # listen for it - a webhook to serve, a schedule to fire. A workflow
  # whose only trigger is executeWorkflowTrigger is a CALL TARGET: it is
  # invoked by another workflow through Execute Workflow and is never
  # listened for. Activating one produces
  #   WorkflowActivationError: ... has no node to start the workflow
  # in a retry loop, and under `set -e` that aborts this script before
  # the NEXT import runs - which is how the old delete workflow stayed
  # live while its replacement was never imported at all.
  local needs_activation
  needs_activation="$(python3 - "$file" <<'PY'
import json, sys
w = json.load(open(sys.argv[1], encoding="utf-8"))
ACTIVATABLE = ("webhook", "scheduleTrigger", "cron", "intervalTrigger",
               "emailReadImap", "rabbitmqTrigger")
hit = any(n["type"].split(".")[-1] in ACTIVATABLE for n in w.get("nodes", []))
print("yes" if hit else "no")
PY
)"

  python3 - "$file" "/tmp/wf-${id}.json" <<'PY'
import json, sys
w = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(w, dict) and w.get("id"), "workflow needs a top-level id"
json.dump([w], open(sys.argv[2], "w"))
PY
  $KUBECTL cp "/tmp/wf-${id}.json" "n8n/${N8N_POD}:/tmp/wf-${id}.json"
  $KUBECTL exec -n n8n deploy/n8n -- n8n import:workflow --input="/tmp/wf-${id}.json"

  if [[ "$needs_activation" == "yes" ]]; then
    # Toggle: import writes active=1 straight into the row, so a bare
    # --active=true is a no-op that never registers the webhook.
    $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$id" --active=false
    $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$id" --active=true
    note "$id activated (it has a listener trigger)"
  else
    # Explicitly deactivate. If a previous run left it active and failing,
    # this is what stops the retry loop.
    $KUBECTL exec -n n8n deploy/n8n -- n8n update:workflow --id="$id" --active=false || true
    note "$id imported, NOT activated - it is a call target, not a listener"
  fi
}

case "$STAGE" in
  --check)     verbs ;;
  --diagnose)  diagnose "$TARGET" ;;
  --backfill-labels) backfill_labels ;;
  --guardrail) guardrail ;;
  --rbac)      rbac ;;
  --test)      test_guard ;;
  --workflows) workflows ;;
  --rollback)  rollback ;;
esac
