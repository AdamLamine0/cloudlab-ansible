#!/bin/sh
# Phase 3 end-to-end: drive the REAL form, including the project name.
set -u
BASE=http://192.168.1.50
H="Host: signup.cloudlab.internal"
PASS='CloudLab-Test-2026!'
OUT=/tmp/e2e-name; mkdir -p $OUT
U="$1"; PROJ="$2"; KIND="$3"; DESC="$4"; REPO="${5:-}"

code=$(curl -s -o $OUT/$U.signup -w '%{http_code}' -H "$H" \
  --data-urlencode "username=$U" --data-urlencode "first=T" \
  --data-urlencode "last=N" --data-urlencode "password=$PASS" $BASE/signup)
[ "$code" = "303" ] && echo "  signup  created" || echo "  signup  HTTP $code (exists?)"

curl -s -o /dev/null -c $OUT/$U.jar -H "$H" \
  --data-urlencode "username=$U" --data-urlencode "password=$PASS" $BASE/login
grep -q cl_session $OUT/$U.jar || { echo "  login   FAILED"; exit 1; }
echo "  login   ok"

curl -s -o $OUT/$U.proj -b $OUT/$U.jar -c $OUT/$U.jar \
  -w "  submit  HTTP %{http_code}\n" -H "$H" \
  --data-urlencode "project=$PROJ" --data-urlencode "description=$DESC" \
  --data-urlencode "kind=$KIND" --data-urlencode "repo=$REPO" \
  --max-time 300 $BASE/new-project
