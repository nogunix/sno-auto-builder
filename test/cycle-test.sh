#!/bin/bash
# Full SNO lifecycle cycle test: create -> verify -> destroy, in one shot.
#
#   ./test/cycle-test.sh              # one cycle, console exposed, lab destroyed at the end
#   ./test/cycle-test.sh -n 3         # three back-to-back cycles
#   ./test/cycle-test.sh --no-console # skip 03-expose-console.yml
#
# Designed to be left unattended (a full cycle takes 1.5-2.5 h). Every phase is
# logged to its own file under the log directory; a summary table with per-phase
# durations is printed at the end and written to summary.txt.
#
# NOTE: the phase log for test-console.sh contains the kubeadmin password, so the
# log directory is created mode 0700. Do not paste raw logs anywhere shared.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="${REPO_ROOT}/vars.yml"

# ---------------------------------------------------------------- options ----
ITERATIONS=1
RUN_CONSOLE=1
DESTROY_ON_FAIL=0   # default: keep a broken lab so it can be inspected afterwards
SKIP_DESTROY=0
PREFLIGHT_ONLY=0

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

  -n, --iterations N   number of create/destroy cycles (default: 1)
      --no-console     skip 03-expose-console.yml and the console HTTP check
      --destroy-on-fail  tear the lab down even when a phase fails
                         (default: leave it up for post-mortem and stop)
      --keep           never run 99-destroy-all.yml (create + verify only)
      --log-dir DIR    base directory for logs (default: \$HOME/sno-cycle-logs)
      --preflight-only run the environment checks and exit (creates nothing)
  -h, --help           this message
EOF
}

LOG_BASE="${SNO_CYCLE_LOG_DIR:-${HOME}/sno-cycle-logs}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--iterations)   ITERATIONS="$2"; shift 2 ;;
        --no-console)      RUN_CONSOLE=0; shift ;;
        --destroy-on-fail) DESTROY_ON_FAIL=1; shift ;;
        --keep)            SKIP_DESTROY=1; shift ;;
        --log-dir)         LOG_BASE="$2"; shift 2 ;;
        --preflight-only)  PREFLIGHT_ONLY=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --iterations must be a positive integer" >&2
    exit 2
fi

# ------------------------------------------------------------------ vars ----
if [[ ! -f "$VARS_FILE" ]]; then
    echo "ERROR: vars.yml not found at $VARS_FILE" >&2
    exit 1
fi

_var() { grep "^$1:" "$VARS_FILE" | awk '{print $2}' | tr -d '"'; }
# sno_base_dir is quoted and contains a Jinja lookup, so it needs its own parsing.
_path_var() {
    grep "^$1:" "$VARS_FILE" | cut -d'"' -f2 | sed "s|{{ lookup('env', 'HOME') }}|${HOME}|"
}

PREFIX=$(_var sno_prefix)
CLUSTER_NAME=$(_var sno_cluster_name)
BASE_DOMAIN=$(_var sno_base_domain)
BASE_DIR=$(_path_var sno_base_dir)
POOL_DIR="${BASE_DIR}/pool"
PULL_SECRET=$(_path_var sno_pull_secret_path)
MASTER_MEM=$(_var sno_master_memory)
BASTION_MEM=$(_var sno_bastion_memory)
MASTER_DISK=$(_var sno_master_disk_size)
BASTION_DISK=$(_var sno_bastion_disk_size)

VIRSH="virsh -c qemu:///system"

RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_BASE}/${RUN_TS}"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_BASE" "$LOG_DIR"
SUMMARY="${LOG_DIR}/summary.txt"

# --------------------------------------------------------------- helpers ----
say()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$SUMMARY"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" | tee -a "$SUMMARY" >&2; }
die()  { echo "[$(date +%H:%M:%S)] FATAL: $*" | tee -a "$SUMMARY" >&2; exit 1; }

hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

RESULTS=()   # "iter|phase|status|duration"

