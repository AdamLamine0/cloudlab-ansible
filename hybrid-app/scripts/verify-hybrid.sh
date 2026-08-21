#!/usr/bin/env bash
# verify-hybrid.sh <user1|user2>
#
# End-to-end check of the hybrid app for one tenant. Run it from `kube`
# (.50), where /usr/local/bin/kubectl works. The Nomad checks are skipped automatically
# if the nomad CLI or NOMAD_TOKEN is not available there — run those
# from the jumpbox instead.
#
# Env it uses:
#   NOMAD_ADDR   default http://192.168.1.51:4646
#   NOMAD_TOKEN  tenant namespace token from Vault (optional here)
#
# Every check prints PASS / FAIL / SKIP and the script exits non-zero if
# anything failed, so it can be dropped straight into the CI/CD phase.
set -uo pipefail

TENANT="${1:-}"
case "$TENANT" in
  user1) PROBE_PORT=28001; OTHER=user2 ;;
  user2) PROBE_PORT=28002; OTHER=user1 ;;
  *) echo "usage: $(basename "$0") <user1|user2>" >&2; exit 2 ;;
esac

NOMAD_ADDR="${NOMAD_ADDR:-http://192.168.1.51:4646}"
SVC="${TENANT}-hostprobe.service.consul"
FAILED=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf '  SKIP  %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

section "1. Consul DNS is reachable from inside the cluster"
# This is the single most fragile link in the chain: the consul:53 zone
# in CoreDNS has silently vanished once already (Problem #34), and with
# Consul ACLs on default_policy=deny the agent needs a DNS token or the
# lookup returns nothing even when the zone is fine. See README.
# Resolve from the portal pod that is already running, rather than
# spawning a throwaway pod. `kubectl run --rm -i` races between the
# container exiting and its logs being readable, which made this check
# fail intermittently even when DNS was fine. The portal pod is also
# the thing that actually needs this lookup to work.
if /usr/local/bin/kubectl -n "$TENANT" exec deploy/portal -- \
     python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$SVC" 2>&1 \
     | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "$SVC resolves from the portal pod"
else
  fail "$SVC does not resolve from the portal pod — check the CoreDNS consul:53 zone and Consul's DNS token"
fi

section "2. Nomad side"
if ! command -v nomad >/dev/null 2>&1; then
  skip "nomad CLI not on this host — run this section from the jumpbox"
elif [ -z "${NOMAD_TOKEN:-}" ]; then
  skip "NOMAD_TOKEN not set — export the ${TENANT} namespace token from Vault"
else
  if NOMAD_ADDR="$NOMAD_ADDR" nomad job status -namespace "$TENANT" hostprobe >/dev/null 2>&1; then
    pass "hostprobe job exists in namespace $TENANT"
  else
    fail "hostprobe job not found in namespace $TENANT"
  fi
  if NOMAD_ADDR="$NOMAD_ADDR" nomad job status -namespace "$OTHER" hostprobe 2>&1 | grep -qi 'permission denied'; then
    pass "same token is denied in namespace $OTHER (§18 still holding)"
  else
    fail "token was NOT denied in namespace $OTHER — investigate before going further"
  fi
fi

section "3. Probe answers directly"
if curl -fsS --max-time 5 "http://192.168.1.51:${PROBE_PORT}/healthz" >/dev/null 2>&1; then
  pass "probe healthz on 192.168.1.51:${PROBE_PORT}"
else
  fail "probe not answering on 192.168.1.51:${PROBE_PORT}"
fi

section "4. Kubernetes side"
if /usr/local/bin/kubectl -n "$TENANT" rollout status deploy/portal --timeout=60s >/dev/null 2>&1; then
  pass "portal deployment is available in namespace $TENANT"
else
  fail "portal deployment is not available in namespace $TENANT"
fi

section "5. The actual hybrid path — portal reads the Nomad host through Consul"
STATUS_JSON="$(/usr/local/bin/kubectl -n "$TENANT" exec deploy/portal -- \
  python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/api/status',timeout=8).read().decode())" 2>/dev/null)"
if [ -z "$STATUS_JSON" ]; then
  fail "could not read /api/status from the portal pod"
else
  # The JSON is passed as argv[2], NOT on stdin: `python3 -` reads the
  # program from stdin, and the heredoc already owns stdin, so a piped
  # payload never arrives and json.load() sees an empty string.
  python3 - "$TENANT" "$STATUS_JSON" <<'PY'
import json, sys
tenant = sys.argv[1]
snap = json.loads(sys.argv[2])
probe = snap["probe"]
iso = snap["isolation"]
ok = True
if probe["ok"]:
    host = probe["data"]["host"]
    ns = probe["data"]["nomad"]["namespace"]
    print("  PASS  portal fetched the probe in %s ms (host=%s, uptime=%sh)"
          % (probe["ms"], host["hostname"], round((host["uptime_seconds"] or 0)/3600, 1)))
    if ns == tenant:
        print("  PASS  probe reports Nomad namespace %s" % ns)
    else:
        print("  FAIL  probe reports Nomad namespace %s, expected %s" % (ns, tenant)); ok = False
else:
    print("  FAIL  portal could not reach the probe: %s" % probe["error"]); ok = False

if not iso["configured"]:
    print("  SKIP  isolation panel — no Consul token in the portal-consul secret")
elif iso["verdict"] == "enforced":
    print("  PASS  Consul isolation enforced (own sees %s instance(s), other sees %s)"
          % (iso["own"]["instances"], iso["other"]["instances"] if iso["other"] else "n/a"))
else:
    print("  FAIL  Consul isolation verdict: %s (%s)" % (iso["verdict"], iso))
    ok = False
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] || FAILED=1
fi

section "6. Ingress"
if curl -fsS --max-time 5 -H "Host: ${TENANT}-portal.cloudlab.internal" http://192.168.1.50/healthz >/dev/null 2>&1; then
  pass "Traefik serves ${TENANT}-portal.cloudlab.internal"
else
  fail "Traefik did not serve ${TENANT}-portal.cloudlab.internal on 192.168.1.50"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  echo "ALL CHECKS PASSED — tenant ${TENANT} hybrid app is live across both orchestrators."
else
  echo "SOME CHECKS FAILED — see above."
fi
exit "$FAILED"
