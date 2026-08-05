# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Automates deployment of **OpenShift Single Node (SNO)** on a Fedora/RHEL/CentOS Stream/Ubuntu host using Ansible + Terraform + libvirt/KVM. Two VMs are provisioned: a bastion (CentOS Stream) and an SNO master (RHCOS).

## Running the Playbooks

```bash
# Install Ansible collection dependency first
ansible-galaxy collection install -r requirements.yml

# Step 1: provision libvirt infra + bastion VM, generate Agent ISO (~5 min)
ansible-playbook 01-infra-bastion.yml

# Step 2: boot SNO master VM from the Agent ISO (installation takes 60–120 min)
ansible-playbook 02-create-sno-cluster.yml

# Optional: expose the OCP web console via nginx stream proxy on the host
ansible-playbook 03-expose-console.yml

# Tear everything down
ansible-playbook 99-destroy-all.yml
```

## Ansible configuration

`ansible.cfg` at the repo root is picked up automatically when running from there:

- `result_format = yaml` — ansible-core's native YAML output. Do **not** switch this to `stdout_callback = yaml`; that resolves to the deprecated `community.general.yaml` callback, which raises `TypeError: function() argument 'code' must be code, not str` on recent Python.
- `callbacks_enabled = ansible.posix.profile_tasks` — per-task timings. This makes `ansible.posix` a dependency of *every* playbook, not just `03`/`99`, so `ansible-galaxy collection install -r requirements.yml` must run first.
- `localhost_warning = False`, `interpreter_python = auto_silent`, `force_handlers = True`, `pipelining = True`.

## Linting and tests

CI uses `ansible-lint` (GitHub Actions, `ansible/ansible-lint@v25`). The repo passes the **production** profile, so keep it that way:

```bash
ansible-lint --profile production
```

There is no unit test suite. The other checks are `shellcheck` on the two scripts in `test/` (not in CI), and the scripts themselves, which need a *live* lab — see below.

## Local verification before pushing

Reproduce the full CI suite locally before pushing (mirrors `lint.yml` + `test.yml`):

```bash
# 1. Lint (pip install --user ansible-lint if the command is missing)
ansible-lint --profile production

# 1b. Shell scripts (not in CI, but keep them clean)
shellcheck test/test-console.sh test/cycle-test.sh

# 2. Syntax-check all playbooks
ansible-playbook --syntax-check -i test/inventory \
  01-infra-bastion.yml 02-create-sno-cluster.yml 03-expose-console.yml 99-destroy-all.yml

# 3. Render templates with default vars, then validate the generated .tf
ansible-playbook test-render.yml          # writes to /tmp/sno-rendered
cd /tmp/sno-rendered && terraform init -backend=false && terraform validate && terraform fmt -check -diff
```

`test-render.yml` (repo root) renders `infra.tf.j2`, `bastion.tf.j2`, `master.tf.j2`, `install-config.yaml.j2`, and `agent-config.yaml.j2` — no libvirt or VMs needed, so this is safe to run anywhere.

## Verifying a live cluster

`test/test-console.sh` is the end-to-end check; it needs a running lab and is **not** part of CI.

```bash
./test/test-console.sh      # exits non-zero if any check fails
```

It reads the bastion IP from `terraform output -raw bastion_ip` (same source as the playbooks), SSHes in as the bastion user, and checks `oc`/`openshift-install`, node readiness, clusterversion, all ClusterOperators, nginx, and console HTTP reachability. It also prints the kubeadmin password, so avoid pasting its raw output into anything shared.

The console check passes `curl --resolve …:443:<host IP>` deliberately, even though `03-expose-console.yml` now manages the host's `/etc/hosts`: the check is about the proxy path, and it must give the same answer whether or not the resolver happens to be set up. Without `--resolve` it returned HTTP 000 against a perfectly healthy cluster. Keep it if you touch that check. Resolution is verified separately, as its own assertion.

## Full lifecycle cycle test

`test/cycle-test.sh` runs the whole lab lifecycle unattended — `01` → `02` → `03` → `test/test-console.sh` → `99` — and is the way to exercise create *and* teardown in one go.

```bash
./test/cycle-test.sh                  # one cycle
./test/cycle-test.sh -n 3             # three back-to-back cycles
./test/cycle-test.sh --no-console     # skip 03 and the console check
./test/cycle-test.sh --preflight-only # environment checks only, creates nothing
./test/cycle-test.sh --keep           # create + verify, skip 99
```

