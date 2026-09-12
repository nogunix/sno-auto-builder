#!/usr/bin/env bash
#
# Run 01-infra-bastion.yml and 02-create-sno-cluster.yml end to end against
# mocked external commands, purely to exercise task coverage.
#
# Why not --check: every `command` task is skipped in check mode, so the facts
# the playbooks register (tofu stdout, the bastion IP) come back empty and the
# run dies at the first assert — 01 reaches 8 of 35 tasks. With shims on PATH
# the registers are real, `when:` branches evaluate, and both playbooks run to
# the end.
#
# Destructive: 02 writes to /etc/hosts and the bastion plays add a local user,
# so this refuses to run outside a container or CI unless --force is given.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${MOCK_WORKDIR:-/tmp/sno-mock-run}"
COVERAGE_OUT="${ANSIBLE_COVERAGE_OUTPUT:-$REPO_ROOT/coverage.xml}"
FORCE=0
LIMIT_ARGS=()

usage() {
  cat <<'USAGE'
Usage: test/mock-run.sh [--force] [--workdir DIR]

  --force        run even outside a container/CI (modifies /etc/hosts)
  --workdir DIR  scratch directory for the fake lab (default /tmp/sno-mock-run)

Environment:
  ANSIBLE_COVERAGE_OUTPUT  Cobertura XML to merge into (default ./coverage.xml)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --workdir) WORKDIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- Safety guard ------------------------------------------------------------
in_container() {
  [ -f /run/.containerenv ] || [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null
}
if [ "$FORCE" != "1" ] && ! in_container && [ -z "${CI:-}" ]; then
  cat >&2 <<'REFUSE'
test/mock-run.sh refuses to run here.

02-create-sno-cluster.yml appends to /etc/hosts and the bastion plays create a
local user, so this is meant for a throwaway container or a CI runner. Run it as:

  podman run --rm -v "$PWD":/repo:Z -w /repo fedora:44 ./test/mock-run.sh

or pass --force if this host really is disposable.
REFUSE
  exit 1
fi

echo "==> workspace: $WORKDIR"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{work,pool,dist,home}

export MOCK_LOG="$WORKDIR/mock-commands.log"
: > "$MOCK_LOG"

# --- Fake pull secret --------------------------------------------------------
# vars.yml resolves sno_pull_secret_path from $HOME, so point HOME at the
# scratch tree rather than writing into the caller's home directory.
export HOME="$WORKDIR/home"
mkdir -p "$HOME/openshift-pull-secret"
echo '{"auths":{"fake.example.com":{"auth":"ZmFrZTpmYWtl"}}}' \
  > "$HOME/openshift-pull-secret/openshift-pull-secret.txt"

# --- Installer tarball served over file:// -----------------------------------
# Lets get_url and unarchive run for real instead of being stubbed out.
tar -czf "$WORKDIR/dist/openshift-install-linux.tar.gz" \
  -C "$REPO_ROOT/test/mock-bin" openshift-install
echo "==> built fake installer tarball"

# --- Bastion stand-in --------------------------------------------------------
# The bastion plays connect over SSH to whatever `tofu output -raw bastion_ip`
# returns. Point that at this machine and give it a matching local account.
BASTION_IP="127.0.0.1"
BASTION_USER="$(sed -n 's/^sno_bastion_user: *"\(.*\)"/\1/p' "$REPO_ROOT/vars.yml")"
BASTION_PASS="$(sed -n 's/^sno_bastion_password: *"\(.*\)"/\1/p' "$REPO_ROOT/vars.yml")"
export MOCK_BASTION_IP="$BASTION_IP"

setup_sshd() {
  # Both halves matter: sshd to accept the connection, and the ssh client for
  # Ansible's connection plugin. openssh-server does not pull in the client, and
  # without it wait_for_connection silently retries for its full 300s timeout.
  command -v sshd >/dev/null 2>&1 || return 1
  command -v ssh >/dev/null 2>&1 || return 1
  command -v sshpass >/dev/null 2>&1 || return 1
  [ "$(id -u)" = "0" ] || return 1
  ssh-keygen -A >/dev/null 2>&1 || return 1
  id "$BASTION_USER" >/dev/null 2>&1 || useradd -m "$BASTION_USER"
  echo "$BASTION_USER:$BASTION_PASS" | chpasswd
  echo "$BASTION_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-$BASTION_USER"
  chmod 0440 "/etc/sudoers.d/99-$BASTION_USER"
  # helper_node.sh installs dnsmasq/HAProxy/NFS and reconfigures the network —
  # far too much for a test container. Pre-create its completion marker so the
  # playbook takes its documented idempotency-guard path instead.
  touch /etc/helper_node_setup_info
  mkdir -p /run/sshd /var/empty/sshd
  /usr/sbin/sshd -o UsePAM=yes -o PasswordAuthentication=yes
  for _ in $(seq 30); do
    (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

if setup_sshd; then
  echo "==> sshd up on $BASTION_IP:22 — bastion plays will run"
else
  echo "==> no usable sshd; skipping the bastion plays"
  LIMIT_ARGS=(--limit localhost)
  # `wait_for port: 22` still has to succeed, so park a bare listener there.
  if [ "$(id -u)" = "0" ]; then
    python3 -c "
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 22)); s.listen(16)
while True:
    try: s.accept()[0].close()
    except OSError: pass
" &
    echo $! > "$WORKDIR/listener.pid"
    sleep 1
  else
    echo "!! not root: nothing can listen on port 22, 01 will stall at 'Wait for bastion SSH'" >&2
  fi
fi

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  [ -f "$WORKDIR/listener.pid" ] && kill "$(cat "$WORKDIR/listener.pid")" 2>/dev/null || true
}
trap cleanup EXIT

