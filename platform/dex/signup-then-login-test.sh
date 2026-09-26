#!/usr/bin/env bash
# signup-then-login-test.sh — the decisive expired-password test.
#
#   ./signup-then-login-test.sh [username] [client_id]
#
# client_id defaults to signup-portal, the portal's own Dex client.
#
# RUN DIRECTLY ON `kube`. Do not wrap in `ssh kube '...'` from a session
# already on kube (SSH nesting reconnects into a password prompt loop).
#
# Creates a BRAND NEW account through the portal's real /signup endpoint
# (which really does call FreeIPA user_add), then IMMEDIATELY attempts a
# Dex password grant against that same account, in the same process, with
# no delay and no intervening kinit.
#
# The password is generated here, used twice, and never printed or
# written to disk. Nobody needs to see it: the account is disposable.
#
# WHAT THIS PROVES / DISPROVES
#   HTTP 200 from Dex  -> a freshly created account can authenticate
#                         immediately. Problem #99's expired-password
#                         behaviour does NOT block Dex's LDAP bind.
#   401 invalid_grant  -> it does block it, and the portal needs a
#                         password-change step before login can work.
#
# CLEANUP: svc-portal cannot delete users (by design, Part 4). The test
# account is permanent until an admin removes it:
#   kinit admin && ipa user-del <username> && kdestroy
set -uo pipefail

U="${1:-dextest$(date +%H%M%S)}"
CLIENT="${2:-signup-portal}"
PORTAL_IP=192.168.1.50
PORTAL_HOST=signup.cloudlab.internal
HERE="$(cd "$(dirname "$0")" && pwd)"

# 16 chars, satisfies the portal's >=8 rule and FreeIPA's own policy.
PW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
[ -n "$PW" ] || { echo "could not generate a password" >&2; exit 1; }

echo "==> creating '$U' through the portal's REAL /signup (FreeIPA user_add)"
RESP=$(curl -s -o /tmp/su.body -w '%{http_code}|%{redirect_url}' \
  -H "Host: ${PORTAL_HOST}" \
  --data-urlencode "username=${U}" \
  --data-urlencode "password=${PW}" \
  --data-urlencode "first=Dex" \
  --data-urlencode "last=Test" \
  "http://${PORTAL_IP}/signup")
CODE="${RESP%%|*}"
LOC="${RESP##*|}"
echo "    HTTP $CODE  ${LOC:+redirect -> $LOC}"

if [ "$CODE" != "303" ]; then
  echo "    SIGNUP FAILED. Portal said:"
  sed -e 's/<[^>]*>/ /g' /tmp/su.body | tr -s ' ' | grep -o '[A-ZÀ-Ü][^.]*\.' \
    | head -3 | sed 's/^/      /'
  rm -f /tmp/su.body
  echo
  echo "    (no account created, so nothing to clean up)"
  exit 1
fi
rm -f /tmp/su.body
echo "    account created in FreeIPA"

echo "==> IMMEDIATELY attempting Dex password grant for '$U' via client '$CLIENT' (no delay)"
"${HERE}/dex-login-test.sh" "$U" "$PW" "$CLIENT"
RC=$?

echo
echo "============================================================"
if [ $RC -eq 0 ]; then
  echo "RESULT: a brand-new portal account authenticated to Dex at once."
  echo "        Problem #99's expired-password behaviour does NOT block"
  echo "        the Dex password grant. No password-change step needed."
else
  echo "RESULT: the brand-new account could NOT authenticate to Dex."
  echo "        The expired-password concern is REAL. The portal needs a"
  echo "        password-change step before /login can work."
fi
echo
echo "CLEANUP (test account is permanent until an admin removes it):"
echo "  on freeipa:  kinit admin && ipa user-del $U && kdestroy"
exit $RC
