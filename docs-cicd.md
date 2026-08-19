# CloudLab CI/CD

The `[TODO] CI/CD` phase from Part 15. The handoff already recorded the
decision — GitHub Actions with a self-hosted runner on `auto`, triggered
by push to main, no PR gates — so this builds that, and settles the
questions the decision left open.

Prerequisite: the hybrid app from the previous phase, since it's what
the pipeline deploys.

---

## 1. What runs when

| Workflow | Trigger | Touches the lab? |
|---|---|---|
| `ci.yml` — validate | every push, every branch | **No.** Reads the repo only. |
| `deploy-hybrid-app.yml` | push to `main` under `hybrid-app/**`, or manual | Yes — tenant namespaces only. |
| `infra-apply.yml` | **manual only**, defaults to check mode | Yes — VM and ACL configuration. |

## 2. The decision the handoff left open: what is CI allowed to change?

"Trigger on push to main" was settled. *What* that trigger is allowed to
do was not, and it's the decision that matters most here.

**Push to main deploys applications. It does not reconfigure
infrastructure.**

The infra playbooks rewrite `/etc/network/interfaces`, Consul and Nomad
configs, and ACL bootstrap state on live VMs. Handing that to a
push-triggered pipeline means a typo in a role becomes a production
network change with no human in the loop, on a lab where OPNsense
already fails to come back on its own and a Nomad ACL cutover already
produced a race condition (Problems #63, #75/#79). A push to main is a
statement about code; it is not a decision to reconfigure a production
ACL system.

So `infra-apply.yml` is `workflow_dispatch` only, defaults to `check`
mode, and refuses to apply to any `*_prod` group unless the group name
is typed into a confirmation box. That preserves the "prove on `.60`,
then cut over to `.51`" discipline the whole project has followed, and
puts it in the pipeline instead of relying on memory.

It also closes the Part 12 near-miss for good. `playbook-nomad.yml`'s
`hosts:` line gets flipped by hand between test and prod, and was once
left on prod when the next job was meant for `.60` — caught only by a
dry run. `infra-apply.yml` passes `--limit` explicitly from the dispatch
form, so the target is whatever the operator chose in the UI, not
whatever the file happened to say. `playbook-hybrid-app.yml` avoids the
hazard entirely by running on `localhost` and reaching the VMs through
`delegate_to` and inventory groups.

## 3. Secrets: nothing goes into GitHub

No GitHub Actions secrets are used at all. Both credentials the pipeline
needs live on the runner host:

- **ansible-vault password** → `/home/auto/.ansible/vault-pass`, mode
  `0600`, referenced by `ANSIBLE_VAULT_PASSWORD_FILE`. This is the one
  password the handoff deliberately never wrote down, so it does not get
  uploaded to a third party now either.
- **jump-host password** → `CLOUDLAB_JUMP_PASSWORD` in
  `~/actions-runner/.env`, used by `preflight.sh`. Ansible itself gets
  it from the encrypted `vault.yml` as it always has.

The reasoning: the runner is on the operator's own PC, so a secret in
GitHub would travel *out* of the lab and back in for no benefit. The
existing trust boundary is "whoever has `auto` has the lab", and this
keeps it there.

This also means `--ask-vault-pass` cannot be used in CI — nothing is
there to type it. That's the one real change the pipeline forces on the
existing workflow, and the password file is how it's handled.

**Keep the repo private.** A self-hosted runner on a public repo lets a
stranger's pull request execute code on the machine holding every
credential in this lab. Nothing in the workflows can prevent that;
repository visibility is the control.

## 4. Setting it up on `auto`

```bash
ssh auto@192.168.64.178
git clone https://github.com/AdamLamine0/cloudlab-ansible ~/cloudlab   # if not already there
~/cloudlab/scripts/install-runner.sh <registration-token>
```

The registration token comes from **Settings → Actions → Runners → New
self-hosted runner** and expires in about an hour. The script installs
dependencies, registers the runner with the `cloudlab` label, and
installs it as a systemd service so it survives a reboot of `auto`. It
then prints the two manual steps: the vault password file and the
`.env` entry.

The runner is labelled `cloudlab`, and every job requests
`[self-hosted, cloudlab]`.

**`auto` is a VM on a PC that gets switched off.** When it's off, jobs
queue rather than fail, and run when it comes back. For a solo lab
that's the correct behaviour, but it does mean a green checkmark can be
hours late. Worth one line in the final report.

## 5. Where the files go in the repo

```
cloudlab-ansible/
├── .github/workflows/{ci,deploy-hybrid-app,infra-apply}.yml
├── ansible/
│   ├── playbook-hybrid-app.yml
│   └── roles/hybrid_app/{tasks,defaults}/main.yml
├── hybrid-app/                     # from the previous phase
└── scripts/{preflight.sh,install-runner.sh}
```

If `~/ansible` is the repo root rather than a subdirectory, drop the
`ansible/` level and adjust `cd ansible` in the workflows to match — that
is the only path assumption they make.

## 6. What a deploy actually does

`playbook-hybrid-app.yml` → `roles/hybrid_app`, per tenant:

1. Check Vault's seal state, and fail immediately with a message saying
   Vault seals on every `vault-0` restart if it's sealed. This is the
   single likeliest cause of a red build.
2. Read the tenant's Nomad and Consul tokens from Vault (`no_log`
   throughout — tokens never reach the run log).
