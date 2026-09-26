// Structural checks on n8n-workflow-provision.json, before importing.
//
// Exists because of a real failure: 'Create service' and 'Create ingress'
// declared authentication:genericCredentialType but carried NO
// `credentials` block. n8n then sent the request with no Authorization
// header, Kubernetes answered 401, and onError:continueRegularOutput
// swallowed it - so the workflow reported success while creating
// nothing. Every node in this file uses continueRegularOutput by design,
// which makes silent misconfiguration the expected failure mode rather
// than an unlikely one.
const vm = require('vm');
// Resolve relative to THIS FILE, not to a hardcoded workstation path.
// The old default was an absolute C:/ path, so running this on the kube
// VM threw ENOENT before a single check ran - and the deploy script that
// calls it as a preflight would have aborted on that.
const path = require('path');
// Workflows moved to <repo>/n8n/workflows/ and lost the redundant
// "n8n-workflow-" prefix. sibling() maps the old long name to the new
// short one, so the many call sites below did not each need editing.
const P = process.argv[2] ||
  path.join(__dirname, '..', '..', 'n8n', 'workflows', 'provision.json');
function sibling(longName) {
  const short = longName.replace(/^n8n-workflow-/, '');
  return path.join(path.dirname(P), short);
}
const w = JSON.parse(require('fs').readFileSync(P, 'utf8'));
let fails = 0;
const fail = m => { console.log('  FAIL  ' + m); fails++; };
const pass = m => console.log('  PASS  ' + m);

// 1. A node that declares generic auth must be bound to a credential.
const orphan = w.nodes
  .filter(n => n.parameters && n.parameters.genericAuthType && !n.credentials)
  .map(n => n.name);
orphan.length ? fail('nodes declare auth but bind no credential: ' + orphan)
              : pass('every generic-auth node is bound to a credential');

// 2. All bound credentials point at ids that the other nodes also use
//    (a typo'd id imports fine and fails at runtime).
const ids = new Set();
w.nodes.forEach(n => Object.values(n.credentials || {})
  .forEach(c => ids.add(c.id + '|' + c.name)));
console.log('  ----  credentials referenced: ' + [...ids].join(', '));

// 3. Every connection names a node that exists.
const names = new Set(w.nodes.map(n => n.name));
let dangling = [];
for (const [src, v] of Object.entries(w.connections)) {
  if (!names.has(src)) dangling.push(src + ' (source)');
  (v.main || []).forEach(o => (o || []).forEach(c => {
    if (!names.has(c.node)) dangling.push(src + ' -> ' + c.node);
  }));
}
dangling.length ? fail('connections reference missing nodes: ' + dangling)
                : pass('every connection names an existing node');

// 4. Every node except the trigger is reachable from the webhook.
const trigger = w.nodes.find(n => n.type.includes('webhook'));
const seen = new Set([trigger.name]);
const stack = [trigger.name];
while (stack.length) {
  const cur = stack.pop();
  const v = w.connections[cur];
  if (!v) continue;
  (v.main || []).forEach(o => (o || []).forEach(c => {
    if (!seen.has(c.node)) { seen.add(c.node); stack.push(c.node); }
  }));
}
const unreachable = w.nodes.map(n => n.name).filter(n => !seen.has(n));
unreachable.length ? fail('unreachable nodes: ' + unreachable)
                   : pass('every node is reachable from the webhook');

// 5. Code nodes must parse.
w.nodes.filter(n => n.type === 'n8n-nodes-base.code').forEach(n => {
  try { new vm.Script('(function(){' + n.parameters.jsCode + '})'); }
  catch (e) { fail('code node "' + n.name + '" does not parse: ' + e.message); }
});
pass('all code nodes parse');

// 6. Problem #116: an n8n expression must not contain an object literal,
//    whose nested }} breaks the template parser.
w.nodes.forEach(n => {
  JSON.stringify(n.parameters || {}).match(/"=\{\{[^"]*"/g)?.forEach(e => {
    if (/\{\s*\w+\s*:/.test(e)) fail('object literal in an expression on "' + n.name + '": ' + e.slice(0, 60));
  });
});
pass('no object literals inside expressions (Problem #116)');

