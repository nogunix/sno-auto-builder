# sno-auto-builder

[![Lint](https://github.com/nogunix/sno-auto-builder/actions/workflows/lint.yml/badge.svg)](https://github.com/nogunix/sno-auto-builder/actions/workflows/lint.yml)
[![Test](https://github.com/nogunix/sno-auto-builder/actions/workflows/test.yml/badge.svg)](https://github.com/nogunix/sno-auto-builder/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![GitHub last commit](https://img.shields.io/github/last-commit/nogunix/sno-auto-builder)

Automatically deploy **OpenShift Single Node (SNO)** on Fedora / RHEL / CentOS Stream / Ubuntu + libvirt using the **Agent-based installer**.

**CI tested on:** Fedora 43 · Fedora 44 · CentOS Stream 9 · CentOS Stream 10 · Ubuntu 24.04 · Ubuntu 26.04

**SNO** is an OpenShift cluster topology that runs all control-plane components on a single master node.  
**Bastion VM** hosts DNS, proxy, and load balancer services, and acts as the jump host for `oc` commands.

> **Why this project?**  
> Getting a full OCP cluster running locally is notoriously tricky — pull secret wrangling, DNS quirks, HAProxy config, Agent ISO generation, and KVM networking all need to line up perfectly.  
> This project automates the entire stack end-to-end with two `ansible-playbook` commands, targeting a standard 32 GB mini PC.
>
> **Use cases:**
> - Testing Operators and custom workloads on a full OCP cluster
> - Home lab with a production-like setup

## Host Requirements

Designed to run on a mini PC with **32 GB RAM**:

| Resource | Required | Notes |
|---|---|---|
| CPU | 10 cores / threads | Hardware virtualization (VT-x / AMD-V) required |
| RAM | 32 GB | 24 GB for VMs + 8 GB host OS |
| Disk | 256 GB free | 140 GB for VM images + host OS |

**VM breakdown (default `vars.yml`):**

| VM | vCPU | RAM | Disk |
|---|---|---|---|
| bastion (CentOS Stream) | 2 | 4 GB | 20 GB |
| SNO master (RHCOS) | 8 | 20 GB | 120 GB |

## Prerequisites

- Fedora / RHEL 9+ / CentOS Stream 9+ / Ubuntu 22.04+ + libvirt/KVM
- `ansible-core` / `opentofu` / `sshpass`
- OpenShift pull secret at `~/openshift-pull-secret/openshift-pull-secret.txt`

  A Red Hat Developer account is required (free): https://developers.redhat.com/register  
  Download the pull secret from Red Hat Console: https://console.redhat.com/openshift/install/pull-secret

  > **Note:** Without a paid Red Hat subscription, OpenShift runs as a **60-day evaluation**.  
  > For home lab / learning purposes the evaluation period is typically sufficient.

### Fedora

```bash
sudo dnf install -y ansible-core opentofu sshpass
```

### RHEL 9+ / CentOS Stream 9+

```bash
# RHEL only: enable EPEL (provides sshpass)
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Add OpenTofu repo and install packages
sudo curl -Lo /etc/yum.repos.d/opentofu.repo \
  https://packages.opentofu.org/opentofu/tofu/config_file.repo?type=rpm
sudo dnf install -y ansible-core opentofu sshpass
```

### Ubuntu 22.04+

```bash
# Add OpenTofu repo and install packages
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sudo sh -s -- --install-method deb
sudo apt-get install -y ansible-core sshpass
```

### libvirt daemons

```bash
# Fedora / RHEL 9+ / CentOS Stream 9+ (modular daemons)
for drv in qemu interface network nodedev nwfilter secret storage; do
  sudo systemctl enable --now virt${drv}d.service
done

# Ubuntu
# sudo systemctl enable --now libvirtd
```

## Configuration

Edit `vars.yml` to set the cluster name, IPs, MAC addresses, OCP version, etc.  
Review all items marked with `[CHANGE]`.

## Usage

```bash
git clone https://github.com/nogunix/sno-auto-builder.git
cd sno-auto-builder

# Step 1: provision bastion VM + generate Agent ISO on localhost (~5 min)
ansible-playbook 01-infra-bastion.yml

# Step 2: boot SNO master VM and monitor installation to completion (60–120 min)
ansible-playbook 02-create-sno-cluster.yml
```

`02-create-sno-cluster.yml` boots the master VM and then waits for installation to finish using `openshift-install agent wait-for`. The playbook exits once the installer reports installation complete. Cluster operators may take a few additional minutes to fully stabilize after the playbook finishes.

When complete, credentials are at:

```
~/sno-lab/work/generated/ocp4/auth/kubeconfig
~/sno-lab/work/generated/ocp4/auth/kubeadmin-password
```

> Replace `ocp4` with your `sno_cluster_name` if you changed it in `vars.yml`.

Access the cluster via the bastion VM (where `oc` and kubeconfig are installed):

```bash
# Log into the bastion
~/sno-lab/work/sno01_login_bastion0.sh

# On the bastion — KUBECONFIG is set automatically
oc get nodes
oc get clusterversion
oc get clusteroperators
```

The kubeadmin password is on the host if needed:

```bash
cat ~/sno-lab/work/generated/ocp4/auth/kubeadmin-password
```

> Replace `sno01` with your `sno_prefix` if changed in `vars.yml`.

## Monitoring Deployment Progress

`02-create-sno-cluster.yml` monitors progress automatically via `openshift-install agent wait-for`. It goes through two phases:

| Phase | What happens | Typical duration |
|---|---|---|
| **Bootstrap** | Agent ISO boots, writes RHCOS to disk, brings up temporary control plane | 15–30 min |
| **Install complete** | Installed system boots, all cluster operators become available | 45–90 min additional |

If you need to re-run only the monitoring step (e.g. after a restart), run from the host:

```bash
cd ~/sno-lab/work/generated/ocp4
~/sno-lab/work/openshift-install --log-level=info agent wait-for bootstrap-complete
~/sno-lab/work/openshift-install --log-level=info agent wait-for install-complete
```

## Web Console

Run the following playbook to expose the console to your home network via an nginx stream proxy on the host.

This playbook requires the `ansible.posix` collection. Install it first:

```bash
ansible-galaxy collection install -r requirements.yml
```

```bash
ansible-playbook 03-expose-console.yml
```

This installs nginx, configures SSL passthrough to the SNO ingress VIP, and opens ports 80/443/6443 in firewalld.

At the end of the playbook, the required `/etc/hosts` entries are saved to `~/sno-lab/hosts-entries.txt`. View them with:

```bash
cat ~/sno-lab/hosts-entries.txt
```

Add the entries to each device on your home network:

```
<fedora-host-ip>  console-openshift-console.apps.ocp4.example.com
<fedora-host-ip>  oauth-openshift.apps.ocp4.example.com
<fedora-host-ip>  api.ocp4.example.com
```

> Update hostnames to match `sno_cluster_name` and `sno_base_domain` in `vars.yml`.

Then open in your browser (no proxy settings needed):

```
https://console-openshift-console.apps.ocp4.example.com
```

Accept the self-signed certificate warning on first access.

Get the `kubeadmin` password:

```bash
cat ~/sno-lab/work/generated/ocp4/auth/kubeadmin-password
```

Log in with:
- **Username:** `kubeadmin`
- **Password:** output of the command above

## Verification

After installation, verify cluster health and console reachability with the included test script:

```bash
bash test/test-console.sh
```

This checks:
- Bastion VM reachability
- `oc` and `openshift-install` binaries on the bastion
- Node status (`Ready`)
- Cluster version and all cluster operators (`Available`)
- nginx status and web console HTTP reachability (if `03-expose-console.yml` was run)
- Prints `/etc/hosts` entries needed on client machines and the `kubeadmin` password

## Teardown

```bash
ansible-playbook 99-destroy-all.yml
```

## Scaling Up

If you have more resources, increase the SNO master allocation in `vars.yml` for better workload capacity:

```yaml
sno_master_vcpu: 16       # more vCPUs for heavier workloads
sno_master_memory: 32     # more RAM for running more pods
sno_master_disk_size: 200 # more disk for persistent volumes
```

The bastion VM (DNS, proxy, HAProxy, NFS, chrony) is lightweight and rarely needs more than the default 2 vCPU / 4 GB.

## Comparison with OpenShift Local (CRC)

[OpenShift Local](https://developers.redhat.com/products/openshift-local/overview) is the easiest way to run OpenShift on a laptop. This project targets a different use case:

| | OpenShift Local (CRC) | sno-auto-builder |
|---|---|---|
| Setup | `crc start` | 2 `ansible-playbook` commands |
| Cluster | Stripped-down, some operators disabled | **Full OCP** — all operators enabled |
| Network | Host-only | Bastion + DNS + proxy + HAProxy |
| Proxy/air-gap testing | No | **Yes** (squid included) |
| OS | macOS / Windows / Linux | Linux (libvirt/KVM) |
| RAM | 10.5 GB+ | 32 GB+ |
| Pull secret | Not required | Required |

**Use this project if you need a production-like SNO environment** — edge deployment testing, proxy/air-gap scenarios, or validating configs before deploying on real hardware.

## Installation Method: Agent-based Installer

ISO generation and installation monitoring are handled directly by `openshift-install` — no external Ansible collections beyond `ansible.posix` are required.

| Step | Command |
|---|---|
| ISO generation | `openshift-install agent create image --dir <manifests>` |
| Bootstrap monitoring | `openshift-install agent wait-for bootstrap-complete` |
| Install monitoring | `openshift-install agent wait-for install-complete` |

This project provides the cluster-specific configuration (`install-config.yaml.j2`, `agent-config.yaml.j2`) and the libvirt infrastructure (bastion VM, networks, SNO master VM).

**Official documentation:**
- [Installing on a single node (SNO)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/installing_on_a_single_node/index)
- [Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/installing_an_on-premise_cluster_with_the_agent-based_installer/index)

```
Host (localhost)
  install-config.yaml.j2 ──render──► install-config.yaml ──┐
  agent-config.yaml.j2   ──render──► agent-config.yaml   ──┤
                                                             ▼
                                     openshift-install agent create image
                                                             │
                                                             ▼
                                                    agent.x86_64.iso
                                                             │
                                                          boot
                                                             ▼
                                              SNO master VM (RHCOS)
                                               ├─ discovers hardware
                                               ├─ writes RHCOS to disk
                                               └─ bootstraps OpenShift
                                                             │
                                     openshift-install agent wait-for
                                      (bootstrap-complete / install-complete)
                                                             │
                                               SNO master running
                                               etcd · kube-apiserver
                                               kubelet · OVN · …
```

```
Host (Fedora / RHEL / CentOS Stream / Ubuntu + libvirt)
  ├─ bastion VM (CentOS Stream)   192.168.222.10 / 192.168.10.2
  │    dnsmasq · squid · HAProxy · NFS · chrony · oc · openshift-install
  └─ SNO master VM (RHCOS)        192.168.10.10
       control-plane · etcd · ingress · kubelet … all on one node

Networks
  default_network   192.168.222.0/24  NAT  host ↔ bastion (management)
  sno01_network     192.168.10.0/24   NAT  bastion ↔ master (cluster L2)
```

## License

This project is licensed under the [MIT License](LICENSE).

This is my personal project.
It is created and maintained in my personal capacity, and has no relation to my employer's business or confidential information.
