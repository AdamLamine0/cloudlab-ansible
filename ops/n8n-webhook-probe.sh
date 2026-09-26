#!/usr/bin/env bash
# n8n-webhook-probe.sh - why is an "active" workflow's webhook 404ing?
#
# RUN ON THE kube VM. Read-only by default; --reregister is the only
# thing that changes anything.
#
# There is no sqlite3 CLI in the n8n image. n8n bundles the sqlite3 NODE
# MODULE though, and that is what this uses - the same approach Part 20
# already uses to read execution_entity.
#
# WHAT THIS IS FOR
#   `n8n list:workflow` showing a workflow, and workflow_entity.active
#   being 1, are BOTH compatible with the webhook not existing. n8n serves
#   production webhooks from a SEPARATE `webhook_entity` table, written
#   when the RUNNING INSTANCE activates a workflow - not when the CLI
#   flips the active column. That is Problem #149 seen from the other
#   side: there, a row outlived a deactivation; here, a row was never
#   created by one.
#
# Usage:
#   ./n8n-webhook-probe.sh              full report (read-only)
#   ./n8n-webhook-probe.sh --logs       activation errors from the pod log
#   ./n8n-webhook-probe.sh --db         workflow_entity + webhook_entity
#   ./n8n-webhook-probe.sh --call       call every registered path
#   ./n8n-webhook-probe.sh --reregister force re-activation (CHANGES STATE)
#   ./n8n-webhook-probe.sh --clean-stale          list stale rows (dry run)
#   ./n8n-webhook-probe.sh --clean-stale --apply  delete them (CHANGES STATE)
set -euo pipefail

KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"
NS=n8n
MODE="${1:-all}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

# --help must work anywhere. It used to sit after these guards, so asking
# a read-only question off-cluster died with "kubectl not found" instead
# of printing the usage.
if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0"
  exit 0
fi

[[ -x "$KUBECTL" ]] || die "$KUBECTL not found. Are you on the kube VM?"
POD="$($KUBECTL get pod -n "$NS" -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "no n8n pod found in namespace $NS"

