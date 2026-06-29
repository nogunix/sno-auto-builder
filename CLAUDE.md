# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Automates deployment of **OpenShift Single Node (SNO)** on a Fedora/RHEL/CentOS Stream host using Ansible + OpenTofu (Terraform-compatible) + libvirt/KVM. Two VMs are provisioned: a bastion (CentOS Stream) and an SNO master (RHCOS).

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

There is no unit test suite; `ansible-lint` is the sole automated check.

## Architecture

### Playbook sequence

| Playbook | Runs on | What it does |
|---|---|---|
| `01-infra-bastion.yml` | localhost → bastion → localhost | Renders OpenTofu templates, calls `tofu apply` to create pool/networks/bastion VM, SSHes into bastion to install helper services (dnsmasq, squid, HAProxy, NFS, chrony), then generates the Agent ISO on **localhost** via `openshift-install agent create image` (ISO lands directly in `sno_tf_dir`) |
| `02-create-sno-cluster.yml` | localhost | Renders `master.tf.j2`, calls `tofu apply` to create the SNO master VM which boots from the Agent ISO |
| `03-expose-console.yml` | localhost | Installs nginx on the host, configures SSL stream passthrough to the SNO ingress VIP, opens ports 80/443/6443 in firewalld |
| `99-destroy-all.yml` | localhost | `tofu destroy`, manual `virsh undefine` fallbacks, removes `sno_base_dir`, cleans up nginx config |

### Template rendering flow

All files in `templates/` are Jinja2 templates. Playbook `01` renders them into `sno_tf_dir` (`~/sno-lab/work/`) at runtime:

- `infra.tf.j2` → `infra.tf` — libvirt pool, `default_network` (NAT 192.168.222.0/24), `sno_prefix_network` (NAT, no DHCP)
- `bastion.tf.j2` → `sno_prefix_bastion0.tf` — bastion VM with cloud-init (user/password, static IP on cluster NIC)
- `master.tf.j2` → `sno_prefix_cluster_master0.tf` — SNO master VM booting from Agent ISO as cdrom
- `helper_node.sh.j2` → runs on bastion — installs dnsmasq/squid/HAProxy/NFS/chrony, downloads `oc` + `openshift-install` from `mirror.openshift.com`
- `install-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`
- `agent-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`; `openshift-install agent create image` then generates the ISO
- `nginx-sno-stream.conf.j2` → `/etc/nginx/stream.d/sno.conf` — TCP stream proxy for ports 80/443/6443

### Network topology

```
Host (libvirt)
  ├─ default_network  192.168.222.0/24  NAT  DHCP — host ↔ bastion management NIC
  └─ sno_network      192.168.10.0/24   NAT  no DHCP — bastion cluster NIC ↔ master
       bastion eth1:  192.168.10.2 (proxy_ip) + .100 (api_vip) + .101 (ingress_vip)
       master enp1s0: 192.168.10.10
```

### Key design decisions

- **OpenTofu state is split**: infra (pool, networks, bastion) is managed by `01-infra-bastion.yml`; the master VM is managed by `02-create-sno-cluster.yml`. Playbook `01` explicitly removes `libvirt_domain.sno_prefix_master0` from state before applying, so re-running `01` never touches the master.
- **Idempotency guard on bastion setup**: `helper_node.sh` writes `/etc/helper_node_setup_info` on completion; `01-infra-bastion.yml` skips the block if that file exists.
- **ISO handoff**: the Agent ISO is generated on the bastion and `fetch`-ed back to `sno_tf_dir` on the host; the master VM references it as a local file path in its disk block.
- **Bastion cluster NIC**: assigned a static IP via cloud-init network config in `bastion.tf.j2`; `helper_node.sh` then adds the api/ingress VIPs as additional addresses via `nmcli`.

## Configuration

All tunable parameters are in `vars.yml`. Fields marked `[CHANGE]` must be reviewed before first run:

- `sno_base_dir` — where OpenTofu state, pool, and ISO land on the host (default: `~/sno-lab`)
- `sno_cluster_version` — OCP release stream (e.g. `stable`, `stable-4.21`)
- `sno_bastion_password` / `sno_bastion_os_image` — bastion credentials and cloud image URL
- `sno_cluster_name` / `sno_base_domain` — cluster FQDN components
- `sno_master_mac` / `sno_interface` — must match the libvirt NIC definition in `master.tf.j2`
- MAC addresses for bastion NICs (`sno_bastion_mac_mgmt`, `sno_bastion_mac_sno`) — must be unique on the host

## CI

- **Lint** (`.github/workflows/lint.yml`): runs `ansible-lint` on every push/PR to `main`
- **OCP version check** (`.github/workflows/ocp-version-check.yml`): runs weekly (Monday 00:00 UTC), fetches the current stable OCP version, verifies download URLs for `oc`/`openshift-install`, re-runs `ansible-lint`, and opens a GitHub issue (or adds a comment to an existing one) if anything fails
