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

## Linting

CI uses `ansible-lint` (GitHub Actions, `ansible/ansible-lint@v25`). Run locally:

```bash
ansible-lint
```

There is no unit test suite; `ansible-lint` is the sole linting check.

## Local verification before pushing

Reproduce the full CI suite locally before pushing (mirrors `lint.yml` + `test.yml`):

```bash
# 1. Lint (pip install --user ansible-lint if the command is missing)
ansible-lint

# 2. Syntax-check all playbooks
ansible-playbook --syntax-check -i test/inventory \
  01-infra-bastion.yml 02-create-sno-cluster.yml 03-expose-console.yml 99-destroy-all.yml

# 3. Render templates with default vars, then validate the generated .tf
ansible-playbook test-render.yml          # writes to /tmp/sno-rendered
cd /tmp/sno-rendered && terraform init -backend=false && terraform validate && terraform fmt -check -diff
```

`test-render.yml` (repo root) renders `infra.tf.j2`, `bastion.tf.j2`, `master.tf.j2`, `install-config.yaml.j2`, and `agent-config.yaml.j2` — no libvirt or VMs needed, so this is safe to run anywhere.

## Architecture

### Playbook sequence

| Playbook | Runs on | What it does |
|---|---|---|
| `01-infra-bastion.yml` | localhost → bastion → localhost | Renders Terraform templates, calls `terraform apply` to create pool/networks/bastion VM, SSHes into bastion to install helper services (dnsmasq, squid, HAProxy, NFS, chrony), then generates the Agent ISO on **localhost** via `openshift-install agent create image` (built in `sno_manifests_dir`, then copied to `sno_tf_dir`) |
| `02-create-sno-cluster.yml` | localhost | Renders `master.tf.j2`, calls `terraform apply` to create the SNO master VM which boots from the Agent ISO |
| `03-expose-console.yml` | localhost | Installs nginx on the host, configures SSL stream passthrough to the SNO ingress VIP, opens ports 80/443/6443 in firewalld |
| `99-destroy-all.yml` | localhost | `terraform destroy`, manual `virsh undefine` fallbacks, removes `sno_base_dir`, cleans up nginx config |

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
- **Bastion IP comes from a Terraform output, not `virsh`**: the bastion's management NIC is DHCP, and `bastion.tf.j2` exposes the lease as the `bastion_ip` output (`wait_for_lease = true` guarantees it is populated at apply time). Both `01` and `02` read it with `terraform output -raw bastion_ip` and assert it looks like an IPv4 address. There is **no** `sno_bastion_ip` variable in `vars.yml` — it is a runtime fact only.
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

## CI

- **Lint** (`.github/workflows/lint.yml`): runs `ansible-lint` on every push/PR to `main`
- **Test** (`.github/workflows/test.yml`): runs on every push/PR to `main`
  - **Syntax check**: `ansible-playbook --syntax-check` on all 4 playbooks, across 6 distros (Fedora 43/44, CentOS Stream 9/10, Ubuntu 24.04/26.04) using container jobs
  - **Template render + terraform validate**: renders all Jinja2 templates with default vars and runs `terraform validate` on the generated `.tf` files
  - Test playbook is `test-render.yml` (repo root); minimal inventory for syntax check is `test/inventory`
- **OCP version check** (`.github/workflows/ocp-version-check.yml`): runs weekly (Monday 00:00 UTC), fetches the current stable OCP version, verifies download URLs for `oc`/`openshift-install`, re-runs `ansible-lint`, and opens a GitHub issue (or adds a comment to an existing one) if anything fails
