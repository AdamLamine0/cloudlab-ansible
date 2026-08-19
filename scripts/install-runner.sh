#!/usr/bin/env bash
# install-runner.sh — set up the GitHub Actions self-hosted runner on
# `auto` (192.168.64.178), as the `auto` user, NOT as root.
#
# Usage:
#   ./install-runner.sh <registration-token>
#
# Get the registration token from:
#   GitHub -> AdamLamine0/cloudlab-ansible -> Settings -> Actions ->
#   Runners -> New self-hosted runner  (it expires after ~1 hour)
#
# This is a repo-scoped runner. That matters: a self-hosted runner on a
# PUBLIC repo would let anyone's pull request execute code on this
# machine, which here means a machine holding lab credentials. Keep the
# repo private, or move the runner behind required approvals before ever
# making it public.
set -euo pipefail

TOKEN="${1:-}"
REPO_URL="https://github.com/AdamLamine0/cloudlab-ansible"
RUNNER_DIR="$HOME/actions-runner"
RUNNER_VERSION="2.336.0"
LABELS="cloudlab"

[ -n "$TOKEN" ] || { echo "usage: $(basename "$0") <registration-token>" >&2; exit 2; }
[ "$(id -u)" -ne 0 ] || { echo "do not run this as root — run it as the 'auto' user" >&2; exit 2; }

echo "==> dependencies"
sudo apt-get update -qq
sudo apt-get install -y curl tar sshpass git python3-pip

command -v ansible-playbook >/dev/null || sudo apt-get install -y ansible
command -v terraform >/dev/null || echo "NOTE: terraform not found — install it if the validate job needs it"

echo "==> downloading runner $RUNNER_VERSION"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [ ! -f "./config.sh" ]; then
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf runner.tar.gz
  rm -f runner.tar.gz
fi

echo "==> registering"
./config.sh --unattended \
  --url "$REPO_URL" \
  --token "$TOKEN" \
  --name "auto" \
  --labels "$LABELS" \
  --work "_work" \
  --replace

echo "==> installing as a systemd service (starts on boot)"
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status

cat <<'EOF'

==> Remaining manual steps

1. Vault password file — CI cannot answer --ask-vault-pass:

     mkdir -p ~/.ansible
     printf '%s' 'THE-VAULT-PASSWORD' > ~/.ansible/vault-pass
     chmod 600 ~/.ansible/vault-pass

   Do NOT commit this file. Confirm it is ignored:
     grep -q '.ansible/vault-pass' ~/.gitignore || echo "(it lives outside the repo — fine)"

2. Jump-host password for preflight.sh, in the runner's environment:

     echo 'CLOUDLAB_JUMP_PASSWORD=azerty12' >> ~/actions-runner/.env
     sudo ./svc.sh stop && sudo ./svc.sh start

3. Confirm the runner shows as Idle:
     GitHub -> Settings -> Actions -> Runners

4. Trigger the validate workflow manually once before trusting a push.

EOF