# ---------------------------------------------------------------- the DB
# Written to a file and copied in, so no quoting has to survive a shell,
# a kubectl exec and a node -e all at once.
write_db_script() {
  cat > /tmp/n8n-db-probe.js <<'JS'
// n8n bundles sqlite3 as a node module even though the CLI is absent.
// The install path has moved between versions, so try the known ones and
// say which worked rather than failing with a bare MODULE_NOT_FOUND.
const CANDIDATES = [
  '/usr/local/lib/node_modules/n8n/node_modules/sqlite3',
  '/usr/local/lib/node_modules/n8n/node_modules/@n8n/db/node_modules/sqlite3',
  'sqlite3',
];
let sqlite3 = null, used = null;
for (const p of CANDIDATES) {
  try { sqlite3 = require(p); used = p; break; } catch (e) { /* next */ }
}
if (!sqlite3) {
  console.log('    could not load a sqlite3 module. Tried:');
  CANDIDATES.forEach(p => console.log('      ' + p));
  console.log('    find it with:');
  console.log('      kubectl exec -n n8n deploy/n8n -- find / -name "sqlite3" -maxdepth 8 -type d 2>/dev/null');
  process.exit(3);
}
console.log('    sqlite3 module: ' + used);

const DB = process.env.N8N_DB || '/home/node/.n8n/database.sqlite';
const db = new sqlite3.Database(DB, sqlite3.OPEN_READONLY, err => {
  if (err) { console.log('    cannot open ' + DB + ': ' + err.message); process.exit(3); }
});

function all(sql) {
  return new Promise(res => db.all(sql, (e, r) => res(e ? { error: e.message } : r)));
}

(async () => {
  console.log('    database: ' + DB);

  const wf = await all(
    "SELECT id, name, active FROM workflow_entity ORDER BY name");
  console.log('\n    --- workflow_entity ---');
  if (wf.error) { console.log('    ERROR: ' + wf.error); }
  else wf.forEach(r =>
    console.log('      ' + String(r.id).padEnd(20) +
                String(r.active === 1 || r.active === true ? 'ACTIVE' : 'inactive').padEnd(10) +
                r.name));

  const wh = await all(
    "SELECT workflowId, webhookPath, method, node FROM webhook_entity " +
    "ORDER BY webhookPath");
  console.log('\n    --- webhook_entity (what actually answers) ---');
  if (wh.error) {
    console.log('    ERROR: ' + wh.error);
  } else if (!wh.length) {
    console.log('      (EMPTY - no production webhook is registered at all)');
  } else {
    wh.forEach(r =>
      console.log('      ' + String(r.method || '?').padEnd(6) +
                  ('/webhook/' + r.webhookPath).padEnd(34) +
                  'workflow=' + r.workflowId));
  }

  // THE COMPARISON THAT MATTERS: an active workflow with a webhook
  // trigger and NO row here is the exact failure being chased.
  console.log('\n    --- active workflows with NO registered webhook ---');
  const registered = new Set((wh.error ? [] : wh).map(r => String(r.workflowId)));
  const rows = await all(
    "SELECT id, name, active, nodes FROM workflow_entity WHERE active = 1");
  if (rows.error) { console.log('    ERROR: ' + rows.error); }
  else {
    let bad = 0;
    rows.forEach(r => {
      let hasTrigger = false, path = '';
      try {
        const nodes = typeof r.nodes === 'string' ? JSON.parse(r.nodes) : r.nodes;
        const t = (nodes || []).find(n => n.type === 'n8n-nodes-base.webhook');
        if (t) { hasTrigger = true; path = (t.parameters || {}).path || '(no path)'; }
      } catch (e) { /* leave as not-a-trigger */ }
      if (hasTrigger && !registered.has(String(r.id))) {
        bad++;
        console.log('      ' + String(r.id).padEnd(20) + r.name +
                    '   expects /webhook/' + path);
      }
    });
    if (!bad) console.log('      (none - every active webhook workflow is registered)');
  }
  db.close();
})();
JS
}

probe_db() {
  say "DB: workflow_entity vs webhook_entity"
  write_db_script
  $KUBECTL cp /tmp/n8n-db-probe.js "$NS/$POD:/tmp/n8n-db-probe.js"
  $KUBECTL exec -n "$NS" "$POD" -- node /tmp/n8n-db-probe.js || true
}

probe_logs() {
  say "pod log: activation errors"
  note "A webhook is registered when the RUNNING instance activates the"
  note "workflow. If that threw, it is in here and nowhere else."
  $KUBECTL logs -n "$NS" "$POD" --tail=400 2>/dev/null \
    | grep -iE "webhook|activat|error|failed|issue" \
    | tail -40 || note "(nothing matched)"
}

