#!/bin/bash
# Verify SNO cluster health and web console reachability.
# Run from the repo root after 02-create-sno-cluster.yml (and optionally 03-expose-console.yml).

set -euo pipefail

VARS_FILE="$(dirname "$0")/../vars.yml"
if [[ ! -f "$VARS_FILE" ]]; then
    echo "ERROR: vars.yml not found. Run from the repo root." >&2
    exit 1
fi

_var() { grep "^$1:" "$VARS_FILE" | awk '{print $2}' | tr -d '"'; }

CLUSTER_NAME=$(_var sno_cluster_name)
BASE_DOMAIN=$(_var sno_base_domain)
SNO_PREFIX=$(_var sno_prefix)
BASTION_USER=$(_var sno_bastion_user)
BASTION_PASSWORD=$(_var sno_bastion_password)

PASS=0
FAIL=0

ok()   { echo "  [OK]   $*"; ((PASS++)) || true; }
fail() { echo "  [FAIL] $*"; ((FAIL++)) || true; }
info() { echo "  [INFO] $*"; }

echo "=== SNO Console Test: ${CLUSTER_NAME}.${BASE_DOMAIN} ==="
echo ""

# --- Bastion IP ---
echo "[ Bastion ]"
BASTION_IP=$(virsh -c qemu:///system domifaddr "${SNO_PREFIX}_bastion0" 2>/dev/null \
    | grep -oP 'ipv4\s+\K[\d.]+(?=/)') || true
if [[ -z "$BASTION_IP" ]]; then
    fail "Bastion VM '${SNO_PREFIX}_bastion0' not found — run 01-infra-bastion.yml first"
    exit 1
fi
ok "Bastion reachable at $BASTION_IP"

SSH="sshpass -p $BASTION_PASSWORD ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $BASTION_USER@$BASTION_IP sudo -i"

# --- oc / openshift-install binaries ---
echo ""
echo "[ Bastion binaries ]"
$SSH which oc              &>/dev/null && ok "oc found" || fail "oc not found on bastion"
$SSH which openshift-install &>/dev/null && ok "openshift-install found" || fail "openshift-install not found on bastion"

# --- Cluster nodes ---
echo ""
echo "[ Cluster nodes ]"
NODE_STATUS=$($SSH oc get nodes --no-headers 2>/dev/null) || true
if [[ -z "$NODE_STATUS" ]]; then
    fail "Could not reach cluster API"
else
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        if [[ "$status" == "Ready" ]]; then
            ok "Node $name: $status"
        else
            fail "Node $name: $status"
        fi
    done <<< "$NODE_STATUS"
fi

# --- Cluster version ---
echo ""
echo "[ Cluster version ]"
CV=$($SSH oc get clusterversion version --no-headers 2>/dev/null) || true
if [[ -n "$CV" ]]; then
    ok "$CV"
else
    fail "Could not get clusterversion"
fi

# --- Cluster operators ---
echo ""
echo "[ Cluster operators ]"
CO_OUT=$($SSH oc get co --no-headers 2>/dev/null) || true
if [[ -z "$CO_OUT" ]]; then
    fail "Could not get cluster operators"
else
    DEGRADED=$(echo "$CO_OUT" | awk '$4=="True" || $3=="False"' || true)
    if [[ -z "$DEGRADED" ]]; then
        COUNT=$(echo "$CO_OUT" | wc -l)
        ok "All $COUNT operators Available"
    else
        while IFS= read -r line; do
            fail "Degraded operator: $(echo "$line" | awk '{print $1}')"
        done <<< "$DEGRADED"
    fi
fi

# --- nginx ---
echo ""
echo "[ nginx (03-expose-console.yml) ]"
CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
if systemctl is-active --quiet nginx 2>/dev/null; then
    ok "nginx is active"

    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$CONSOLE_URL") || true
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" ]]; then
        ok "Console reachable (HTTP $HTTP_CODE): $CONSOLE_URL"
    else
        fail "Console returned HTTP $HTTP_CODE: $CONSOLE_URL"
    fi
else
    info "nginx not running — skipping console URL check (run 03-expose-console.yml to expose console)"
fi

# --- /etc/hosts hint ---
echo ""
echo "[ /etc/hosts entries for client machines ]"
HOST_IP=$(hostname -I | awk '{print $1}')
echo "  ${HOST_IP}  console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  ${HOST_IP}  oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  ${HOST_IP}  api.${CLUSTER_NAME}.${BASE_DOMAIN}"

# --- kubeadmin password ---
BASE_DIR=$(grep "^sno_base_dir:" "$VARS_FILE" | cut -d'"' -f2 | sed "s|{{ lookup('env', 'HOME') }}|${HOME}|")
KUBEADMIN_FILE="${BASE_DIR}/work/generated/${CLUSTER_NAME}/auth/kubeadmin-password"
echo ""
echo "[ kubeadmin password ]"
if [[ -f "$KUBEADMIN_FILE" ]]; then
    ok "$(cat "$KUBEADMIN_FILE")"
else
    info "Not found at $KUBEADMIN_FILE"
fi

# --- Summary ---
echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