// 7. Nomad jobs must not pin a datacenter that does not exist (#122).
const dc = JSON.stringify(w.nodes).match(/Datacenters['"]?\s*:\s*\[[^\]]*\]/g) || [];
dc.forEach(d => { if (!d.includes("'*'") && !d.includes('"*"')) fail('pinned datacenter: ' + d); });
pass('Nomad datacenters are not pinned (Problem #122)');


// 8. THE 2026-09-05 RESUBMISSION BUG. Every k8s node POSTed to a
//    COLLECTION endpoint, which is create-only: for an existing tenant
//    the API answers 409 AlreadyExists, onError:continueRegularOutput
//    swallows it, and the run reports success having changed nothing.
//    Execution 62 carried SIX such failures and still said success, and
//    the tenant stayed frozen at its first submission's image and port.
//
//    Objects a resubmission must be able to CHANGE have to use
//    server-side apply against the NAMED resource. Namespace, quota and
//    RoleBinding are deliberately excluded: the quota tier is recomputed
//    from the description each time, so applying it would silently
//    re-tier an existing tenant on an unrelated resubmit.
const MUTABLE = {
  'Create starter deployment': { name: 'starter', kind: 'Deployment' },
  // Was 'Deploy built image' creating a SECOND Deployment named `app`.
  // Now an in-place upgrade of `starter`, so a failed build leaves the
  // old pod serving (Part 23 item 16) instead of a Service-selector move.
  'Upgrade to the repo image': { name: 'starter', kind: 'Deployment' },
  'Create service':            { name: 'site-k8s', kind: 'Service' },
  'Create ingress':            { name: 'site',    kind: 'Ingress' },
};
const CREATE_ONLY = ['Create namespace', 'Create quota', 'Bind tenant identity'];

// 12. A CALL TARGET MUST NOT BE MARKED ACTIVE.
//     A workflow whose only trigger is executeWorkflowTrigger is invoked
//     by another workflow; nothing listens for it. Marking it active makes
//     n8n retry activation forever with
//       "has no node to start the workflow - at least one trigger, poller
//        or webhook node is required"
//     and, if an import script runs under `set -e`, that failure aborts
//     the run before the NEXT workflow is imported. That is how a
//     replacement delete workflow was never imported while its predecessor
//     stayed live and kept behaving the old way.
(function () {
  const fs5 = require('fs');
  const ACTIVATABLE = ['webhook', 'scheduleTrigger', 'cron', 'intervalTrigger',
                       'emailReadImap', 'rabbitmqTrigger'];
  ['n8n-workflow-nomad-namespace.json',
   'n8n-workflow-provision.json',
   'n8n-workflow-delete-project.json',
   'n8n-workflow-my-projects.json'].forEach(f => {
    const sib = sibling(f);
    if (!fs5.existsSync(sib)) return;
    const wf = JSON.parse(fs5.readFileSync(sib, 'utf8'));
    const listens = (wf.nodes || []).some(
      n => ACTIVATABLE.indexOf(n.type.split('.').pop()) !== -1);
    if (!listens && wf.active === true)
      fail('"' + f + '" has no listener trigger but is marked active - n8n '
           + 'will retry activation forever and fail the import that follows');
  });
  pass('no call-target workflow is marked active');
})();

// 11. NOTHING THAT NEEDS A FRESHLY BUILT IMAGE MAY RUN BEFORE THE BUILD.
//     Measured 2026-09-19 on tenant-grafanatest: the Deployment was
//     created at 19:26:08 and began pulling an image whose manifest was
//     not pushed until 19:29:58 - 3m50s during which every pull attempt
//     was guaranteed to fail. Kubernetes then backs off exponentially to
//     a 5-minute cap, so the tenant waited 20+ minutes for a 4-minute
//     build. Nomad had the same race with no wait at all.
//
//     The rule: a node consuming the built image must be DOWNSTREAM of
//     `Respond to portal`. The tenant is answered with a working
//     placeholder first, and the real image is patched in when it exists.
(function () {
  const conn = w.connections || {};
  const reach = (start) => {
    const seen = new Set([start]), q = [start];
    while (q.length) {
      const c = q.pop();
      ((conn[c] || {}).main || []).forEach(g => g.forEach(t => {
        if (!seen.has(t.node)) { seen.add(t.node); q.push(t.node); }
      }));
    }
    return seen;
  };
  // Reachability from the WEBHOOK, treating the responder as a barrier.
  // Checking only "is it downstream of Respond" is not enough: a node can
  // be BOTH downstream of the responder and reachable before it, which is
  // exactly the racing shape. What matters is whether it can be reached
  // WITHOUT passing through the responder.
  const reachBarrier = (start, barrier) => {
    const seen = new Set([start]), q = [start];
    while (q.length) {
      const c = q.pop();
      if (c === barrier) continue;
      ((conn[c] || {}).main || []).forEach(g => g.forEach(t => {
        if (!seen.has(t.node)) { seen.add(t.node); q.push(t.node); }
      }));
    }
    return seen;
  };
  const beforeRespond = reachBarrier('Submission from portal', 'Respond to portal');
  const afterRespond = reach('Respond to portal');
  const CONSUMERS = ['Upgrade to the repo image', 'Submit Nomad job (built image)'];
  let raced = 0;
  CONSUMERS.forEach(nm => {
    const n = w.nodes.find(x => x.name === nm);
    if (!n) { fail('missing node "' + nm + '" - the built image is deployed nowhere'); raced++; return; }
    if (beforeRespond.has(nm)) {
      raced++;
      fail('"' + nm + '" is reachable BEFORE "Respond to portal" - it races '
           + 'the build and leaves the tenant in ImagePullBackOff');
    } else if (!afterRespond.has(nm)) {
      raced++;
      fail('"' + nm + '" is not reachable from "Respond to portal" - the '
           + 'built image would never be deployed at all');
    }
  });
  if (!raced) pass('built-image deploys wait for the build instead of racing it');

  // Every build poll needs a $runIndex cap, or a Job that never reports
  // either way loops forever (Problem #141's other half).
  const POLLS = ['Repo build settled?', 'Nomad build settled?', 'Build settled?'];
  let capped = 0;
  POLLS.forEach(nm => {
    const n = w.nodes.find(x => x.name === nm);
    if (!n) { fail('missing poll gate "' + nm + '"'); return; }
    const expr = JSON.stringify(n.parameters || {});
    if (expr.indexOf('runIndex') === -1)
      fail('"' + nm + '" has no $runIndex cap - an unsettled Job loops forever');
    else capped++;
  });
  if (capped === POLLS.length) pass('every build poll is capped by $runIndex');

  // A poll that does not loop back is not a poll.
  [['Repo build settled?', 'Give the repo build time'],
   ['Nomad build settled?', 'Give the Nomad build time']].forEach(([gate, waitNode]) => {
    const outs = ((conn[gate] || {}).main || []).map(g => g.map(t => t.node));
    const falseBranch = outs[1] || [];
    if (falseBranch.indexOf(waitNode) === -1)
      fail('"' + gate + '" does not loop back to "' + waitNode + '"');
  });
  pass('each build poll loops back to its own wait node');
})();

const codeSrc = w.nodes.filter(x => x.type === 'n8n-nodes-base.code')
                       .map(x => x.parameters.jsCode).join('\n');

Object.keys(MUTABLE).forEach(nm => {
  const n = w.nodes.find(x => x.name === nm);
  if (!n) { fail('missing node "' + nm + '"'); return; }
  const p = n.parameters || {};
  const want = MUTABLE[nm];
  const url = p.url || '';

  if (p.method !== 'PATCH')
    fail('"' + nm + '" uses ' + p.method + ', not PATCH - a resubmission cannot update it');
  if (p.rawContentType !== 'application/apply-patch+yaml')
    fail('"' + nm + '" is not server-side apply (rawContentType=' + p.rawContentType + ')');
  if (p.contentType !== 'raw')
    fail('"' + nm + '" must send a raw body so the apply content type is unambiguous');
  if (!/fieldManager=/.test(url) || !/force=true/.test(url))
    fail('"' + nm + '" apply needs fieldManager and force=true: ' + url);

  // The URL must address the SAME object the body declares. If the two
  // drift, apply silently creates a SECOND object under the URL's name
  // instead of updating the intended one.
  const m = url.match(/\/([a-z0-9-]+)\?/);
  if (!m) fail('"' + nm + '" does not PATCH a named resource: ' + url);
  else if (m[1] !== want.name)
    fail('"' + nm + '" patches "' + m[1] + '" but should patch "' + want.name + '"');

  // Cross-check against the body actually built in the code node.
  const varName = (String(p.body || '').match(/json\.(\w+)/) || [])[1];
  if (varName) {
    const at = codeSrc.indexOf(varName + ' = JSON.stringify({');
    if (at !== -1) {
      const decl = codeSrc.slice(at, at + 400);
      const nameInBody = (decl.match(/name: '([a-z0-9-]+)'/) || [])[1];
      const kindInBody = (decl.match(/kind: '(\w+)'/) || [])[1];
      if (nameInBody && nameInBody !== want.name)
        fail('"' + nm + '" body declares metadata.name "' + nameInBody +
             '" but the URL patches "' + want.name + '"');
      if (kindInBody && kindInBody !== want.kind)
        fail('"' + nm + '" body declares kind "' + kindInBody + '", expected ' + want.kind);
    }
  }
});
pass('mutable tenant objects use server-side apply (2026-09-05 resubmission bug)');

CREATE_ONLY.forEach(nm => {
  const n = w.nodes.find(x => x.name === nm);
  if (n && n.parameters.method !== 'POST')
    fail('"' + nm + '" must stay create-only POST - applying it would ' +
         're-tier or re-bind an existing tenant');
});
pass('namespace, quota and RoleBinding stay create-only');

// 9. The response must distinguish a new tenant from a re-provisioned
//    one, so "success" is never ambiguous about whether anything changed.
const brNode = w.nodes.find(n => n.name === 'Build result') || { parameters: {} };
if (!/tenantState/.test(brNode.parameters.jsCode || ''))
  fail('Build result does not report tenantState (created vs updated)');
pass('Build result reports created vs updated');


// 10. THE NOMAD TENANT URL BRIDGE (2026-09-05). Kubernetes' Traefik
//     fronts a Nomad job on another host via a selector-less Service, a
//     hand-built EndpointSlice carrying the allocation's real host:port,
//     and a normal Ingress. Two failure modes are designed against here,
//     both of which actually happened on the Kubernetes side tonight.
const NOMAD_APPLY = {
  'Create nomad service':   { name: 'site-nomad-svc', kind: 'Service' },
  'Create nomad endpoints': { name: 'site-nomad', kind: 'EndpointSlice' },
  'Create nomad ingress':   { name: 'site',       kind: 'Ingress' },
};

Object.keys(NOMAD_APPLY).forEach(nm => {
  const n = w.nodes.find(x => x.name === nm);
  if (!n) { fail('missing node "' + nm + '"'); return; }
  const p = n.parameters || {};
  const want = NOMAD_APPLY[nm];
  const url = p.url || '';

  // (a) THE RESUBMISSION BUG (#130). A new allocation gets a NEW random
  //     port, so these must UPDATE, never create-only. POST here would
  //     409 on the second submission, get swallowed, and leave the tenant
  //     pointing at a port nothing listens on any more.
  if (p.method !== 'PATCH')
    fail('"' + nm + '" uses ' + p.method + ' - a new Nomad port could never overwrite the old');
  if (p.rawContentType !== 'application/apply-patch+yaml')
    fail('"' + nm + '" is not server-side apply');
  if (!/fieldManager=/.test(url) || !/force=true/.test(url))
    fail('"' + nm + '" apply needs fieldManager and force=true');
  const m = url.match(/\/([a-z0-9-]+)\?/);
  if (!m) fail('"' + nm + '" does not PATCH a named resource: ' + url);
  else if (m[1] !== want.name)
    fail('"' + nm + '" patches "' + m[1] + '" but should patch "' + want.name + '"');
});
pass('Nomad bridge objects use server-side apply (new port overwrites old)');

// (b) THE PORT BUG. The allocated port must be READ AND USED. A literal
//     port in the EndpointSlice body means the tenant gets a link that
//     cannot work - detected-and-logged is not the same as used.
const dns = w.nodes.find(n => n.name === 'Decide Nomad site');
if (!dns) fail('missing node "Decide Nomad site"');
else {
  const code = dns.parameters.jsCode || '';
  const slice = code.slice(code.indexOf('bodyNomadSlice'),
                           code.indexOf('bodyNomadIngress'));
  if (!slice) fail('Decide Nomad site does not build bodyNomadSlice');
  const portLine = (slice.match(/ports:\s*\[\{[^\]]*\}\]/) || [''])[0];
  if (!/port:\s*port\b/.test(portLine))
    fail('EndpointSlice port is not the port READ from the allocation: ' + portLine.slice(0, 80));
  if (/port:\s*[0-9]{2,}/.test(portLine))
    fail('EndpointSlice carries a LITERAL port - the tenant would get a dead link: ' + portLine.slice(0, 80));
  if (!/AllocatedResources/.test(code))
    fail('Decide Nomad site never reads AllocatedResources - where the real port lives');
  // The address must come from the allocation too, not be hardcoded.
  const epLine = (slice.match(/endpoints:\s*\[[^\]]*\]/) || [''])[0];
  if (/192\.168\./.test(epLine))
    fail('EndpointSlice hardcodes a host address instead of reading it: ' + epLine.slice(0, 80));
  // No URL may be emitted without a real port.
  if (!/haveAddr/.test(code))
    fail('Decide Nomad site does not gate the URL on actually having an address');
}
pass('Nomad EndpointSlice uses the port READ from the allocation, never a literal');

