#!/usr/bin/env bash
#
# Run 03-expose-console.yml, 04-deploy-mcp-server.yml and 99-destroy-all.yml
# for coverage, against a real systemd/firewalld/nginx/dnsmasq environment and
# mocked cluster access.
#
# Companion to test/mock-run.sh, which covers 01 and 02. These three need more
# than PATH shims: 03 and 99 drive systemd units and firewalld, and 04 talks to
# a Kubernetes API. So this script needs the systemd image built from
# test/Containerfile.mock-host, and it shadows kubernetes.core / containers.podman
# with the test doubles in test/mock-collections/.
#
# Destructive: rewrites /etc/hosts, /etc/nginx and /etc/dnsmasq.d and stops
# services. Container/CI only unless --force.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${MOCK_WORKDIR:-/tmp/sno-mock-host}"
COVERAGE_OUT="${ANSIBLE_COVERAGE_OUTPUT:-$REPO_ROOT/coverage.xml}"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --workdir) WORKDIR="$2"; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

in_container() {
  [ -f /run/.containerenv ] || [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null
}
if [ "$FORCE" != "1" ] && ! in_container && [ -z "${CI:-}" ]; then
  cat >&2 <<'REFUSE'
test/mock-run-host.sh refuses to run here.

It rewrites /etc/hosts, /etc/nginx and /etc/dnsmasq.d and stops services, so it
is meant for the throwaway systemd container:

  podman build -t sno-mock-host -f test/Containerfile.mock-host .
  podman run -d --name sno-mock-host --systemd=always --cap-add=NET_ADMIN,NET_RAW \
    -v "$PWD":/repo:Z sno-mock-host
  podman exec -w /repo sno-mock-host ./test/mock-run-host.sh
REFUSE
  exit 1
fi

[ "$(id -u)" = "0" ] || { echo "must run as root" >&2; exit 1; }

echo "==> workspace: $WORKDIR"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{work/generated/ocp4/auth,tls,mcp}
# Deliberately outside WORKDIR: 99 removes sno_base_dir, which is WORKDIR here,
# so anything kept inside it disappears mid-run — same reason test/cycle-test.sh
# keeps its logs elsewhere.
export MOCK_LOG="${WORKDIR}-commands.log"
: > "$MOCK_LOG"

CLUSTER="$(sed -n 's/^sno_cluster_name: *"\(.*\)"/\1/p' "$REPO_ROOT/vars.yml")"
DOMAIN="$(sed -n 's/^sno_base_domain: *"\(.*\)"/\1/p' "$REPO_ROOT/vars.yml")"
MCP_PORT="$(sed -n 's/^sno_mcp_port: *\([0-9]*\)/\1/p' "$REPO_ROOT/vars.yml")"
APPS="apps.$CLUSTER.$DOMAIN"

# --- TLS for the monitoring-route stubs --------------------------------------
# 04 verifies Thanos/Alertmanager over HTTPS and validates them against the CA
# bundle taken from the kubeconfig, not the system trust store. Mirror that: one
# CA, embedded in the fake kubeconfig, signing the stub's certificate.
echo "==> generating CA + server certificate"
cd "$WORKDIR/tls"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 \
  -subj "/CN=sno-mock-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
cat > san.cnf <<EOF
[req]
distinguished_name = dn
[dn]
[ext]
subjectAltName = DNS:thanos-querier-openshift-monitoring.$APPS,DNS:alertmanager-main-openshift-monitoring.$APPS,DNS:prometheus-k8s-openshift-monitoring.$APPS
EOF
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=thanos-querier-openshift-monitoring.$APPS" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 1 -extfile san.cnf -extensions ext >/dev/null 2>&1
cd "$REPO_ROOT"

# --- Fake cluster kubeconfig -------------------------------------------------
KUBECONFIG_PATH="$WORKDIR/work/generated/$CLUSTER/auth/kubeconfig"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
cat > "$KUBECONFIG_PATH" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $CLUSTER
    cluster:
      server: https://api.$CLUSTER.$DOMAIN:6443
      certificate-authority-data: $(base64 -w0 < "$WORKDIR/tls/ca.crt")
contexts:
  - name: admin
    context: {cluster: $CLUSTER, user: admin}
current-context: admin
users:
  - name: admin
    user:
      client-certificate-data: $(base64 -w0 < "$WORKDIR/tls/server.crt")
      client-key-data: $(base64 -w0 < "$WORKDIR/tls/server.key")
EOF

# --- Stub endpoints ----------------------------------------------------------
start_stubs() {
  python3 - "$WORKDIR" "$MCP_PORT" <<'PY' &
import http.server, json, ssl, sys, threading

workdir, mcp_port = sys.argv[1], int(sys.argv[2])

class Monitoring(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # kube-rbac-proxy in front of these routes accepts a bearer token only.
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            self.send_response(401); self.end_headers(); return
        body = json.dumps({"status": "success", "data": {"result": []}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{workdir}/tls/server.crt", f"{workdir}/tls/server.key")
https = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Monitoring)
https.socket = ctx.wrap_socket(https.socket, server_side=True)
threading.Thread(target=https.serve_forever, daemon=True).start()
http.server.ThreadingHTTPServer(("0.0.0.0", mcp_port), Health).serve_forever()
PY
  echo $! > "$WORKDIR/stubs.pid"
  for _ in $(seq 40); do
    (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

stop_stubs() {
  [ -f "$WORKDIR/stubs.pid" ] || return 0
  kill "$(cat "$WORKDIR/stubs.pid")" 2>/dev/null || true
  rm -f "$WORKDIR/stubs.pid"
  sleep 1
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() { stop_stubs; }
trap cleanup EXIT

# --- Ansible environment -----------------------------------------------------
export PATH="$REPO_ROOT/test/mock-bin:$PATH"
export ANSIBLE_CALLBACKS_ENABLED="coverage_reporter"
export ANSIBLE_COVERAGE_OUTPUT="$COVERAGE_OUT"
# Test doubles for kubernetes.core and containers.podman must win over the real
# collections, so this path goes first.
_real_collections="$(ansible-config dump 2>/dev/null \
  | sed -n 's/^COLLECTIONS_PATHS([^)]*) = \(.*\)$/\1/p' \
  | tr -d "[]' " | tr ',' ':')"
export ANSIBLE_COLLECTIONS_PATH="$REPO_ROOT/test/mock-collections:${_real_collections:-$HOME/.ansible/collections:/usr/share/ansible/collections}"
# /etc/hosts is a bind mount in a container; atomic rename onto it fails EBUSY.
export ANSIBLE_UNSAFE_WRITES=1
export MOCK_KUBE_PLAY_CAPTURE="${WORKDIR}-kube-play-stream.yaml"

OVERRIDES=(
  -e "sno_base_dir=$WORKDIR"
  -e "sno_tf_dir=$WORKDIR/work"
  -e "sno_pool_dir=$WORKDIR/pool"
  # Point the monitoring routes at the local stub instead of the libvirt VIP,
  # so 04's own /etc/hosts block resolves to something that answers.
  -e "sno_ingress_vip=127.0.0.1"
)

systemctl start firewalld
for _ in $(seq 20); do firewall-cmd --state >/dev/null 2>&1 && break; sleep 0.5; done

rc=0
run_pb() {
  echo "==> $1"
  ansible-playbook -i "$REPO_ROOT/test/inventory" "${OVERRIDES[@]}" \
    "$REPO_ROOT/$1" || { rc=1; echo "!! $1 failed"; }
}

# 04 runs before 03 on purpose: its verification stubs listen on 443, and 03
# then hands that port to the nginx stream proxy. Teardown order is unaffected.
start_stubs || { echo "!! stub endpoints did not come up" >&2; exit 1; }
run_pb 04-deploy-mcp-server.yml
stop_stubs

run_pb 03-expose-console.yml
run_pb 99-destroy-all.yml

# --- Teardown symmetry -------------------------------------------------------
# CLAUDE.md: 99's markers must stay byte-identical to what 03 and 04 write, or
# teardown silently leaks a stale /etc/hosts entry. Assert that here, since it
# is exactly the kind of drift a coverage run would otherwise pass over.
echo "==> checking teardown removed everything it wrote"
leaks=0
check_absent() {
  if grep -qF "$1" /etc/hosts 2>/dev/null; then
    echo "!! /etc/hosts still contains: $1" >&2; leaks=1
  fi
}
check_absent "SNO console proxy ($CLUSTER.$DOMAIN)"
check_absent "SNO MCP monitoring routes ($CLUSTER.$DOMAIN)"
for path in "/etc/nginx/stream.d/backends.d/$CLUSTER.$DOMAIN.json" \
            "/etc/dnsmasq.d/sno-$CLUSTER.$DOMAIN.conf"; do
  if [ -e "$path" ]; then echo "!! left behind: $path" >&2; leaks=1; fi
done
[ "$leaks" = "0" ] && echo "    /etc/hosts, nginx backend and dnsmasq config all cleaned up" || rc=1

echo "==> mocked commands invoked:"
sed 's/^/    /' "$MOCK_LOG"
exit "$rc"