- Per-phase logs and a duration summary land in `~/sno-cycle-logs/<timestamp>/` (mode `0700` — the verify log contains the kubeadmin password). The log directory deliberately lives **outside** `sno_base_dir`, which `99` deletes.
- **Destroy guard:** `infra.tf.j2` names its libvirt pool literally `default` and `99-destroy-all.yml` undefines it by name, so an unattended teardown on a host with a stock `default` pool would destroy someone else's storage. The script runs the destroy phase only when `virsh pool-dumpxml default` points at `sno_pool_dir`, and checks the same in preflight. Do not remove that guard.
- On failure the lab is **left running** for post-mortem and the loop stops; `--destroy-on-fail` overrides.
- Reference timing on a 60 GB / 8-core host: ~40 min total (01 ≈ 5½ min, 02 ≈ 35 min, 03 and 99 seconds each). The 60–120 min in this file and the README is the upstream install figure; well past ~50 min in `02` means something is wrong. Memory is the binding constraint — the lab needs 24 GB (20 master + 4 bastion).

## Architecture

### Playbook sequence

| Playbook | Runs on | What it does |
|---|---|---|
| `01-infra-bastion.yml` | localhost → bastion → localhost | Renders Terraform templates, calls `terraform apply` to create pool/networks/bastion VM, SSHes into bastion to install helper services (dnsmasq, squid, HAProxy, NFS, chrony), then generates the Agent ISO on **localhost** via `openshift-install agent create image` (built in `sno_manifests_dir`, then copied to `sno_tf_dir`) |
| `02-create-sno-cluster.yml` | localhost | Renders `master.tf.j2`, calls `terraform apply` to create the SNO master VM which boots from the Agent ISO |
| `03-expose-console.yml` | localhost | Installs nginx on the host, configures SSL stream passthrough to the SNO ingress VIP, opens ports 80/443/6443 in firewalld, adds the console `/etc/hosts` block on this host and writes `hosts-entries.txt` for other LAN devices |
| `99-destroy-all.yml` | localhost | `terraform destroy`, manual `virsh undefine` fallbacks, removes `sno_base_dir`, cleans up nginx config and both `/etc/hosts` entries |

### Template rendering flow

All files in `templates/` are Jinja2 templates, rendered at runtime by the playbooks (most by `01`; `master.tf.j2` by `02`). Destinations vary as noted below:

- `infra.tf.j2` → `infra.tf` — `required_version`/provider pin, libvirt pool, `default_network` (NAT, `sno_mgmt_network`, DHCP), `sno_prefix_network` (NAT, no DHCP)
- `bastion.tf.j2` → `sno_prefix_bastion0.tf` — bastion VM with cloud-init (user/password, static IP on cluster NIC) plus the `bastion_ip` output
- `master.tf.j2` → `sno_prefix_cluster_master0.tf` — SNO master VM booting from Agent ISO as cdrom
- `helper_node.sh.j2` → runs on bastion — installs dnsmasq/squid/HAProxy/NFS/chrony, downloads `oc` + `openshift-install` from `mirror.openshift.com`
- `install-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`
- `agent-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`; `openshift-install agent create image` then generates the ISO
- `nginx.conf.j2` → `/etc/nginx/nginx.conf` — stream-only nginx config (rendered by `03`)
- `nginx-sno-stream.conf.j2` → `/etc/nginx/stream.d/sno.conf` — TCP stream proxy for ports 80/443/6443 (rendered by `03`)

### Network topology

```
Host (libvirt)
  ├─ default_network  192.168.222.0/24  NAT  DHCP — host ↔ bastion management NIC
  └─ sno_network      192.168.10.0/24   NAT  no DHCP — bastion cluster NIC ↔ master
       bastion eth1:  192.168.10.2 (proxy_ip) + .100 (api_vip) + .101 (ingress_vip)
       master enp1s0: 192.168.10.10
```

### Key design decisions

- **Terraform state is split**: infra (pool, networks, bastion) is managed by `01-infra-bastion.yml`; the master VM is managed by `02-create-sno-cluster.yml`. Playbook `01` explicitly removes `libvirt_domain.sno_prefix_master0` from state before applying, so re-running `01` never touches the master. **Re-run safety:** `01` is safe to re-run — it leaves a running master untouched (and the bastion setup is idempotency-guarded). Re-running `02` re-renders `master.tf` and re-applies the master VM, so only re-run it when you intend to recreate/reconfigure the master.
- **Bastion IP comes from a Terraform output, not `virsh`**: the bastion's management NIC is DHCP, and `bastion.tf.j2` exposes the lease as the `bastion_ip` output (`wait_for_lease = true` guarantees it is populated at apply time). `01`, `02` and `test/test-console.sh` all read it with `terraform output -raw bastion_ip`. There is **no** `sno_bastion_ip` variable in `vars.yml` — it is a runtime fact only.
  - **Gotcha:** when the output is missing (e.g. state predating this change), `terraform output -raw` writes a *warning to stdout* and still **exits 0**. An emptiness or exit-code check would treat that warning text as an IP, so every caller validates the IPv4 shape instead. Keep that validation if you touch these call sites.