// (c) The Service that the EndpointSlice backs must have NO selector - a
//     selector would make Kubernetes manage (and wipe) the endpoints.
if (dns) {
  const code = dns.parameters.jsCode || '';
  const svc = code.slice(code.indexOf('bodyNomadService'), code.indexOf('bodyNomadSlice'));
  if (/selector/.test(svc))
    fail('the Nomad Service declares a selector - Kubernetes would overwrite the manual endpoints');
}
pass('the Nomad Service is selector-less');

// (d) The BUILT Nomad job must publish a port at all. It originally
//     declared no Networks block, so nothing was reachable and there was
//     no allocation port to read.
const anode = w.nodes.find(n => n.name === 'Analyse repo');
if (anode) {
  const src = anode.parameters.jsCode || '';
  // Anchor on the DECLARATION, not the first mention: a comment
  // elsewhere in this file also names bodyNomadBuiltJob, and slicing
  // from there stops at whatever `});` happens to come next - which
  // silently made this check inspect the wrong object when an
  // unrelated body was added between the two.
  const built = src.slice(src.indexOf('const bodyNomadBuiltJob'));
  const body = built.slice(0, built.indexOf('});') + 3);
  if (!/DynamicPorts/.test(body))
    fail('the built Nomad job declares no DynamicPorts - it would publish nothing');
  if (!/To:\s*appPort/.test(body))
    fail('the built Nomad job does not map the port the Dockerfile EXPOSEs');
  if (!/ports:\s*\['http'\]/.test(body))
    fail('the built Nomad job task does not attach the http port');
  // ORDERING: appPort must be computed BEFORE the job body uses it, or it
  // reads undefined and every tenant silently gets port 0.
  if (src.indexOf('let appPort') > src.indexOf('To: appPort'))
    fail('bodyNomadBuiltJob uses appPort BEFORE it is computed - it would be undefined');
}
pass('the built Nomad job publishes a dynamic port mapped to the real EXPOSE');

// (e) The allocation detail fetch is not optional: the LIST endpoint
//     returns a summary with no AllocatedResources, so a workflow that
//     only lists would never see a port.
if (!w.nodes.find(n => n.name === 'Read Nomad allocation'))
  fail('no "Read Nomad allocation" node - the list endpoint carries no ports');