3. Copy the jobspec to `.51`, `nomad job plan`, then `nomad job run` in
   the tenant's namespace using the tenant's own token.
4. Render the portal manifest, ship it to `.50`, upsert the
   `portal-consul` secret, `kubectl apply`, restart only if something
   changed, wait for the rollout.
5. Run `verify-hybrid.sh` and fail the deploy if any check fails.

Step 5 is the point. A deploy that reports success without proving the
k3s pod still reaches the Nomad job through Consul isn't worth having —
that path is the thesis of the whole lab, and it's now checked on every
push.

`--check` is honoured throughout, so a dry run is
`ansible-playbook ... --check`.

## 7. Verify the Vault paths before the first run

`roles/hybrid_app/defaults/main.yml` guesses:

```yaml
hybrid_app_vault_nomad_path: "cloudlab/nomad"
hybrid_app_vault_consul_path: "cloudlab/consul"
```

The handoff records the KV mount as `cloudlab/` and those two prefixes,
but the exact per-tenant key and field names were hidden by `no_log`
during the ACL rollout and never captured. Confirm with:

```bash
ssh -J root@192.168.64.172 root@192.168.1.50
kubectl exec -n vault vault-0 -- vault kv list cloudlab/nomad
kubectl exec -n vault vault-0 -- vault kv get cloudlab/nomad/user1
```

then correct the defaults. The Nomad token is required; a missing Consul
token only degrades the portal's isolation panel, so the role warns
instead of failing on that one.

## 8. Honest status

Written and validated offline: shell scripts parse, all YAML parses, the
playbook passes `--syntax-check` against a stub inventory, and the
rendered portal manifests and their embedded Python compile — the
validate workflow runs exactly those checks, so it should pass on first
push.

Not yet exercised against the real lab, because that needs the runner
registered and the VMs up. Expect the first run to surface, in rough
order of likelihood: the Vault paths in §7, the repo-root path
assumption in §5, and the Consul DNS-under-ACLs issue documented in the
hybrid app's README §6.

Suggested first run: register the runner, push to a **branch** (not
main) so only `ci.yml` fires and nothing is deployed. Then dispatch
`infra-apply.yml` manually against `nomad_test` in `check` mode to prove
the runner can reach the lab. Only then push the app to main.

## 9. What this leaves for the report

- CI never gained the power to reconfigure production, and §2 says why.
- No credential left the lab to enable automation.
- The pipeline's success criterion is the cross-orchestrator proof
  itself, not "the command exited 0".
- Remaining gap, unchanged: OPNsense and FreeIPA are still outside IaC,
  so the pipeline can detect that OPNsense is down (`preflight.sh` check
  5) but cannot fix it.
