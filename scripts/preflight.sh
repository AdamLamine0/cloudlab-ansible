#!/usr/bin/env bash
# preflight.sh — is the lab actually up?
#
# Run from the CI runner on `auto` before any workflow that touches the
# lab. Every check here maps to a failure that has already happened at
# least once in this project, and each one prints the specific fix
# rather than a generic failure.
#
# Exits 0 if everything needed is reachable, 1 otherwise.
set -uo pipefail

PROXMOX=192.168.64.172
KUBE=192.168.1.50
NOMAD=192.168.1.51
FAILED=0

ok()   { printf '  OK    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; FAILED=1; }

jump() {
  # run a command on a vmbr1 host through the Proxmox jump, the same
  # pattern inventory.ini uses
  local host="$1"; shift
  sshpass -p "${CLOUDLAB_JUMP_PASSWORD:-azerty12}" \
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
        -o ProxyCommand="sshpass -p '${CLOUDLAB_JUMP_PASSWORD:-azerty12}' ssh -o StrictHostKeyChecking=no -W %h:%p root@${PROXMOX}" \
        "root@${host}" "$@" 2>/dev/null
}

echo "Preflight"

# 1 — Proxmox host
if ping -c1 -W3 "$PROXMOX" >/dev/null 2>&1; then
  ok "Proxmox host $PROXMOX responds"
else
  bad "Proxmox host $PROXMOX unreachable" \
      "the PC or the Proxmox host is off; nothing else can work until it is up"
fi

# 2 — required tooling on the runner
for tool in ansible-playbook sshpass terraform; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool present"
  else
    bad "$tool missing on the runner" "apt install it on \`auto\` (see cicd/README.md §4)"
  fi
done

# 3 — vault password file (this is why deploys can run unattended)
VAULT_PASS_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.ansible/vault-pass}"
if [ -r "$VAULT_PASS_FILE" ]; then
  ok "ansible-vault password file readable"
else
  bad "no readable vault password file at $VAULT_PASS_FILE" \
      "create it (chmod 600) — CI cannot answer --ask-vault-pass interactively"
fi

# 4 — the two production VMs
for pair in "kube:$KUBE" "nomad:$NOMAD"; do
  name="${pair%%:*}"; ip="${pair##*:}"
  if jump "$ip" true; then
    ok "$name ($ip) reachable through the jump host"
  else
    bad "$name ($ip) unreachable" \
        "start the VM (qm start), and remember OPNsense (VMID 100) must be up first — Problem #63"
  fi
done

# 5 — gateway/DNS. VM-to-VM traffic works even with OPNsense down, which
# has masked this exact problem before, so test something EXTERNAL.
if jump "$KUBE" "getent hosts deb.debian.org >/dev/null"; then
  ok "external DNS resolves from kube (OPNsense is up)"
else
  bad "external DNS fails from kube" \
      "OPNsense (VMID 100) is probably stopped — 'qm start 100' on the Proxmox host, wait 30-60s"
fi

# 6 — Vault seal state. Seals on every vault-0 restart, by design.
SEALED="$(jump "$KUBE" "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -n vault vault-0 -- vault status -format=json" | tr -d ' \n' | grep -o '\"sealed\":[a-z]*' | cut -d: -f2)"
case "$SEALED" in
  false) ok "Vault is unsealed" ;;
  true)  bad "Vault is SEALED" "unseal with 3 of the 5 keys (Part 17) — expected after any vault-0 restart" ;;
  *)     bad "could not read Vault status" "check the vault-0 pod on kube" ;;
esac

# 7 — Consul and Nomad answering. A 403 is a healthy answer here: it
# means the service is up and ACLs are on. Only a connection failure is
# a problem, which is why this greps for either.
if jump "$NOMAD" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8500/v1/status/leader" | grep -qE '200|403'; then
  ok "Consul API answering (200 or 403 both fine — 403 means ACLs are live)"
else
  bad "Consul API not answering on .51" "systemctl status consul; remember the Type=exec drop-in"
fi

if jump "$NOMAD" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4646/v1/status/leader" | grep -qE '200|403'; then
  ok "Nomad API answering"
else
  bad "Nomad API not answering on .51" "systemctl status nomad"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "Preflight passed — the lab is up."
else
  echo "Preflight failed — fix the above before deploying."
fi
exit "$FAILED"