probe_call() {
  say "calling the endpoints from inside the pod"
  local token
  token="$($KUBECTL get secret n8n-webhook-token -n "$NS" \
           -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || true)"
  [[ -n "$token" ]] || note "WARNING: no n8n-webhook-token secret; calls will be unauthenticated"

  cat > /tmp/n8n-call-probe.js <<'JS'
const token = process.env.PORTAL_TOKEN || '';
const paths = ['new-project', 'name-available', 'my-projects', 'delete-project'];
(async () => {
  for (const p of paths) {
    for (const prefix of ['webhook', 'webhook-test']) {
      let line = '    ' + (prefix + '/' + p).padEnd(34);
      try {
        const r = await fetch('http://localhost:5678/' + prefix + '/' + p, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Portal-Token': token },
          body: '{}'
        });
        const raw = await r.text();
        // TWO RESPONSE SHAPES. `respondWith: json` returns an OBJECT;
        // `respondWith: allIncomingItems` returns an ARRAY of item json.
        // Reading a field off the array yields undefined, which is how
        // my-projects was misreported as broken when it was answering
        // correctly. The portal already unwraps this (list_projects does
        // `if isinstance(body, list): body = body[0]`); the probe must too.
        let doc = null;
        try { doc = JSON.parse(raw); } catch (e) { doc = null; }
        if (Array.isArray(doc)) doc = doc.length ? doc[0] : {};
        const shape = doc && typeof doc === 'object'
          ? Object.keys(doc).slice(0, 6).join(',') : '(not an object)';
        const body = 'keys[' + shape + '] ' + raw.slice(0, 60).replace(/\s+/g, ' ');
        // 404 = not registered.  401/403 = registered, auth refused it.
        // 200/500 = registered and it ran.
        const verdict = r.status === 404 ? 'NOT REGISTERED'
                      : (r.status === 401 || r.status === 403) ? 'registered (auth refused)'
                      : 'registered';
        line += 'HTTP ' + String(r.status).padEnd(5) + verdict + '  ' + body;
      } catch (e) {
        line += 'request failed: ' + e.message;
      }
      console.log(line);
    }
  }
})();
JS
  $KUBECTL cp /tmp/n8n-call-probe.js "$NS/$POD:/tmp/n8n-call-probe.js"
  $KUBECTL exec -n "$NS" "$POD" -- env PORTAL_TOKEN="$token" \
    node /tmp/n8n-call-probe.js || true
  echo
  note "404 on BOTH prefixes = the path is not registered at all."
  note "404 on /webhook but 200 on /webhook-test = the workflow is saved"
  note "but not ACTIVE in the running instance."
}

reregister() {
  say "forcing re-activation (this CHANGES STATE)"
  note "Why this is not a no-op: import:workflow writes active=1 straight"
  note "into the row when the JSON says active:true. A later"
  note "'update:workflow --active=true' then sees it is ALREADY active and"
  note "does nothing - so the activation path that writes webhook_entity"
  note "never runs. Toggling it off and on forces that path."
  local ids="${2:-deleteProject001 myProjectsRead01}"
  for id in $ids; do
    note "deactivating $id"
    $KUBECTL exec -n "$NS" deploy/n8n -- n8n update:workflow --id="$id" --active=false
  done
  $KUBECTL rollout restart deploy/n8n -n "$NS"
  $KUBECTL rollout status deploy/n8n -n "$NS" --timeout=180s
  POD="$($KUBECTL get pod -n "$NS" -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
  for id in $ids; do
    note "activating $id"
    $KUBECTL exec -n "$NS" deploy/n8n -- n8n update:workflow --id="$id" --active=true
  done
  $KUBECTL rollout restart deploy/n8n -n "$NS"
  $KUBECTL rollout status deploy/n8n -n "$NS" --timeout=180s
  POD="$($KUBECTL get pod -n "$NS" -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
  probe_db
  probe_call
}