- **`/etc/hosts` is written by two playbooks, pointing at two different IPs — deliberately.** `02-create-sno-cluster.yml` adds one plain line for `api`/`api-int` → `sno_api_vip`, because the host reaches the VIP directly over the libvirt NAT network and `openshift-install wait-for` needs it during the install. `03-expose-console.yml` adds a marker block for the `apps.*` names → the *host's* LAN IP, which goes through the nginx stream proxy. Do **not** add `api` to the 03 block: two entries for the same name would shadow each other. Devices other than the host cannot reach the VIP at all, so `hosts-entries.txt` lists `api` → host IP for them. `99-destroy-all.yml` removes both, and the marker/line there must stay byte-identical to what 02 and 03 write or teardown silently leaks a stale entry.
- **Secrets are marked `no_log`**: the tasks that render `login_bastion.sh` (mode `0700`, it embeds the password) and that `add_host` the bastion with `ansible_password` both set `no_log: true`. Do not remove it to make debugging easier.
- **Provider is pinned to `dmacvicar/libvirt` 0.8.3 deliberately**: 0.9.x is a plugin-framework rewrite with an incompatible schema (`devices = { disks = [...] }`, `os = { boot_devices = [...] }` replace `disk`/`network_interface`/`cloudinit`/`boot_device`). Do not "upgrade" the pin without rewriting all three `.tf` templates.
- **`03-expose-console.yml` is RedHat-family only** and asserts so up front: it uses `dnf`, `semanage`, `seboolean`, `firewalld`, and the `/etc/nginx/stream.d` layout. The other playbooks are portable. CI syntax-checks Ubuntu, but syntax-check does not execute these tasks.
- **Idempotency guard on bastion setup**: `helper_node.sh` writes `/etc/helper_node_setup_info` on completion; `01-infra-bastion.yml` skips the block if that file exists.
- **ISO handoff**: the Agent ISO is generated on **localhost** (not the bastion) by `openshift-install agent create image` into `sno_manifests_dir`, then copied to `sno_tf_dir`; the master VM references it as a local file path in its disk block.
- **Bastion cluster NIC**: assigned a static IP via cloud-init network config in `bastion.tf.j2`; `helper_node.sh` then adds the api/ingress VIPs as additional addresses via `nmcli`.
- **Bastion kubeconfig lives at the bastion user's `~/.kube/config`** (default user `redhat`), copied there by `02-create-sno-cluster.yml` — *not* `/root/kubeconfig`, and there is no `KUBECONFIG` env var. `oc`/`kubectl` find it via the default path. **Anything that runs `oc` on the bastion must run as the bastion user, not root** — root has no kubeconfig. `test/test-console.sh` uses `sudo -iu "$BASTION_USER"` for this reason; do not change it to `sudo -i` (root). The `oc`/`openshift-install` binaries are in `/usr/local/bin` (on the login PATH).

## Configuration

All tunable parameters are in `vars.yml`. Fields marked `[CHANGE]` must be reviewed before first run:

- `sno_base_dir` — where Terraform state, pool, and ISO land on the host (default: `~/sno-lab`)
- `sno_cluster_version` — OCP release stream (e.g. `stable`, `stable-4.21`)
- `sno_bastion_password` / `sno_bastion_os_image` — bastion credentials and cloud image URL
- `sno_cluster_name` / `sno_base_domain` — cluster FQDN components
- `sno_master_mac` / `sno_interface` — must match the libvirt NIC definition in `master.tf.j2`
- MAC addresses for bastion NICs (`sno_bastion_mac_mgmt`, `sno_bastion_mac_sno`) — must be unique on the host
- `sno_mgmt_network` / `sno_mgmt_bridge` — CIDR and bridge name for `default_network` (were hardcoded in `infra.tf.j2` before)

The bastion's management IP is deliberately **absent** from `vars.yml` — see the Terraform-output design decision above.

## CI

- **Lint** (`.github/workflows/lint.yml`): runs `ansible-lint` on every push/PR to `main`
- **Test** (`.github/workflows/test.yml`): runs on every push/PR to `main`
  - **Syntax check**: `ansible-playbook --syntax-check` on all 4 playbooks, across 6 distros (Fedora 43/44, CentOS Stream 9/10, Ubuntu 24.04/26.04) using container jobs
  - **Template render + terraform validate**: renders all Jinja2 templates with default vars, then runs `terraform init -backend=false`, `terraform validate` and `terraform fmt -check -diff` on the generated `.tf` files (uses `hashicorp/setup-terraform@v3` with `terraform_wrapper: false`). Templates must therefore render *already formatted* — run `terraform fmt` on `/tmp/sno-rendered` and port any change back into the `.j2` source.
  - Test playbook is `test-render.yml` (repo root); minimal inventory for syntax check is `test/inventory`
- **OCP version check** (`.github/workflows/ocp-version-check.yml`): runs weekly (Monday 00:00 UTC), fetches the current stable OCP version, verifies download URLs for `oc`/`openshift-install`, re-runs `ansible-lint`, and opens a GitHub issue (or adds a comment to an existing one) if anything fails
