#!/usr/bin/env bash
# dex-login-test.sh — prove Dex's OAuth2 password grant, by hand.
#
#   ./dex-login-test.sh <username> <password> [client_id]
#
# RUN THIS DIRECTLY ON `kube`. Do NOT wrap it in `ssh kube '...'` from a
# session that is already on kube — nesting SSH reconnects and lands you
# in a password prompt loop.
#
# The password is read from argv and never written to disk. The client
# secret is read from Dex's OWN running config, so it cannot be mistyped
# or truncated in transit. The access/ID tokens are never printed in
# full — only their decoded claims.
set -uo pipefail

U="${1:-}"
P="${2:-}"
CID="${3:-nomad}"
if [ -z "$U" ] || [ -z "$P" ]; then
  echo "usage: $0 <username> <password> [client_id]" >&2
  echo "note: username is the BARE UID (user1), never the email (Problem #83)" >&2
  exit 2
fi

KUBECTL=/usr/local/bin/kubectl          # Problem #87
CA=/root/dex-setup/freeipa-ca.crt
ISS_HOST=dex.dex.svc.cluster.local
LB_IP=192.168.1.50

[ -f "$CA" ] || { echo "CA not found at $CA" >&2; exit 1; }

echo "==> reading client secret for '$CID' from Dex's running config"
CSEC=$($KUBECTL get secret dex -n dex -o jsonpath='{.data.config\.yaml}' \
       | base64 -d \
       | awk -v id="- id: $CID" '
           $0 ~ id {f=1; next}
           f && /^- id:/ {exit}
           f && /secret:/ {print $2; exit}')
if [ -z "$CSEC" ]; then
  echo "  no client '$CID' found in Dex config. Clients present:" >&2
  $KUBECTL get secret dex -n dex -o jsonpath='{.data.config\.yaml}' \
    | base64 -d | grep '^- id:' >&2
  exit 1
fi
echo "    got a ${#CSEC}-char secret (value not printed)"

echo "==> POST /dex/token  grant_type=password  client_id=$CID  username=$U"
BODY=$(curl -s -w '\n%{http_code}' \
  --cacert "$CA" --resolve "${ISS_HOST}:5554:${LB_IP}" \
  "https://${ISS_HOST}:5554/dex/token" \
  -d grant_type=password \
  -d client_id="$CID" \
  --data-urlencode "client_secret=${CSEC}" \
  --data-urlencode "username=${U}" \
  --data-urlencode "password=${P}" \
  -d scope="openid email groups")

CODE=$(printf '%s' "$BODY" | tail -n1)
JSON=$(printf '%s' "$BODY" | sed '$d')
echo "    HTTP $CODE"

printf '%s' "$JSON" | python3 -c '
import sys, json, base64
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("  unparseable response:", raw[:200]); raise SystemExit(1)

if "error" in d:
    print("  ERROR:", d.get("error"), "-", d.get("error_description", ""))
    e = d.get("error")
    if e == "invalid_client":
        print("  => the CLIENT secret was rejected (not the user password)")
    elif e == "invalid_grant":
        print("  => the USER credentials were rejected.")
        print("     Expected if the account password is EXPIRED (Problem #99),")
        print("     which is the thing this test exists to find out.")
    raise SystemExit(1)

if "id_token" not in d:
    print("  no id_token; keys returned:", list(d)); raise SystemExit(1)

p = d["id_token"].split(".")[1]
p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print("  LOGIN OK. id_token claims:")
for k in ("iss", "aud", "sub", "email", "email_verified", "groups",
          "name", "preferred_username", "exp", "iat"):
    if k in c:
        print(f"    {k}: {c[k]}")
print("  (raw tokens deliberately not printed)")
'