# run_phase <iteration> <phase-name> <command...>
run_phase() {
    local iter="$1" phase="$2"; shift 2
    local log="${LOG_DIR}/${iter}-${phase}.log"
    local start=$SECONDS rc=0

    say "--- [cycle ${iter}] ${phase} : start (log: ${log##*/})"
    ( cd "$REPO_ROOT" && "$@" ) >>"$log" 2>&1 || rc=$?
    local dur=$((SECONDS - start))

    if [[ $rc -eq 0 ]]; then
        say "--- [cycle ${iter}] ${phase} : OK ($(hms "$dur"))"
        RESULTS+=("${iter}|${phase}|OK|${dur}")
    else
        say "--- [cycle ${iter}] ${phase} : FAILED rc=${rc} ($(hms "$dur"))"
        say "    last 30 lines of ${log}:"
        tail -n 30 "$log" | sed 's/^/    | /' | tee -a "$SUMMARY"
        RESULTS+=("${iter}|${phase}|FAIL(rc=${rc})|${dur}")
    fi
    return $rc
}

# The libvirt pool created by infra.tf.j2 is named literally "default". 99-destroy-all.yml
# undefines it by name, so on a host that already has a stock "default" pool that would
# tear down someone else's storage. Only ever proceed when the defined pool points at
# our own pool directory.
pool_is_ours() {
    local xml path
    xml=$($VIRSH pool-dumpxml default 2>/dev/null) || return 0   # not defined -> nothing to clash with
    path=$(sed -n 's|.*<path>\(.*\)</path>.*|\1|p' <<<"$xml" | head -1)
    [[ "$path" == "$POOL_DIR" ]]
}

preflight() {
    local rc=0
    echo "=== Preflight ==="

    for t in ansible-playbook terraform virsh sshpass curl; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "  [OK]   $t"
        else
            echo "  [FAIL] $t not found"; rc=1
        fi
    done

    if ansible-galaxy collection list ansible.posix 2>/dev/null | grep -q ansible.posix; then
        echo "  [OK]   ansible.posix collection installed"
    else
        echo "  [FAIL] ansible.posix missing - run: ansible-galaxy collection install -r requirements.yml"; rc=1
    fi

    if [[ -f "$PULL_SECRET" ]]; then
        echo "  [OK]   pull secret: $PULL_SECRET"
    else
        echo "  [FAIL] pull secret not found: $PULL_SECRET"; rc=1
    fi

    if sudo -n true 2>/dev/null; then
        echo "  [OK]   passwordless sudo (needed by 01/02/03/99)"
    else
        echo "  [FAIL] sudo requires a password - an unattended run will hang"; rc=1
    fi

    if $VIRSH list --all >/dev/null 2>&1; then
        echo "  [OK]   libvirt qemu:///system reachable"
    else
        echo "  [FAIL] cannot talk to qemu:///system"; rc=1
    fi

    # Storage pool ownership - see pool_is_ours()
    if pool_is_ours; then
        echo "  [OK]   no foreign libvirt pool named 'default'"
    else
        echo "  [FAIL] a libvirt pool named 'default' exists and does NOT point at ${POOL_DIR}."
        echo "         99-destroy-all.yml would undefine it. Aborting."
        rc=1
    fi

    local need_mem=$((MASTER_MEM + BASTION_MEM)) avail_mem
    avail_mem=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    if [[ $avail_mem -ge $need_mem ]]; then
        echo "  [OK]   memory: ${avail_mem}G available, ${need_mem}G needed"
    else
        echo "  [WARN] memory: ${avail_mem}G available, ${need_mem}G needed (VMs may fail to start)"
    fi

    local need_disk=$((MASTER_DISK + BASTION_DISK + 10)) avail_disk
    avail_disk=$(df -BG --output=avail "$(dirname "$BASE_DIR")" | tail -1 | tr -dc '0-9')
    if [[ $avail_disk -ge $need_disk ]]; then
        echo "  [OK]   disk: ${avail_disk}G available under $(dirname "$BASE_DIR"), ${need_disk}G needed"
    else
        echo "  [WARN] disk: ${avail_disk}G available, ~${need_disk}G needed"
    fi

    # Leftovers from an earlier run would make this cycle non-representative.
    local leftovers=""
    $VIRSH list --all --name 2>/dev/null | grep -qx "${PREFIX}_master0"  && leftovers+=" ${PREFIX}_master0"
    $VIRSH list --all --name 2>/dev/null | grep -qx "${PREFIX}_bastion0" && leftovers+=" ${PREFIX}_bastion0"
    [[ -d "$BASE_DIR" ]] && leftovers+=" ${BASE_DIR}"
    if [[ -n "$leftovers" ]]; then
        echo "  [WARN] leftovers from a previous run:${leftovers}"
        echo "         01/02 are re-run safe, but consider ./99-destroy-all.yml first for a clean cycle"
    else
        echo "  [OK]   no leftovers from a previous run"
    fi

    echo "=== Preflight $( [[ $rc -eq 0 ]] && echo passed || echo FAILED ) ==="
    return $rc
}