clean_stale() {
  say "stale webhook_entity rows"
  note "A row is STALE when its path is not the path its workflow's trigger"
  note "declares - typically left by an earlier import under a different"
  note "registration key. Problem #149: a stale row KEEPS ANSWERING across"
  note "restarts, so it is a live duplicate entry point, not dead data."

  cat > /tmp/n8n-clean-stale.js <<'JS'
const CANDIDATES = [
  '/usr/local/lib/node_modules/n8n/node_modules/sqlite3',
  '/usr/local/lib/node_modules/n8n/node_modules/@n8n/db/node_modules/sqlite3',
  'sqlite3',
];
let sqlite3 = null;
for (const p of CANDIDATES) { try { sqlite3 = require(p); break; } catch (e) {} }
if (!sqlite3) { console.log('    no sqlite3 module found'); process.exit(3); }

const APPLY = process.env.APPLY === '1';
const DB = '/home/node/.n8n/database.sqlite';
const db = new sqlite3.Database(DB,
  APPLY ? sqlite3.OPEN_READWRITE : sqlite3.OPEN_READONLY);
const all = sql => new Promise(r => db.all(sql, (e, x) => r(e ? { error: e.message } : x)));
const run = sql => new Promise(r => db.run(sql, function (e) { r(e ? { error: e.message } : this); }));

(async () => {
  const wfs = await all("SELECT id, name, nodes FROM workflow_entity");
  if (wfs.error) { console.log('    ERROR: ' + wfs.error); process.exit(3); }

  // What each workflow's trigger actually declares.
  const declared = {};
  wfs.forEach(w => {
    try {
      const nodes = typeof w.nodes === 'string' ? JSON.parse(w.nodes) : w.nodes;
      (nodes || []).filter(n => n.type === 'n8n-nodes-base.webhook')
        .forEach(n => {
          declared[String(w.id)] = declared[String(w.id)] || [];
          declared[String(w.id)].push((n.parameters || {}).path);
        });
    } catch (e) {}
  });

  const rows = await all("SELECT workflowId, webhookPath, method FROM webhook_entity");
  if (rows.error) { console.log('    ERROR: ' + rows.error); process.exit(3); }

  const stale = rows.filter(r => {
    const want = declared[String(r.workflowId)];
    if (!want) return true;                       // workflow gone entirely
    return !want.includes(r.webhookPath);         // path is not one it declares
  });

  console.log('    registered rows: ' + rows.length + ', stale: ' + stale.length);
  rows.forEach(r => {
    const want = declared[String(r.workflowId)];
    const bad = stale.includes(r);
    console.log('      ' + (bad ? 'STALE ' : '  ok  ') +
                String(r.method || '?').padEnd(6) +
                '/webhook/' + r.webhookPath +
                (bad ? '   (workflow declares: ' + (want ? want.join(',') : 'NOTHING') + ')' : ''));
  });

  if (!stale.length) { console.log('    nothing to clean.'); db.close(); return; }
  if (!APPLY) {
    console.log('');
    console.log('    DRY RUN. Re-run with --clean-stale --apply to delete these.');
    db.close();
    return;
  }
  for (const r of stale) {
    const q = "DELETE FROM webhook_entity WHERE workflowId='" +
              String(r.workflowId).replace(/'/g, "''") + "' AND webhookPath='" +
              String(r.webhookPath).replace(/'/g, "''") + "'";
    const res = await run(q);
    console.log('    deleted ' + (res.error ? 'FAILED: ' + res.error
                : (res.changes + ' row(s): /webhook/' + r.webhookPath)));
  }
  db.close();
})();
JS

  $KUBECTL cp /tmp/n8n-clean-stale.js "$NS/$POD:/tmp/n8n-clean-stale.js"
  if [[ "${2:-}" == "--apply" ]]; then
    note "APPLYING - this deletes rows and restarts n8n"
    $KUBECTL exec -n "$NS" "$POD" -- env APPLY=1 node /tmp/n8n-clean-stale.js
    $KUBECTL rollout restart deploy/n8n -n "$NS"
    $KUBECTL rollout status deploy/n8n -n "$NS" --timeout=180s
    POD="$($KUBECTL get pod -n "$NS" -l app=n8n -o jsonpath='{.items[0].metadata.name}')"
    note "verifying by CALLING - a deleted row must now 404 (#149)"
    probe_db
  else
    $KUBECTL exec -n "$NS" "$POD" -- node /tmp/n8n-clean-stale.js
  fi
}

case "$MODE" in
  --logs)       probe_logs ;;
  --clean-stale) clean_stale "$@" ;;
  --db)         probe_db ;;
  --call)       probe_call ;;
  --reregister) reregister "$@" ;;
  all)          probe_logs; probe_db; probe_call
                echo
                say "reading this report"
                note "webhook_entity EMPTY, or missing a row for an active"
                note "workflow  -> registration never happened. Run:"
                note "      ./n8n-webhook-probe.sh --reregister"
                note "webhook_entity has the row but calls still 404  -> the"
                note "path or method in the trigger node does not match what"
                note "you are calling. Compare the two tables above."
                ;;
  -h|--help)    awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else{exit}}' "$0" ;;
  *)            die "unknown argument: $MODE (try --help)" ;;
esac
