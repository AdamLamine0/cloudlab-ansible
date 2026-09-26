# CloudLab

A hybrid-cloud lab built on Proxmox: two orchestrators (Kubernetes and
Nomad/Consul) under one identity provider, one secrets store and one
monitoring stack, with a self-service portal that provisions a tenant
onto either platform from a form.

Everything here is real and running on the lab — this repository is the
code and configuration behind it, not a design document.

---

## The shape of it

```
            ┌──────────────── OPNsense (gateway, DNS forward) ─────────────┐
            │                                                              │
   Proxmox  │   freeipa 192.168.1.152   identity + DNS for cloudlab.internal│
   (pve)    │   kube    192.168.1.50    k3s, Traefik, Vault, Dex, Grafana   │
            │   nomad   192.168.1.51    Nomad + Consul                      │
            │   auto    192.168.64.178  Ansible control node, CI runner     │
            └──────────────────────────────────────────────────────────────┘

   user ─▶ signup portal ─▶ FreeIPA (account)
                │
                └─▶ n8n ─▶ Kubernetes namespace + quota + RBAC + Ingress
                       └─▶ Nomad namespace + job + bridged Service
```

A tenant picks a platform (or asks to be advised), and n8n provisions it:
a namespace, a resource quota, a RoleBinding scoped to them, a workload
built from their Git repo, and — for Kubernetes tenants — a real URL at
`<project>.apps.cloudlab.internal`.

---

## Where each part lives

| Path | What |
|---|---|
| `terraform/` | Proxmox VM definitions. The VMs themselves are code |
| `roles/`, `playbook-*.yml` | Ansible: k3s, Nomad, Consul, CoreDNS, node setup |
| `inventory.ini`, `group_vars/`, `host_vars/` | Inventory and variables |
| `platform/dex/` | Dex OIDC — the LDAP bridge to FreeIPA, and its RBAC bindings |
| `platform/monitoring/` | Prometheus values, scrape config, Grafana dashboards and ingress |
| `platform/vault/` | Vault Helm values |
| `platform/rbac/` | The `delete namespaces` grant and its admission guardrail |
| `portal/` | The self-service signup portal (stdlib-only Python), its manifests, assets, design source and test suites |
| `n8n/` | n8n itself, its ClusterRole, and the five provisioning workflows |
| `ops/` | Operator scripts: deploys, probes, discovery, end-to-end checks |
| `hybrid-app/` | The `portal`/`hostprobe` demo app that runs on both platforms |
| `scripts/` | CI runner install and preflight |
| `docs/` | Design and integration notes |
| `.github/workflows/` | CI: validate, infra-apply, deploy-hybrid-app |

---

## The pieces

**Foundation.** Proxmox hosts the VMs; OPNsense is the gateway and
forwards the whole `cloudlab.internal` zone to FreeIPA's DNS. Terraform
defines the VMs; Ansible configures them.

**Identity.** FreeIPA holds users and DNS. Dex bridges it to OIDC over
LDAP, and is the single sign-on for Kubernetes, Nomad, Grafana and the
portal. The asymmetry to remember: **bare uid in, full email out** —
Dex only emits `preferred_username` when `preferredUsernameAttr` is set
in its LDAP `userSearch`.

**Secrets.** Vault (KV mount `cloudlab/`) holds service-account
passwords, the Dex client secrets and the Nomad tokens. Nothing in this
repository contains a credential; deploy scripts read them from Vault at
run time — `platform/dex/values.yaml` ships a literal placeholder for
`bindPW` and `deploy-dex.sh` substitutes the real one.

**Compute.** k3s on `kube` with Traefik as ingress; Nomad and Consul on
`nomad`. A Nomad tenant reaches the outside world through a
selector-less Kubernetes Service plus a hand-built EndpointSlice, so
both platforms serve tenants through one Traefik.

**Monitoring.** Prometheus scrapes both orchestrators — Nomad included.
Grafana authenticates through Dex, and the "My usage" dashboard filters
by the signed-in user. That filter is a convenience, **not** a security
boundary: Grafana OSS cannot restrict Explore or `/api/ds/query` per
role, so any signed-in user can still reach every tenant's series.

**Self-service.** `portal/` is a stdlib-only Python server, shipped as a
ConfigMap rather than an image. It creates real FreeIPA accounts over
JSON-RPC, authenticates against Dex, and calls n8n to provision. n8n
classifies the project, analyses the repo, builds it with Kaniko in a
sandboxed namespace, and deploys it.

**CI/CD.** `validate` runs on every push: shell and YAML parse, rendered
manifests, Ansible syntax, Terraform fmt/validate, and Checkov over
Terraform and the rendered portal.

---

## Known gaps

**OPNsense and FreeIPA are not under IaC.** Both were configured by hand
and remain so. Their state is documented but not reproducible from this
repository — rebuilding either means following notes, not running a
playbook. This is a deliberate deferral, not an oversight.

**Checkov does not cover the newer manifests.** `ci.yml` scans
`terraform/` and the rendered hybrid-app portal. The manifests under
`portal/` and `n8n/` are written to the same hardening standard but are
not yet in scope for the scan.

**The `both` classification is a human-review fallback**, not a
dual-deployment feature.

---

## Running the Ansible

The playbooks target a **disposable test VM**, not the live boxes.
`inventory.ini` defines `[nomad_test]`; `[nomad_prod]` is present but
commented out on purpose — don't uncomment it until a clean run against
the test VM has been reviewed.

1. Stand up the test VM (Debian 13, matching `nomad`/`kube`), note its IP.
2. In `inventory.ini`, set `ansible_host`; in the role's
   `defaults/main.yml`, set `node_static_ip` to the address it should
   *end up* at (these differ if it currently has DHCP).
3. Confirm the jumphost line matches how you reach `vmbr1`
   (`ssh -J root@192.168.64.172 ...`).

```bash
ansible-playbook -i inventory.ini playbook-nomad.yml --check
ansible-playbook -i inventory.ini playbook-nomad.yml
```

## Running the portal tests

```bash
cd portal
python tests/smoke_delete.py        # and the other smoke_*.py
python tests/shcheck.py             # shell script conventions
node   tests/wfcheck.js             # n8n workflow structure
```

They read the repo only and never touch the lab.
