#!/bin/sh
# Live three-option test for the explicit-platform-choice fix.
# Drives the REAL portal over HTTP: signup -> login -> submit.
# ONE host, path-based ingress; signup answers 303 on success.
set -u
BASE=http://192.168.1.50
H="Host: signup.cloudlab.internal"
PASS='CloudLab-Test-2026!'
OUT=/tmp/e2e-choice; mkdir -p $OUT
U="$1"; KIND="$2"; DESC="$3"; REPO="$4"

echo "=================================================="
echo "USER $U   kind=$KIND"
echo "=================================================="

code=$(curl -s -o $OUT/$U.signup -w '%{http_code}' -H "$H" \
  --data-urlencode "username=$U" --data-urlencode "first=Test" \
  --data-urlencode "last=Choix" --data-urlencode "password=$PASS" \
  $BASE/signup)
if [ "$code" = "303" ]; then echo "  signup  account created (303)"
else
  echo "  signup  HTTP $code"
  sed -e 's/<[^>]*>/|/g' $OUT/$U.signup | tr '|' '\n' | grep -i 'pris\|erreur\|caract' | head -2 | sed 's/^/    /'
fi

curl -s -o $OUT/$U.login -c $OUT/$U.jar -w '  login   HTTP %{http_code}\n' -H "$H" \
  --data-urlencode "username=$U" --data-urlencode "password=$PASS" $BASE/login
grep -q cl_session $OUT/$U.jar && echo "  login   session cookie issued" \
  || { echo "  login   NO SESSION - aborting"; exit 1; }

echo "  submitting (build may take several minutes)..."
curl -s -o $OUT/$U.proj -b $OUT/$U.jar -c $OUT/$U.jar \
  -w '  submit  HTTP %{http_code}  in %{time_total}s\n' -H "$H" \
  --data-urlencode "description=$DESC" --data-urlencode "kind=$KIND" \
  --data-urlencode "repo=$REPO" --max-time 900 $BASE/new-project

echo "  ---- what the user is shown ----"
sed -e 's/<[^>]*>/|/g' $OUT/$U.proj | tr '|' '\n' | grep -v '^ *$' | sed 's/^/    /'
