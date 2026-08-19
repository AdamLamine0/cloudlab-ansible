# CloudLab hybrid app — `portal` (k3s) + `hostprobe` (Nomad)

This is the `[TODO] Real hybrid app` phase from Part 15 of the master
handoff. It replaces the placeholder `hello` job as the thing the lab
actually runs, and it is the first workload that uses the §18 tenant
isolation for something other than a proof script.

Two tenants, `user1` and `user2`, each get their own copy. Nothing here
touches the `default` Nomad namespace, so the existing `hello` job stays
where it is as the "did I just break something" baseline.

---

## 1. The design question, answered

Part 15 flagged one thing to settle before writing any code:

> what work GENUINELY needs to span both orchestrators, rather than
> being arbitrarily split to make a point

The answer used here is **heterogeneous placement, not a split
application**:

| Component | Runs on | Why it cannot sensibly run on the other side |
|---|---|---|
| `hostprobe` | Nomad, `.51` | It reports the state of the Nomad VM's own host — uptime, load, memory, filesystem, kernel. A pod on `.50` cannot observe `.51`, because k3s does not manage `.51` at all and never will. The work is *located*, and its location is the point. |
| `portal` | k3s, `.50` | Long-lived HTTP service that wants an Ingress, a namespace with a ResourceQuota, RBAC-scoped tenant access and a rolling update. All four already exist on the k8s side (Parts 3 and 8) and none exist on the Nomad side. |

Consul is the only thing joining them, over exactly the DNS path proven
in Part 10: pod → CoreDNS `consul:53` → Consul DNS on `.51:8600` →
catalog → the Nomad allocation's real address.

The honest version for the final report: nobody *has* to build it this
way — you could run a node-exporter in a privileged DaemonSet, or run
the whole thing on one orchestrator. What this app demonstrates is the
realistic case where an org already has both, and a service on one side
needs a service on the other side that isn't going to move. That is a
migration-shaped problem, and it's the one the whole Consul/Nomad half
of this lab exists to answer.

Rejected alternatives, and why:

- **Split a web app into "frontend on k8s, backend on Nomad".** The
  split would be arbitrary — both halves would run fine on either side.
- **Nomad runs batch, k8s runs services.** k8s has Jobs and CronJobs.
  Nothing about batch work requires Nomad.
- **Nomad runs a GPU/legacy binary workload.** Genuinely justified in
  general, but there is no such binary in this lab, and inventing one
  would just be the arbitrary split again with more steps.

## 2. What the app actually does

`hostprobe` (Nomad, `exec` driver, stdlib Python, no image, no artifact
download) serves JSON on a static port, registered in Consul as
`<tenant>-hostprobe`.

`portal` (k3s, stock `python:3.12-alpine`, code from a ConfigMap) serves
a dashboard that does three things on every request:

1. resolves `<tenant>-hostprobe.service.consul` and shows the address
   and lookup time;
2. fetches the probe's JSON and renders the Nomad host's real state;
3. asks the Consul HTTP API, **with that tenant's own token**, for its
   own service (expect `200`) and for the other tenant's (expect `403`).

Point 3 is the part worth keeping: the §18 isolation proof stops being a
script somebody remembers to run and becomes a panel that is either
green or wrong, checked every 15 seconds.

## 3. Layout

```
hybrid-app/
├── README.md
├── nomad/probe.nomad.hcl          # tenant-parameterised, exec driver
├── k8s/portal.yaml                # ConfigMap + Deployment + Service + Ingress
└── scripts/
    ├── render-portal.sh           # substitutes tenant/port, writes to stdout
    └── verify-hybrid.sh           # 6 checks, exits non-zero on failure
```

Per-tenant static ports, assigned deliberately (see §7): `user1` →
`28001`, `user2` → `28002`.

## 4. Deploy — `user1`

**Nomad half**, from the jumpbox, as the tenant:

```bash
# tenant token from Vault, the §18 JWT path from Part 17 also works
export NOMAD_ADDR=http://192.168.1.51:4646
export NOMAD_TOKEN=<user1 namespace token>

nomad job plan -var="tenant=user1" -var="port=28001" nomad/probe.nomad.hcl
nomad job run  -var="tenant=user1" -var="port=28001" nomad/probe.nomad.hcl
nomad job status -namespace user1 hostprobe
curl -s http://192.168.1.51:28001/api/probe | head
```

**Kubernetes half**, from `kube`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
scripts/render-portal.sh user1 > /tmp/portal-user1.yaml
kubectl apply -f /tmp/portal-user1.yaml
kubectl -n user1 rollout status deploy/portal
```

**Optional — the Consul token that powers the isolation panel.** Without
it the app works and that one panel reads `no token`.

```bash
TOKEN=$(kubectl exec -n vault vault-0 -- \
  vault kv get -field=token cloudlab/consul/user1)     # confirm the real path first