destroy_lab() {
    local iter="$1"
    if ! pool_is_ours; then
        warn "libvirt pool 'default' does not point at ${POOL_DIR} - refusing to run 99-destroy-all.yml."
        warn "Tear the lab down by hand after checking: ${VIRSH} pool-dumpxml default"
        RESULTS+=("${iter}|99-destroy|SKIPPED(pool guard)|0")
        return 1
    fi
    run_phase "$iter" "99-destroy" ansible-playbook 99-destroy-all.yml
}

print_summary() {
    {
        echo ""
        echo "==================== CYCLE TEST SUMMARY ===================="
        echo "started : ${RUN_TS}"
        echo "finished: $(date +%Y%m%d-%H%M%S)"
        echo "cluster : ${CLUSTER_NAME}.${BASE_DOMAIN}   logs: ${LOG_DIR}"
        echo ""
        printf '%-6s %-16s %-20s %s\n' "CYCLE" "PHASE" "STATUS" "DURATION"
        printf '%-6s %-16s %-20s %s\n' "-----" "-----" "------" "--------"
        local total=0
        for r in "${RESULTS[@]}"; do
            IFS='|' read -r i p s d <<<"$r"
            printf '%-6s %-16s %-20s %s\n' "$i" "$p" "$s" "$(hms "$d")"
            total=$((total + d))
        done
        echo ""
        echo "total wall clock: $(hms "$total")"
        echo "============================================================"
    } | tee -a "$SUMMARY"
}

EXIT_RC=0
finish() {
    print_summary
    echo ""
    echo "Full logs: ${LOG_DIR}"
    exit $EXIT_RC
}
trap 'EXIT_RC=130; say "interrupted"; finish' INT TERM

# ------------------------------------------------------------------ main ----
say "SNO cycle test: ${ITERATIONS} iteration(s), console=$( ((RUN_CONSOLE)) && echo yes || echo no ), destroy=$( ((SKIP_DESTROY)) && echo no || echo yes )"
say "logs -> ${LOG_DIR}"

preflight 2>&1 | tee "${LOG_DIR}/0-preflight.log"
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    EXIT_RC=1
    die "preflight failed - see ${LOG_DIR}/0-preflight.log"
fi

if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
    say "preflight only - nothing created"
    exit 0
fi

for ((iter = 1; iter <= ITERATIONS; iter++)); do
    say "===== CYCLE ${iter}/${ITERATIONS} ====="
    cycle_rc=0

    run_phase "$iter" "01-infra"  ansible-playbook 01-infra-bastion.yml     || cycle_rc=$?
    if [[ $cycle_rc -eq 0 ]]; then
        run_phase "$iter" "02-cluster" ansible-playbook 02-create-sno-cluster.yml || cycle_rc=$?
    fi
    if [[ $cycle_rc -eq 0 && $RUN_CONSOLE -eq 1 ]]; then
        run_phase "$iter" "03-console" ansible-playbook 03-expose-console.yml || cycle_rc=$?
    fi
    if [[ $cycle_rc -eq 0 ]]; then
        run_phase "$iter" "verify" ./test/test-console.sh || cycle_rc=$?
    fi

    if [[ $cycle_rc -ne 0 ]]; then
        EXIT_RC=1
        warn "cycle ${iter} failed"
        if [[ $SKIP_DESTROY -eq 1 || $DESTROY_ON_FAIL -eq 0 ]]; then
            warn "leaving the lab up for post-mortem (re-run with --destroy-on-fail to change this)"
            warn "tear it down later with: ansible-playbook 99-destroy-all.yml"
            break
        fi
        destroy_lab "$iter" || true
        break
    fi

    if [[ $SKIP_DESTROY -eq 1 ]]; then
        say "cycle ${iter} succeeded; --keep given, leaving the lab running"
        break
    fi

    destroy_lab "$iter" || EXIT_RC=1

    if [[ $iter -lt $ITERATIONS ]]; then
        say "settling for 60s before the next cycle"
        sleep 60
    fi
done

finish
