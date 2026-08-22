#!/bin/bash
# Verify SNO cluster health and web console reachability.
# Run after 02-create-sno-cluster.yml (and optionally 03-expose-console.yml).

set -euo pipefail

VARS_FILE="$(dirname "$0")/../vars.yml"
if [[ ! -f "$VARS_FILE" ]]; then
    echo "ERROR: vars.yml not found. Run from the repo root." >&2
    exit 1
fi

_var() { grep "^$1:" "$VARS_FILE" | awk '{print $2}' | tr -d '"'; }

CLUSTER_NAME=$(_var sno_cluster_name)
BASE_DOMAIN=$(_var sno_base_domain)
BASTION_USER=$(_var sno_bastion_user)
BASTION_PASSWORD=$(_var sno_bastion_password)

# sno_base_dir is quoted and contains a Jinja lookup, so it needs its own parsing.
BASE_DIR=$(grep "^sno_base_dir:" "$VARS_FILE" | cut -d'"' -f2 | sed "s|{{ lookup('env', 'HOME') }}|${HOME}|")
TF_DIR="${BASE_DIR}/work"

PASS=0
FAIL=0

ok()   { echo "  [OK]   $*"; ((PASS++)) || true; }
fail() { echo "  [FAIL] $*"; ((FAIL++)) || true; }
info() { echo "  [INFO] $*"; }

echo "=== SNO Console Test: ${CLUSTER_NAME}.${BASE_DOMAIN} ==="
echo ""

# --- Bastion IP ---
echo "[ Bastion ]"
# Same source as the playbooks: the bastion_ip output from 01-infra-bastion.yml.
# `tofu output -raw` prints a warning to stdout and still exits 0 when the
# output is absent, so validate the shape instead of trusting the exit code.
BASTION_IP=$(tofu -chdir="$TF_DIR" output -raw bastion_ip 2>/dev/null) || true
if [[ ! "$BASTION_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    fail "No bastion_ip output in $TF_DIR — run 01-infra-bastion.yml first"
    exit 1
fi
ok "Bastion IP from OpenTofu output: $BASTION_IP"

# Run oc as the bastion user (kubeconfig lives at ~/.kube/config for that user).
# -i gives a login shell so /usr/local/bin (oc, openshift-install) is on PATH.
SSH="sshpass -p $BASTION_PASSWORD ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $BASTION_USER@$BASTION_IP sudo -iu $BASTION_USER"

# --- oc / openshift-install binaries ---
echo ""
echo "[ Bastion binaries ]"
if $SSH which oc &>/dev/null; then ok "oc found"; else fail "oc not found on bastion"; fi
if $SSH which openshift-install &>/dev/null; then ok "openshift-install found"; else fail "openshift-install not found on bastion"; fi

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
HOST_IP=$(hostname -I | awk '{print $1}')
if systemctl is-active --quiet nginx 2>/dev/null; then
    ok "nginx is active"

    # 03-expose-console.yml manages a marker block in /etc/hosts for this host.
    CONSOLE_FQDN="console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
    RESOLVED=$(getent hosts "$CONSOLE_FQDN" | awk '{print $1}' | head -1)
    if [[ "$RESOLVED" == "$HOST_IP" ]]; then
        ok "Console name resolves to $HOST_IP (/etc/hosts block)"
    elif [[ -n "$RESOLVED" ]]; then
        fail "Console name resolves to $RESOLVED, expected $HOST_IP"
    else
        fail "Console name does not resolve — the /etc/hosts block from 03-expose-console.yml is missing"
    fi

    # Still pass --resolve: this check is about the proxy path, and it must give
    # the same answer whether or not the resolver happens to be set up.
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
        --resolve "console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}:443:${HOST_IP}" \
        "$CONSOLE_URL") || true
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "301" ]]; then
        ok "Console reachable (HTTP $HTTP_CODE): $CONSOLE_URL"
    else
        fail "Console returned HTTP $HTTP_CODE: $CONSOLE_URL"
    fi
else
    info "nginx not running — skipping console URL check (run 03-expose-console.yml to expose console)"
fi

# --- dnsmasq ---
echo ""
echo "[ dnsmasq (03-expose-console.yml) ]"
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
    ok "dnsmasq is active"
    if [[ -f /etc/dnsmasq.d/sno.conf ]]; then
        ok "SNO wildcard DNS config exists"
        # Verify wildcard resolution via dnsmasq directly
        WILDCARD_TEST="test-route-check.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
        DIG_RESULT=$(dig +short "@${HOST_IP}" "$WILDCARD_TEST" 2>/dev/null) || true
        if [[ "$DIG_RESULT" == "$HOST_IP" ]]; then
            ok "Wildcard *.apps resolves to $HOST_IP via dnsmasq"
        elif [[ -n "$DIG_RESULT" ]]; then
            fail "Wildcard resolves to $DIG_RESULT, expected $HOST_IP"
        else
            info "dig not available or dnsmasq not reachable — wildcard check skipped"
        fi
    else
        fail "SNO wildcard DNS config /etc/dnsmasq.d/sno.conf missing"
    fi
else
    info "dnsmasq not running — LAN clients must use /etc/hosts (run 03-expose-console.yml for wildcard DNS)"
fi

# --- LAN client setup hint ---
echo ""
echo "[ LAN client setup ]"
echo "  Recommended: configure a resolver to use dnsmasq on this host"
echo "    Mac:   sudo bash -c 'mkdir -p /etc/resolver && echo \"nameserver ${HOST_IP}\" > /etc/resolver/${BASE_DOMAIN}'"
echo "    Linux: resolvectl dns <IF> ${HOST_IP} or add nameserver ${HOST_IP} to /etc/resolv.conf"
echo "  Fallback: copy these /etc/hosts entries"
echo "    ${HOST_IP}  console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "    ${HOST_IP}  oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "    ${HOST_IP}  api.${CLUSTER_NAME}.${BASE_DOMAIN}"

# --- kubeadmin password ---
KUBEADMIN_FILE="${TF_DIR}/generated/${CLUSTER_NAME}/auth/kubeadmin-password"
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