kubectl -n user1 create secret generic portal-consul --from-literal=token="$TOKEN"
kubectl -n user1 rollout restart deploy/portal
```

**Verify:**

```bash
scripts/verify-hybrid.sh user1
```

Repeat all of the above with `user2` / port `28002`.

**Reach the dashboard from Windows** (same pattern as Grafana, Part 17):

```
ssh -J root@192.168.64.172 -L 8081:192.168.1.50:80 root@192.168.1.50
# add to C:\Windows\System32\drivers\etc\hosts:
#   127.0.0.1 user1-portal.cloudlab.internal
# then browse http://user1-portal.cloudlab.internal:8081
```

## 5. Rollback

```bash
nomad job stop -namespace user1 -purge hostprobe
kubectl delete -f /tmp/portal-user1.yaml
```

Nothing shared is modified, so rollback is complete. The one exception
is the Consul DNS token in §6 — if you add it, note it, because it is a
change to a shared agent.

## 6. The risk to check first: Consul DNS under default-deny ACLs

The cross-orchestrator DNS proof in Part 10 was done **before** Consul
ACLs went live. Since Part 12 piece 1/4, Consul runs
`default_policy = "deny"`, and a DNS query arriving from CoreDNS carries
no token at all — it authenticates as the anonymous token.

So `nslookup user1-hostprobe.service.consul` from a pod will return
nothing unless the Consul agent has a DNS token with catalog read.
Check 1 in `verify-hybrid.sh` exists specifically to catch this, and it
is the most likely thing to fail on first deploy.

If it fails, the fix is an agent-level DNS token, not a wider anonymous
policy:

```hcl
# consul.hcl, on .51 — then re-template through the nomad_node role,
# don't hand-edit and forget it (this is exactly how the undocumented
# Type=exec drop-in in Part 12 happened)
acl {
  tokens {
    default = "<token with node_prefix read + service_prefix read>"
  }
}
```

Worth stating plainly in the final report: **catalog reads via DNS are
necessarily shared.** A pod cannot present a Consul token over port 53.
The tenant boundary in Consul is enforced on *writes* and on
*authenticated API reads* — which is exactly what the portal's isolation
panel measures. Anyone who can query DNS can see that
`user2-hostprobe` exists. That is a real limitation of DNS-based
discovery, not a bug in the ACL work.

Second, smaller risk: the `consul:53` zone in the CoreDNS ConfigMap has
disappeared once already with no root cause (Problem #34). Check 1
catches that too.

## 7. Decisions taken here, and why

- **`exec`, not `raw_exec`.** `raw_exec` is deliberately off on prod
  `.51` (`nomad_enable_raw_exec: false`) and this app does not ask for
  that to change. `exec` is on by default, gives chroot plus namespace
  isolation, and its chroot includes `/usr`, so the `python3` that
  Ansible already requires on the host is available with no artifact
  download.
- **Static ports instead of SRV lookups.** An A record from Consul DNS
  carries an address but no port. Static per-tenant ports keep the
  discovery path byte-for-byte the one already proven in Part 10;
  SRV would add a second failure mode to debug on day one. If a third
  tenant ever appears, this is the thing to revisit.
- **Stock image + ConfigMap, no registry.** The CI/CD phase should
  replace this with a built image, and it now has a real payload to
  build rather than a placeholder. Deliberately left as the obvious
  next seam.
- **Service named `<tenant>-hostprobe`.** Matches the `user1-*` /
  `user2-*` prefix the Consul tenant policies are written against, so
  the existing policies cover it with no edit.
- **Nomad registers the service with its own broad integration token.**
  Unchanged from Part 12's reasoning: Nomad is trusted platform
  infrastructure, and the boundary is enforced on tenant tokens.
- **No Vault Agent injection.** The Consul token is a plain Secret
  created by hand. Vault-to-k8s auth exists (Part 9) and wiring the
  injector in is a reasonable later improvement; it is not needed to
  make this app work and would have doubled the moving parts.

## 8. Testing already done

Both programs were run and exercised outside the lab before anything was
handed over: probe and portal started, JSON and HTML verified, the
isolation panel checked against a stub Consul returning `200` for
`user1-*` and `403` for `user2-*` (verdict rendered `enforced`), the
probe then killed to confirm the dashboard degrades to `no answer`
instead of erroring, and `/healthz` and 404 handling confirmed. What
cannot be tested outside the lab, and therefore what to watch on first
deploy: Consul DNS resolution under ACLs (§6), the `exec` driver's
chroot exposing `/proc` (every reader in the probe is individually
guarded and degrades to `null`, so a missing path shows as a blank
field, not a crash), and the ResourceQuota accepting the portal pod.

## 9. Next, after this lands

1. Fold this into IaC — the manifests and jobspec belong in the
   `~/ansible` repo alongside the roles, not loose on a VM.
2. CI/CD (`auto`, GitHub Actions self-hosted runner, push to main) now
   has a real payload: build a portal image, `nomad job run`, `kubectl
   apply`, then `verify-hybrid.sh` as the gate.
3. Add the portal and probe to Prometheus. The probe's JSON is one small
   step from a `/metrics` endpoint, and `verify-hybrid.sh` check 1 is
   the alert that Problem #34 never had.