# --- Run ---------------------------------------------------------------------
export PATH="$REPO_ROOT/test/mock-bin:$PATH"
export ANSIBLE_CALLBACKS_ENABLED="coverage_reporter"
export ANSIBLE_COVERAGE_OUTPUT="$COVERAGE_OUT"
export ANSIBLE_HOST_KEY_CHECKING=False
# 02 writes /etc/hosts, which a container runtime bind-mounts from the host.
# Ansible's atomic rename onto a bind mount fails with EBUSY, so fall back to
# writing in place. Test-harness only — production runs write a real file.
export ANSIBLE_UNSAFE_WRITES=1
# 02's wait-for tasks are async. The async status file is looked up under the
# *connection user's* home, which no longer matches the HOME redirected above,
# so pin the directory explicitly or async_status reports "could not find job".
export ANSIBLE_ASYNC_DIR="$WORKDIR/.ansible_async"

OVERRIDES=(
  -e "sno_base_dir=$WORKDIR"
  -e "sno_tf_dir=$WORKDIR/work"
  -e "sno_pool_dir=$WORKDIR/pool"
  -e "sno_installer_url=file://$WORKDIR/dist/openshift-install-linux.tar.gz"
)

rc=0
for pb in 01-infra-bastion.yml 02-create-sno-cluster.yml; do
  echo "==> $pb"
  ansible-playbook -i "$REPO_ROOT/test/inventory" "${LIMIT_ARGS[@]}" \
    "${OVERRIDES[@]}" "$REPO_ROOT/$pb" || { rc=1; echo "!! $pb failed"; }
done

# --- Negative path: the tofu-output-missing gotcha ---------------------------
# A missing output makes real tofu warn on *stdout* and exit 0, so the callers
# validate the IPv4 shape rather than the exit code. Prove the assert catches it.
echo "==> negative: tofu output -raw bastion_ip returns a warning, exit 0"
if MOCK_TOFU_OUTPUT_MISSING=1 ansible-playbook -i "$REPO_ROOT/test/inventory" \
     --limit localhost "${OVERRIDES[@]}" "$REPO_ROOT/01-infra-bastion.yml" \
     >"$WORKDIR/negative.log" 2>&1; then
  echo "!! expected 01 to fail its bastion-IP assert, but it passed" >&2
  rc=1
elif grep -q 'The bastion has no management IP' "$WORKDIR/negative.log"; then
  echo "    caught by 'Assert the bastion received a DHCP lease' as expected"
else
  echo "!! 01 failed, but not at the bastion-IP assert — see $WORKDIR/negative.log" >&2
  rc=1
fi

echo "==> mocked commands invoked:"
sed 's/^/    /' "$MOCK_LOG"
exit "$rc"
