# Nomad node Ansible playbook

Captures, as code, the hand-done setup of the `nomad` VM (§2, §11 of the
handoff): static IP, a directly-written and locked `/etc/resolv.conf`,
HashiCorp's apt repo, Nomad + Consul installed, and their configs written
exactly as verified working in production.

## Scope — per §16 item 2 of the handoff

This targets a **brand-new, disposable Debian 13 test VM**, not the real
`nomad` (192.168.1.51) or `kube` (192.168.1.50) boxes. `inventory.ini` only
defines `[nomad_test]`; the `[nomad_prod]` group is present but commented
out on purpose — don't uncomment it until a clean run here has been
reviewed.

## Before running

1. Stand up the test VM manually: Debian 13, matching `nomad`/`kube`
   exactly. Note its IP.
2. Edit `inventory.ini`:
   - set `ansible_host` to the test VM's real address
   - update `defaults/main.yml`'s `node_static_ip` to the address you want
     it to *end up* at after this playbook runs (these can differ if the
     VM currently has a DHCP address and you're moving it to a new static
     one)
3. Confirm the jumphost proxy line in `inventory.ini` matches how you
   actually reach VMs on `vmbr1` (`ssh -J root@192.168.64.172 ...`).

## Run it

```bash
cd ansible
ansible-playbook playbook-nomad.yml --check --diff   # dry run first
ansible-playbook playbook-nomad.yml
```

## What it deliberately does NOT do

- **No TLS/mTLS** — matches the documented, deliberate lab simplification
  (§7). Not something to "fix" as part of this playbook without being
  asked.
- **No Consul ACLs / Nomad namespaces** — that's the planned §18 work,
  a separate phase after IaC.
- **No DHCP-drift handling** — the real `nomad` VM's IP drifted once
  before being pinned (§2) because it started on DHCP. This playbook sets
  the static config from the very first run, so that failure mode doesn't
  apply here — but it's worth remembering *why* the static-first approach
  matters when this same role is later pointed at `kube`.

## After a clean run

Compare against the real VM to confirm the playbook reproduces it exactly:

```bash
# on the real nomad VM
cat /etc/nomad.d/nomad.hcl
cat /etc/consul.d/consul.hcl
cat /etc/network/interfaces
cat /etc/resolv.conf
lsattr /etc/resolv.conf   # should show ----i--------e--- (immutable)
```

Then, and only then, consider adding a `[nomad_prod]` run — as a
`--check --diff` dry run first, never a direct apply against the box
that's currently serving the cross-orchestrator discovery proof (§12).

## Next role (not built yet)

`kube_node` — the k3s side (static IP, resolv.conf, k3s install, CoreDNS
custom forward zone for `.consul`). Handoff §16 mentions Ansible starting
with `nomad` specifically because it's the more self-contained sequence;
`kube` is the natural next role once this one is proven.