const picker = w.nodes.find(n => n.name === 'Pick the live allocation');
if (!picker) fail('no "Pick the live allocation" node');
else {
  // Strip comments FIRST. An earlier version of this check passed on a
  // COMMENT that mentioned CreateIndex while the actual sort had been
  // deleted - the check could not fail, which is worse than no check.
  const NLc = String.fromCharCode(10);
  const live = (picker.parameters.jsCode || '').split(NLc)
                 .filter(l => l.trim().slice(0, 2) !== '//').join(NLc);
  if (!live.includes('.sort(') || !live.includes('CreateIndex'))
    fail('the allocation picker does not order by CreateIndex - after a ' +
         'resubmit it could pick the OLD allocation and its OLD port');
}
pass('the live allocation is fetched in detail and chosen newest-first');



// 11. A NODE THAT OUTPUTS ZERO ITEMS SILENTLY KILLS THE BRANCH, and every
//     node between the webhook and "Respond to portal" is load-bearing for
//     the user getting ANY answer at all.
//
//     Found for real: a brand-new Nomad user has no Nomad namespace, so the
//     job cannot exist, so "List Nomad allocations" 404s with NO items. n8n
//     does not run a node with no input, so the branch stopped dead -
//     "Build result" and "Respond to portal" never ran, the webhook never
//     answered, and the portal timed out at 60s showing a generic
//     "service unavailable" instead of the honest, operator-fixable
//     "your Nomad space has not been created yet".
//
//     onError:continueRegularOutput does NOT cover this. It stops a FAILING
//     node aborting the run; it says nothing about an EMPTY one ending the
//     branch. alwaysOutputData is the half that guarantees an item flows on.
['List Nomad allocations', 'Read Nomad allocation', 'Create nomad service',
 'Create nomad endpoints', 'Create nomad ingress'].forEach(nm => {
  const n = w.nodes.find(x => x.name === nm);
  if (!n) { fail('missing node "' + nm + '"'); return; }
  if (n.alwaysOutputData !== true)
    fail('"' + nm + '" lacks alwaysOutputData - an empty result would end the ' +
         'branch, and the portal would answer 503 instead of the real reason');
});
pass('the Nomad chain cannot die on an empty result (portal always gets an answer)');


// 12. PRIVILEGE SEPARATION FOR THE NOMAD MANAGEMENT TOKEN (2026-09-06).
//     Proven by experiment: a Nomad CLIENT token cannot create a namespace
//     under ANY policy - given namespace "*" write plus agent, operator,
//     node, quota and plugin write it still answers 403, while the same
//     request with a management token answers 200. Namespace CRUD is
//     management-only, so the token CANNOT be scoped down.
//
//     Least privilege therefore comes from isolation: one separate
//     two-node workflow holds the management credential and can perform
//     exactly one operation. THIS workflow must never hold or reference
//     it - that is the whole property, so it is asserted rather than
//     trusted to stay true.
const MGMT_CRED = 'nomadMgmtCred01';
const blob = JSON.stringify(w);

if (blob.includes(MGMT_CRED))
  fail('the main workflow references the Nomad MANAGEMENT credential (' +
       MGMT_CRED + ') - the token must live only in the Nomad Namespace Creator');
