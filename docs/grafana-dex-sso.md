# Grafana login via Dex SSO — CORRECTED PLAN, STILL NOT APPLIED

Status: **not applied, not verified.** Revised 2026-09-16 after an audit
against the live facts in the handoff. The first draft (written the same
night) had three errors that would each have produced a working-looking
apply followed by a failed login. They are recorded here rather than
quietly fixed, because two of them are the same mistakes this project has
already made once.

`tests/smoke_grafana_sso.py` now asserts the corrected values against
`app.py`'s own `DEX_ISSUER` and `GRAFANA_URL`, so this file cannot drift
from the config the portal proves works every day.

## What the first draft got wrong

**1. The Dex endpoints used the EXTERNAL hostname.** The draft said
`https://dex.cloudlab.internal/dex/auth`. Dex's issuer is the INTERNAL
name, `https://dex.dex.svc.cluster.local:5554/dex`, and changing it was
considered and **rejected** because k3s's API-server flags expect that
exact string. A client pointed at any other hostname fails at login with
`oidc: issuer did not match the issuer returned by provider` — which is
Problem #77, already paid for once with Nomad. Object creation does not
catch it; only a real login does.

**2. `root_url` was `https://`.** No Traefik Ingress in this lab
terminates TLS — signup, n8n and Grafana are all plain HTTP (Problem
#85, and Part 20 says `http://grafana.cloudlab.internal`). An https
`root_url` makes Grafana build an https `redirect_uri`, which then does
not match what is registered in Dex, so the user authenticates
successfully and *then* fails. The same error was live in `app.py`'s
`GRAFANA_URL` default, making the portal's Monitoring rail link
non-functional; fixed in the same pass.

**3. It was written as a raw `grafana.ini`.** Grafana here is not
standalone: it is part of the `kube-prometheus-stack` Helm release
`monitoring`, so the config belongs under `grafana.grafana.ini` in the
values file, and the mounts belong under `grafana.extraSecretMounts`.
Dropping an ini file next to the pod would be overwritten by the next
`helm upgrade`.

## What this does and does not do

**Does:** let anyone with a platform account (created at `/signup`,
authenticated by Dex against FreeIPA) log into Grafana with that same
identity. No hand-created Grafana account, no second password.

**Does not:** change what anyone sees. Every signed-in user, admin or
not, gets the same cluster-wide dashboards — Nomad, Consul, node
metrics. Nothing here scopes a metric or a dashboard by tenant. This is
**login-only**, and no UI text, confirmation message or nav link may
imply otherwise. The portal's rail item says "Monitoring" and stops
there, deliberately. Per-tenant isolation remains Part 23 item 24 and is
NOT closed by this work.

## HAZARD: Dex staticClients are addressed BY LIST INDEX

Already a documented trap. `deploy-dex.sh` sets the portal's secret with:

```
--set-string config.staticClients[$PORTAL_CLIENT_INDEX].secret=...
```

Helm cannot match a list element by field value, so that index is
positional. Current clients:

```
[0] kubernetes
[1] nomad
[2] signup-portal
```

**Appending `grafana` as `[3]` is the only safe insertion.** Inserting it
earlier shifts `signup-portal` and `nomad` down, and the next
`deploy-dex.sh` run writes the portal's secret over another client's —
most damagingly `nomad`'s, which breaks `nomad login` for every tenant
with no error at deploy time. `deploy-dex.sh` already verifies that
`PORTAL_CLIENT_INDEX` really is `signup-portal`; add the same guard for
the new client.

## Prerequisite the first draft missed entirely

Because the issuer is the internal name, **the browser doing the login
must resolve `dex.dex.svc.cluster.local`.** `.51` and `jumpbox` already
have `/etc/hosts` entries for exactly this reason; the Windows
workstation does not.

```
# C:\Windows\System32\drivers\etc\hosts   (elevated editor)
192.168.1.50 dex.dex.svc.cluster.local
192.168.1.50 grafana.cloudlab.internal
```

The hosts file beats the NRPT rule, which is why this is the right lever
here. The browser will also need the FreeIPA CA trusted, or it will warn
on the Dex redirect — the cert is FreeIPA-signed and carries both names
as SANs.

Without this, the login fails at the redirect with a DNS error and it
looks like Dex is down.

## 1. Dex: append a fourth static client

In `/root/dex-setup/values.yaml`, **appended after `signup-portal`**:

```yaml
- id: grafana
  name: Grafana
  secret: PLACEHOLDER-SET-BY-deploy-dex.sh
  redirectURIs:
  - http://grafana.cloudlab.internal/login/generic_oauth
```

Note `http`, matching how Traefik actually serves Grafana.

The secret follows `bindPW`'s pattern rather than the inline-plaintext
pattern `kubernetes` and `nomad` use — the inline ones are already
flagged as a hardening debt, so a new client should not add to it:

```
kubectl exec -n vault vault-0 -- vault kv put cloudlab/grafana-oidc \
  client_secret="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
```

and in `deploy-dex.sh`, alongside the existing `--set-string`, with the
same index guard.

## 2. Grafana: values, not a raw ini

**Read the LIVE values first.** `/root/prometheus-values.yaml` on disk is
STALE and shows `additionalScrapeConfigs: []`; applying it would silently
delete the real scrape configs.

```
helm get values monitoring -n monitoring -o yaml > /root/prometheus-values-live.yaml
```

Edit THAT file. Under `grafana:`:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: http://grafana.cloudlab.internal
    auth.generic_oauth:
      enabled: true
      name: CloudLab
      allow_sign_up: true
      client_id: grafana
      client_secret: $__file{/etc/grafana/secrets/oidc/client_secret}
      scopes: openid profile email groups
      # THE INTERNAL NAME, because that is Dex's issuer (Problem #77).
      # It resolves in-cluster for the token exchange and, via the hosts
      # entry above, in the browser for the redirect.
      auth_url: https://dex.dex.svc.cluster.local:5554/dex/auth
      token_url: https://dex.dex.svc.cluster.local:5554/dex/token
      api_url: https://dex.dex.svc.cluster.local:5554/dex/userinfo
      # MEASURED 2026-09-18: Dex was sending NO preferred_username claim
      # at all, so this resolved to null and Grafana stored the EMAIL as
      # the Login - which never matches the bare-uid `owner` label on
      # tenant namespaces (Problem #161). This line is correct ONLY once
      # `preferredUsernameAttr: uid` is set inside Dex's userSearch.
      # Verify with ./dex-claims-probe.sh before trusting it.
      login_attribute_path: preferred_username
      # Dex presents a FreeIPA-signed cert, which is not in the base
      # image's trust store. Mount the CA rather than skipping
      # verification - there is no verify=False anywhere in this project.
      tls_client_ca: /etc/grafana/secrets/ca/freeipa-ca.crt
    # BREAK GLASS. The shared admin login stays enabled on purpose. Do
    # not lock cluster administration out of Grafana while proving SSO
    # works, and do not set disable_login_form.
    auth.basic:
      enabled: true
  extraSecretMounts:
    - name: oidc
      secretName: grafana-oidc
      mountPath: /etc/grafana/secrets/oidc
      readOnly: true
    - name: ca
      secretName: grafana-dex-ca
      mountPath: /etc/grafana/secrets/ca
      readOnly: true
```

Create the two mounted Secrets first, from Vault and from the CA file
`deploy.sh` already uses:

```
kubectl create secret generic grafana-oidc -n monitoring \
  --from-literal=client_secret="$(kubectl exec -n vault vault-0 -- \
     vault kv get -field=client_secret cloudlab/grafana-oidc)"

kubectl create secret generic grafana-dex-ca -n monitoring \
  --from-file=freeipa-ca.crt=/root/dex-setup/freeipa-ca.crt
```

Apply with the chart version pinned, so a values change does not smuggle
in a chart upgrade:

```
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --version 88.2.0 -f /root/prometheus-values-live.yaml
```

## 3. Verification — NOT YET DONE

Every box below is unchecked. "Applied successfully" is not evidence;
tonight already produced an import that reported success and left a
webhook that 404'd.

- [ ] `grafana` is at index `[3]` in the rendered Dex config and
      `signup-portal` is still at `[2]` — check **before** deploying Dex.
- [ ] Dex rolls out cleanly (`kubectl rollout status deploy/dex -n dex`).
- [ ] Grafana rolls out cleanly
      (`kubectl rollout status deploy/monitoring-grafana -n monitoring`).
- [ ] `http://grafana.cloudlab.internal` shows a "Sign in with CloudLab"
      button.
- [ ] **User 1** (e.g. `tesuseradam3`) logs in through it, is redirected
      to Dex, and lands in Grafana.
- [ ] **User 2**, a different real account, does the same.
- [ ] Server Admin → Users lists them as **two distinct accounts**, not
      one shared auto-provisioned identity.
- [ ] `admin` / `<set at install time; see Vault>` still logs in via the local form, not forced
      through Dex.
- [ ] Both Dex users see the SAME dashboards as each other and as admin —
      confirming the no-scoping limitation is still true, measured rather
      than assumed.
- [ ] `nomad login` still works for a tenant. The index hazard would
      break this silently and nothing else would report it.

## 4. Deliberately not attempted

Per-tenant metric isolation. Scoping a user to their own namespace's data
needs Grafana Enterprise's data-source permissions, or an open-source
label-enforcing proxy in front of Prometheus, **plus** dashboards written
to filter by tenant. None exist here. New infrastructure, not a follow-up
to this change. Part 23 item 24.