// A raw token value must never be inlined anywhere either.
if (/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.test(
      blob.replace(/"(id|webhookId)":"[^"]*"/g, '')))
  fail('a raw UUID that looks like a Nomad token is inlined in the main workflow');
pass('the main workflow holds NO Nomad management credential');

// It must reach the namespace creator ONLY by workflow reference.
const ens = w.nodes.find(n => n.name === 'Ensure Nomad namespace');
if (!ens) fail('missing node "Ensure Nomad namespace"');
else {
  if (ens.type !== 'n8n-nodes-base.executeWorkflow')
    fail('"Ensure Nomad namespace" must be an Execute Workflow node, not a direct call');
  if (ens.credentials)
    fail('"Ensure Nomad namespace" carries credentials - it must only reference a workflow ID');
  // Problem #135 again: this must not be able to end the branch.
  if (ens.alwaysOutputData !== true)
    fail('"Ensure Nomad namespace" lacks alwaysOutputData - a failure would end the ' +
         'branch and the portal would answer 503 instead of the real reason');
  if (ens.onError !== 'continueRegularOutput')
    fail('"Ensure Nomad namespace" must not abort the run on failure');
}
pass('the namespace creator is reached only by workflow reference, and cannot end the branch');

// No node in the main workflow may talk to Nomad's namespace API directly -
// that is the sub-workflow's single reason to exist.
w.nodes.forEach(n => {
  const u = (n.parameters && n.parameters.url) || '';
  if (/4646\/v1\/namespace/.test(u))
    fail('"' + n.name + '" calls the Nomad namespace API directly - that belongs ' +
         'only in the Nomad Namespace Creator');
});
pass('no node here touches the Nomad namespace API directly');


// 13. AI-ASSISTED DOCKERFILE GENERATION (2026-09-06). The model produces
//     TEXT; everything that follows must be as constrained as the
//     human-written path, and the retry must be genuinely capped.
const aiCheckers = ['Check the generated Dockerfile', 'Check the retry Dockerfile']
  .map(n => w.nodes.find(x => x.name === n));

aiCheckers.forEach((n, i) => {
  if (!n) { fail('missing AI Dockerfile checker #' + (i + 1)); return; }
  const src = n.parameters.jsCode || '';

  // (a) NO SPECIAL TREATMENT. The sandbox must be identical to the
  //     human-written build: same SA, same dropped capabilities, no
  //     service-account token. An AI-authored Dockerfile is exactly as
  //     untrusted as a stranger's on public GitHub - the sandbox is the
  //     control, so it must not be relaxed for convenience.
  if (!/serviceAccountName: 'builder'/.test(src))
    fail('AI build does not run as the sandboxed `builder` service account');
  if (!/drop: \['ALL'\]/.test(src))
    fail('AI build does not drop ALL capabilities');
  if (!/automountServiceAccountToken: false/.test(src))
    fail('AI build mounts a service account token');
  if (/privileged: true/.test(src))
    fail('AI build requests privileged mode');
  if (!/activeDeadlineSeconds: 900/.test(src))
    fail('AI build is not time-bounded - a hung build would never resolve');

  // (b) THE GENERATED TEXT IS VALIDATED, not trusted. A model that
  //     ignores "no fences" must not be able to produce a broken build.
  if (!/```/.test(src) || !/replace\(/.test(src))
    fail('AI checker does not strip markdown fences from the generated text');
  if (!/hasFrom/.test(src))
    fail('AI checker does not require a real FROM line');
  if (!/usable/.test(src))
    fail('AI checker has no usable/unusable gate');

  // (c) The port comes from the generated EXPOSE, like every other port
  //     in this system, and its provenance is reported.
  if (!/EXPOSE/.test(src) || !/aiPortSource/.test(src))
    fail('AI checker does not read EXPOSE / report where the port came from');
});
pass('AI builds use the identical sandbox and the generated text is validated');

// (d) EXACTLY ONE RETRY. Capped by construction - two generate nodes and
//     two build-start nodes, no more - rather than by a counter that
//     could drift. An unbounded retry would burn the build namespace's
//     two concurrent slots indefinitely.
const gens = w.nodes.filter(n => /^Generate a Dockerfile/.test(n.name));
const starts = w.nodes.filter(n => /^Start AI build/.test(n.name));
if (gens.length !== 2)
  fail('expected exactly 2 Dockerfile generation nodes (one retry), found ' + gens.length);
if (starts.length !== 2)
  fail('expected exactly 2 AI build nodes (one retry), found ' + starts.length);
// The second failure must not loop back into generation.
const retryIf = w.connections['Retry succeeded?'];
const retryFalse = (retryIf && retryIf.main && retryIf.main[1]) || [];
if (retryFalse.some(c => /Generate|Start AI build/.test(c.node)))
  fail('a failed retry loops back into another generation - the cap is not real');
pass('the AI retry is capped at exactly one, by construction');

// (e) THE HONEST FALLBACK MUST SURVIVE. The whole AI attempt hangs off
//     `Respond to portal`, so the tenant already has a working starter
//     site and an answer before any of it runs. If that link is ever
//     moved inline, the portal would wait minutes for a build and time
//     out with a generic 503 (Problem #135).
const respond = w.connections['Respond to portal'];
const hangsOff = respond && respond.main && respond.main[0] &&
  respond.main[0].some(c => c.node === 'Try an AI Dockerfile?');
if (!hangsOff)
  fail('the AI attempt does not hang off "Respond to portal" - the user would ' +
       'wait for a real build and the portal would time out (Problem #135)');
// The starter must still be what a no-Dockerfile tenant gets first.
const needsK8s = w.connections['Needs a k8s workload?'];
const starterFirst = needsK8s && needsK8s.main && needsK8s.main[0] &&
  needsK8s.main[0].some(c => c.node === 'Create starter deployment');
if (!starterFirst)
  fail('a no-Dockerfile tenant no longer gets the starter site first - the ' +
       'honest fallback has been removed from the answer path');
pass('the tenant is answered with a working starter before any AI build runs');

// (f) SCOPE: single container only. The prompt must say so - a generated
//     compose-style app would need an orchestrated set of objects this
//     feature does not create.
const promptNode = w.nodes.find(n => n.name === 'Write the Dockerfile prompt');
if (!promptNode) fail('missing node "Write the Dockerfile prompt"');
else {
  const p = promptNode.parameters.jsCode || '';
  if (!/ONE container only/.test(p))
    fail('the Dockerfile prompt does not constrain the model to a single container');
  if (!/SQLite/.test(p))
    fail('the prompt does not state that an embedded database is acceptable');
}
pass('the generator is constrained to single-container projects');


// (g) The AI build must use the SAME time bound as the human-written
//     path. A shorter one killed two correct Dockerfiles and then spent
//     the single retry trying to fix a file that was never wrong.
aiCheckers.forEach((n, i) => {
  if (!n) return;
  if (!/activeDeadlineSeconds: 900/.test(n.parameters.jsCode || ""))
    fail("AI build #" + (i+1) + " does not use the 900s bound the human path uses");
});
// A timeout must not trigger the self-correction retry.
const worth = w.nodes.find(n => n.name === "Worth a second try?");
if (!worth) fail("no timeout filter before the retry - a DeadlineExceeded would ask the model to fix a Dockerfile that was never wrong");
else if (!/DeadlineExceeded/.test(JSON.stringify(worth.parameters)))
  fail("the retry filter does not test for DeadlineExceeded");
pass("AI builds share the human time bound, and a timeout never triggers the retry");


// (h) A successful AI build must be deployed as soon as it FINISHES, not
//     on a timer. A fixed 930s wait left a tenant on the old image for
//     ~14 minutes after a 68s build - indistinguishable, from outside,
//     from the update never happening at all. Poll instead, and cap the
//     loop so a check that errors every time cannot spin forever.
[['Give the AI build time', 'Build settled?'],
 ['Give the retry time', 'Retry settled?']].forEach(([waitName, gateName]) => {
  const wn = w.nodes.find(n => n.name === waitName);
  const gate = w.nodes.find(n => n.name === gateName);
  if (!wn) { fail('missing wait node "' + waitName + '"'); return; }
  if (wn.parameters.amount > 60)
    fail('"' + waitName + '" waits ' + wn.parameters.amount + 's on a timer - a fast ' +
         'build would sit undeployed for minutes; poll instead');
  if (!gate) { fail('missing settle gate "' + gateName + '"'); return; }
  const p = JSON.stringify(gate.parameters);
  if (!/succeeded/.test(p) || !/failed/.test(p))
    fail('"' + gateName + '" does not test for a settled Job');
  if (!/runIndex/.test(p))
    fail('"' + gateName + '" has no iteration cap - a failing check would loop forever');
  const back = (w.connections[gateName] || {}).main || [];
  if (!(back[1] || []).some(c => c.node === waitName))
    fail('"' + gateName + '" does not loop back to "' + waitName + '"');
});
pass('AI builds are polled to completion and deployed as soon as they finish');


// 14. THE TWO PLATFORMS MUST NOT SHARE A SERVICE (2026-09-07).
//     Kubernetes fills a Service's endpoints from its SELECTOR; the Nomad
//     bridge supplies a hand-built EndpointSlice. Both mechanisms are
//     valid, and both stay live if they are pointed at the same Service.
//     Measured on a real tenant: THREE ready endpoints on one Service -
//     a leftover controller slice, a mirror of a legacy Endpoints object,
//     and the Nomad slice - so two thirds of requests reached the old
//     Kubernetes pod regardless of the platform just chosen. Removing a
//     selector does not remove the endpoints created under it, and n8n
//     has no `delete` on anything, by design.
//
//     One Ingress still exists and is re-pointed each submission, so the
//     tenant's single URL follows the CURRENT project.
const dsCode = (w.nodes.find(n => n.name === 'Decide site') || {parameters:{}}).parameters.jsCode || '';
const dnCode = (w.nodes.find(n => n.name === 'Decide Nomad site') || {parameters:{}}).parameters.jsCode || '';
const k8sSvc = (dsCode.match(/kind: 'Service',\s*\n\s*metadata: \{ name: '([a-z0-9-]+)'/) || [])[1];
const nomadSvc = (dnCode.match(/kind: 'Service',\s*\n\s*metadata: \{ name: '([a-z0-9-]+)'/) || [])[1];

if (!k8sSvc) fail('cannot find the Kubernetes Service name in "Decide site"');
if (!nomadSvc) fail('cannot find the Nomad Service name in "Decide Nomad site"');
if (k8sSvc && nomadSvc && k8sSvc === nomadSvc)
  fail('both platforms use the Service "' + k8sSvc + '" - a selector-based and a ' +
       'hand-built endpoint mechanism would both stay live on it, and stale ' +
       'endpoints would keep serving the old platform');

// The Nomad slice must back the NOMAD Service, or it backs nothing.
const sliceSvc = (dnCode.match(/'kubernetes\.io\/service-name': '([a-z0-9-]+)'/) || [])[1];
if (sliceSvc !== nomadSvc)
  fail('the Nomad EndpointSlice labels service-name "' + sliceSvc + '" but the ' +
       'Nomad Service is "' + nomadSvc + '" - the slice would back nothing');

// Each platform's Ingress must point at ITS OWN Service.
const k8sBackend = (dsCode.match(/backend: \{ service: \{ name: '([a-z0-9-]+)'/) || [])[1];
const nomadBackend = (dnCode.match(/backend: \{ service: \{ name: '([a-z0-9-]+)'/) || [])[1];
if (k8sBackend !== k8sSvc)
  fail('the Kubernetes Ingress points at "' + k8sBackend + '", not its own Service "' + k8sSvc + '"');
if (nomadBackend !== nomadSvc)
  fail('the Nomad Ingress points at "' + nomadBackend + '", not its own Service "' + nomadSvc + '"');

// Still exactly ONE Ingress object, so the URL follows the current project.
const ingressNames = new Set();
['Create ingress', 'Create nomad ingress'].forEach(n => {
  const node = w.nodes.find(x => x.name === n);
  if (node) { const m = (node.parameters.url || '').match(/\/ingresses\/([a-z0-9-]+)\?/); if (m) ingressNames.add(m[1]); }
});
if (ingressNames.size !== 1)
  fail('the platforms write different Ingress objects (' + [...ingressNames].join(', ') +
       ') - a switch would leave the old hostname routed to the old platform');
pass('each platform owns its Service, and one Ingress follows the current project');


// 15. THE DOCKERFILE'S REAL FILENAME (2026-09-08). Git is case-sensitive
//     and `dockerfile` is as valid as `Dockerfile`. Detection was always
//     case-insensitive, but two places downstream hardcoded the
//     capitalised name: Kaniko's --dockerfile flag (so the build failed)
//     and the raw fetch used to read EXPOSE (so the port silently
//     defaulted to 80). Both must carry the ACTUAL filename.
const arCode = (w.nodes.find(n => n.name === 'Analyse repo') || {parameters:{}}).parameters.jsCode || '';
if (/'--dockerfile=Dockerfile'/.test(arCode))
  fail('the Kaniko flag hardcodes "Dockerfile" - any repo spelling it ' +
       'lowercase fails to build (Problem #143)');
if (!/--dockerfile='\s*\+\s*\(?dockerfileName/.test(arCode))
  fail('the Kaniko flag does not use the detected dockerfileName');
if (!/dockerfileName = f\.name/.test(arCode))
  fail('Analyse repo never captures the real Dockerfile filename');
// Detection itself must stay case-insensitive.
if (!/f\.name\.toLowerCase\(\)/.test(arCode))
  fail('Dockerfile detection is no longer case-insensitive');

const rdUrl = ((w.nodes.find(n => n.name === 'Repo dockerfile') || {parameters:{}}).parameters.url) || '';
if (/\/HEAD\/Dockerfile$/.test(rdUrl))
  fail('"Repo dockerfile" fetches a hardcoded "Dockerfile" - a lowercase ' +
       'repo 404s and the port silently falls back to 80');
if (!/toLowerCase\(\) === 'dockerfile'/.test(rdUrl))
  fail('"Repo dockerfile" does not resolve the real filename from the listing');
pass('the Dockerfile\'s real filename is used for both the build and the port read');


// 16. AI-GENERATED DOCKERFILES ON NOMAD (2026-09-08). Same generation,
//     same sandbox, same retry - only the deployment of a winning image
//     differs. The invariants that must not drift:
const aiGate = w.nodes.find(n => n.name === 'Try an AI Dockerfile?');
if (!aiGate) fail('missing node "Try an AI Dockerfile?"');
else {
  const g = JSON.stringify(aiGate.parameters);
  // The AI must NEVER generate when the repo already ships a Dockerfile.
  if (!/!\$\('Analyse repo'\)\.first\(\)\.json\.hasDockerfile/.test(g))
    fail('the AI gate no longer requires the repo to have NO Dockerfile - it ' +
         'would overwrite a working one the author supplied');
  // 'no Dockerfile found' and 'we could not look' must not be conflated:
  // hasDockerfile comes from api.github.com, which can simply be down.
  if (!/repoAnalysed/.test(g))
    fail('the AI gate does not require repoAnalysed - a failed GitHub listing ' +
         'would look like "no Dockerfile" and the AI would overwrite one the author shipped');
  if (!/'kubernetes'/.test(g) || !/'nomad'/.test(g))
    fail('the AI gate does not cover both platforms');
}
pass('the AI generates only when NO Dockerfile exists, for both platforms');

// The Nomad upgrade must submit the image over the LAN registry address:
// Nomad runs on another VM and cannot route to a ClusterIP.
const wbCode = (w.nodes.find(n => n.name === 'Which build won?') || {parameters:{}}).parameters.jsCode || '';
if (!/10\.43\.200\.50:5000'[\s\S]{0,40}192\.168\.1\.50:5000/.test(wbCode))
  fail('the Nomad AI image is not rewritten to the LAN registry address - ' +
       'Nomad cannot pull from a ClusterIP');
// Nomad's default restart policy kills a job whose image is not yet there.
if (!/RestartPolicy/.test(wbCode))
  fail('the Nomad AI job declares no RestartPolicy - Nomad gives up after 2 ' +
       'attempts and the allocation dies permanently (Problem #133)');
if (!/DynamicPorts/.test(wbCode) || !/src\.aiPort/.test(wbCode))
  fail('the Nomad AI job does not publish the port read from the generated EXPOSE');
pass('the Nomad AI job pulls over the LAN, retries, and publishes the generated port');

// The slice must carry the port read from the NEW allocation, never a
// constant and never the previous one.
const rt = w.nodes.find(n => n.name === 'Point Nomad at the AI image');
if (!rt) fail('missing node "Point Nomad at the AI image"');
else {
  const s = rt.parameters.jsCode || '';
  if (!/AllocatedResources/.test(s))
    fail('the Nomad AI route does not read the allocation for its port');
  if (/port:\s*[0-9]{2,}/.test(s))
    fail('the Nomad AI EndpointSlice carries a LITERAL port');
  if (!/'kubernetes\.io\/service-name': 'site-nomad-svc'/.test(s))
    fail('the Nomad AI slice does not back site-nomad-svc - it would back nothing');
  if (!/haveAddr/.test(s))
    fail('the Nomad AI route does not gate on actually having an address');
}
// Newest allocation first, or a replaced job hands back the OLD port.
const pk = w.nodes.find(n => n.name === 'Pick the AI allocation');
if (!pk) fail('missing node "Pick the AI allocation"');
else {
  const live = (pk.parameters.jsCode || '').split(String.fromCharCode(10))
                 .filter(l => l.trim().slice(0, 2) !== '//').join(String.fromCharCode(10));
  if (!live.includes('.sort(') || !live.includes('CreateIndex'))
    fail('the AI allocation picker does not order newest-first - replacing the ' +
         'job leaves the old allocation listed with the OLD port');
}
// The placement poll must be capped.
const pl = w.nodes.find(n => n.name === 'AI allocation placed?');
if (pl && !/runIndex/.test(JSON.stringify(pl.parameters)))
  fail('"AI allocation placed?" has no iteration cap - a job that never places would loop forever');
pass('the Nomad AI route reads its port from the newest allocation, with a capped poll');


// 17. NAMESPACE OWNERSHIP (Phase 1 of named projects, 2026-09-08).
//     A 409 AlreadyExists on Create namespace used to mean "fine, it is a
//     resubmit" - correct only while a namespace can ONLY ever be your
//     own. Once project names are user-chosen and globally unique, a 409
//     can mean SOMEONE ELSE OWNS THAT NAME, and carrying on would deploy
//     into their namespace. This is a tenant-isolation property, so it is
//     asserted rather than trusted to survive future edits.
const own = w.nodes.find(n => n.name === 'Is it ours to use?');
if (!own) fail('missing node "Is it ours to use?" - nothing verifies who owns the namespace');
else {
  const s = own.parameters.jsCode || '';
  // Must read ownership from the object, not assume it.
  if (!/labels\.owner/.test(s) || !/labels\.tenant/.test(s))
    fail('the ownership check does not read BOTH owner and tenant labels - a ' +
         'namespace created before this change would lock its owner out');
  if (!/owner === v\.username/.test(s))
    fail('the ownership check does not compare the owner to the submitting user');
  // FAIL CLOSED: unreadable or unlabelled must not count as ours.
  if (!/readable/.test(s))
    fail('the ownership check does not require the namespace to be readable - ' +
         'an unknown owner would be treated as ours');
}
const gate = w.nodes.find(n => n.name === 'Ours?');
if (!gate) fail('missing gate "Ours?"');
else {
  const outs = (w.connections['Ours?'] || {}).main || [];
  const yes = (outs[0] || []).map(c => c.node);
  const no = (outs[1] || []).map(c => c.node);
  if (!yes.includes('Create quota'))
    fail('the owned path does not continue to provisioning');
  if (!no.includes('Build result'))
    fail('a refused name does not reach Build result - the user would get no ' +
         'answer at all rather than an honest refusal');
  if (no.some(n => /quota|binding|deployment|service|ingress|nomad/i.test(n)))
    fail('the REFUSED path reaches a provisioning node - it would deploy into ' +
         'a namespace owned by someone else');
}
// Nothing may provision before the check runs.
const nsOut = ((w.connections['Create namespace'] || {}).main || [])[0] || [];
if (!nsOut.some(c => c.node === 'Read the namespace'))
  fail('Create namespace does not lead to the ownership read - provisioning ' +
       'would proceed on a 409 without knowing whose namespace it is');
if (nsOut.some(c => c.node === 'Create quota'))
  fail('Create namespace still goes straight to Create quota, bypassing the ownership check');
// A refusal must not be reported as an update - nothing was created or changed.
const brc = (w.nodes.find(n => n.name === 'Build result') || {parameters:{}}).parameters.jsCode || '';
if (!brc.includes("if (nameTaken) tenantState = 'refused'"))
  fail('a refused name is still reported as created/updated - it claims work that never happened');
pass('namespace ownership is verified before anything is provisioned, and fails closed');

// The project name is validated at the boundary and reserved names blocked.
const viCode = (w.nodes.find(n => n.name === 'Validate input') || {parameters:{}}).parameters.jsCode || '';
if (!/RESERVED/.test(viCode))
  fail('Validate input has no reserved-name list');
for (const r of ['kube-system', 'vault', 'dex', 'n8n', 'signup']) {
  if (!new RegExp("'" + r + "'").test(viCode))
    fail('reserved name "' + r + '" is not blocked');
}
if (!/\^\[a-z\]\[a-z0-9-\]/.test(viCode))
  fail('the project name is not constrained to a DNS-1123 label');
if (!/\^\(kube-\|proj-\|tenant-\)/.test(viCode))
  fail('platform-owned name prefixes are not blocked');
pass('project names are DNS-safe and reserved names are blocked at the boundary');


// 18. THE NAME-AVAILABILITY CHECK (Phase 2, 2026-09-08). It lives in its
//     own workflow, so its reserved-word list is a SECOND COPY. A name
//     the check calls free but the provisioner then rejects is the worst
//     of both worlds, so the two copies are asserted identical.
try {
  const fs2 = require('fs');
  const sib = sibling('n8n-workflow-name-check.json');
  if (fs2.existsSync(sib)) {
    const nc = JSON.parse(fs2.readFileSync(sib, 'utf8'));
    const grab = src => {
      const i = src.indexOf('const RESERVED');
      if (i < 0) return null;
      return src.slice(i, src.indexOf('];', i)).replace(/\s+/g, '');
    };
    const provList = grab((w.nodes.find(n => n.name === 'Validate input') || {parameters:{}}).parameters.jsCode || '');
    const chkNode = nc.nodes.find(n => n.name === 'Is the name usable at all?');
    const chkList = chkNode ? grab(chkNode.parameters.jsCode || '') : null;
    if (!provList || !chkList) fail('a reserved-word list is missing from one of the two workflows');
    else if (provList !== chkList)
      fail('the reserved-word lists have DRIFTED between the provisioning workflow ' +
           'and the availability check - a name could be called free and then refused');

    // The check must never report "free" when a lookup failed.
    const ans = nc.nodes.find(n => n.name === 'Answer');
    if (!ans) fail('the availability check has no Answer node');
    else {
      const s = ans.parameters.jsCode || '';
      if (!/'unknown'/.test(s))
        fail('the availability check has no unknown state - a failed lookup would ' +
             'be reported as an available name');
      if (!/=== null/.test(s))
        fail('the availability check does not distinguish "not found" from "could not tell"');
    }
    // It must consult BOTH platforms: they share one hostname space.
    const names = nc.nodes.map(n => n.name);
    if (!names.includes('Taken on Kubernetes?') || !names.includes('Taken on Nomad?'))
      fail('the availability check does not consult both platforms');
    // And hold no management credential.
    if (JSON.stringify(nc).includes('nomadMgmtCred01'))
      fail('the availability check references the Nomad MANAGEMENT credential - it only needs to read');
    pass('the availability check agrees with the provisioner and never guesses "free"');
  }
} catch (e) { fail('availability-check validation errored: ' + e.message); }


// 19. THE AVAILABILITY CHECK IS CALLED BY THE PORTAL (Phase 3, 2026-09-09).
//     It gained a webhook trigger beside the Execute Workflow one. Both
//     feed the same node, so there stays exactly ONE implementation of
//     the rules - and the webhook must be authenticated, like the
//     provisioning one.
try {
  const fs3 = require('fs');
  const sib3 = sibling('n8n-workflow-name-check.json');
  if (fs3.existsSync(sib3)) {
    const nc = JSON.parse(fs3.readFileSync(sib3, 'utf8'));
    const hook = nc.nodes.find(n => n.type === 'n8n-nodes-base.webhook');
    if (!hook) fail('the availability check has no webhook trigger - the portal cannot call it');
    else {
      if (hook.parameters.authentication !== 'headerAuth')
        fail('the availability webhook is UNAUTHENTICATED - anyone reaching n8n could enumerate names');
      if (!JSON.stringify(hook.credentials || {}).includes('portalHookCred01'))
        fail('the availability webhook does not use the portal token credential');
    }
    // Both triggers must converge on the same rules node.
    const conns = nc.connections || {};
    const targets = new Set();
    for (const src of ['Called by the portal', 'Asked by the portal']) {
      ((conns[src] || {}).main || []).forEach(o => o.forEach(c => targets.add(c.node)));
    }
    if (targets.size !== 1)
      fail('the two triggers feed different nodes (' + [...targets].join(', ') +
           ') - the rules would exist twice and could diverge');
    // The shared node must cope with both payload shapes.
    const shape = nc.nodes.find(n => n.name === 'Is the name usable at all?');
    if (shape && !/raw\.body \|\| raw/.test(shape.parameters.jsCode || ''))
      fail('the rules node does not accept both trigger shapes - a webhook nests the payload under .body');
    pass('the availability check is portal-callable, authenticated, and has one rule set');
  }
} catch (e) { fail('availability trigger validation errored: ' + e.message); }


// 20. THE READ PATH'S OWNERSHIP BOUNDARY (Phase 4, 2026-09-09).
//     /welcome lists a user's projects. The boundary is a Kubernetes
//     LABEL SELECTOR bound to the session-derived username - the API
//     server filters, so no per-item decision here can be wrong. That is
//     Problem #147's rule reused rather than reimplemented.
//
//     MEASURED, not assumed: the same token on the same endpoint WITHOUT
//     a selector returns every namespace in the cluster (23 of them,
//     including every tenant's). A missing selector is a total leak.
try {
  const fs4 = require('fs');
  const sib4 = sibling('n8n-workflow-my-projects.json');
  if (fs4.existsSync(sib4)) {
    const mp = JSON.parse(fs4.readFileSync(sib4, 'utf8'));

    // Every namespace read MUST be safe, but the two SHAPES of read are
    // not the same risk and are checked differently:
    //
    //   COLLECTION  /namespaces?...   returns many. Without a selector it
    //               returns EVERY tenant's namespace, so it must carry one
    //               bound to the requesting user. This is the original rule
    //               and it is unchanged.
    //   SCOPED      /namespaces/<ns>/...  returns one named object. A
    //               selector is meaningless here; what matters is where the
    //               NAME came from. It must be interpolated from the
    //               already-filtered project list, never from the request
    //               body - otherwise the caller picks the namespace and the
    //               filtering upstream buys nothing.
    mp.nodes.filter(n => n.type === 'n8n-nodes-base.httpRequest').forEach(n => {
      const u = n.parameters.url || '';
      if (!/\/namespaces/.test(u)) return;
      const scoped = /\/namespaces\/[^?]/.test(u);
      if (scoped) {
        if (/\$json\.body|\$json\.username|body\./.test(u))
          fail('"' + n.name + '" builds a namespace path from REQUEST INPUT - ' +
               'the caller would choose which tenant is read');
        if (!/\{\{\s*\$json\.namespace\s*\}\}/.test(u))
          fail('"' + n.name + '" reads a namespace by a name that does not come ' +
               'from the selector-filtered list');
        return;
      }
      if (!/labelSelector=/.test(u))
        fail('"' + n.name + '" lists namespaces with NO label selector - it would ' +
             'return every tenant in the cluster');
      if (!/(owner|tenant)%3D\{\{/.test(u))
        fail('"' + n.name + '" does not bind its selector to the requesting user');
      if (/labelSelector=[^{]*$/.test(u))
        fail('"' + n.name + '" has a constant selector - it must come from the caller');
    });

    // A blank/malformed username must be refused WITHOUT querying.
    const who = mp.nodes.find(n => n.name === 'Whose projects?');
    if (!who) fail('the read path has no username validation node');
    else if (!/usable/.test(who.parameters.jsCode || ''))
      fail('the read path does not validate the username - a blank one would widen the selector');
    const gate = mp.nodes.find(n => n.name === 'Is that a real user?');
    if (!gate) fail('the read path has no gate before querying');
    else {
      const outs = (mp.connections['Is that a real user?'] || {}).main || [];
      const no = (outs[1] || []).map(c => c.node);
      if (no.some(n => /Projects they own|legacy/i.test(n)))
        fail('a refused username still reaches a namespace query');
      if (!no.some(n => /Refuse/i.test(n)))
        fail('there is no refusal branch - a bad username would fall through');
    }

    // Read-only: it must never write.
    mp.nodes.filter(n => n.type === 'n8n-nodes-base.httpRequest').forEach(n => {
      const m = (n.parameters.method || 'GET').toUpperCase();
      if (m !== 'GET')
        fail('"' + n.name + '" uses ' + m + ' - the project list must be read-only');
    });

    // Authenticated, like every other portal-facing webhook.
    const hook = mp.nodes.find(n => n.type === 'n8n-nodes-base.webhook');
    if (!hook) fail('the read path has no webhook trigger');
    else if (hook.parameters.authentication !== 'headerAuth')
      fail('the project-list webhook is UNAUTHENTICATED - anyone reaching n8n could read any user\'s projects');
    pass('the project list is read-only, authenticated, and filtered by a selector bound to the caller');
  }
} catch (e) { fail('read-path validation errored: ' + e.message); }

console.log(fails === 0 ? '\nWORKFLOW STRUCTURE OK' : '\n' + fails + ' STRUCTURAL FAILURE(S)');
process.exit(fails);
