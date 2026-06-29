# sno-auto-builder

Automatically deploy **OpenShift Single Node (SNO)** on Fedora / RHEL / CentOS Stream + libvirt using the **Agent-based installer**.

**SNO** is an OpenShift cluster topology that runs all control-plane components on a single master node.  
**Bastion VM** hosts DNS, proxy, and load balancer services, and acts as the jump host for `oc` commands.

## Installation Method: Agent-based Installer

ISO generation and installation monitoring are handled directly by `openshift-install` — no external Ansible collections beyond `ansible.posix` are required.

| Step | Command |
|---|---|
| ISO generation | `openshift-install agent create image --dir <manifests>` |
| Bootstrap monitoring | `openshift-install agent wait-for bootstrap-complete` |
| Install monitoring | `openshift-install agent wait-for install-complete` |

This project provides the cluster-specific configuration (`install-config.yaml.j2`, `agent-config.yaml.j2`) and the libvirt infrastructure (bastion VM, networks, SNO master VM).

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
Host (Fedora / RHEL / CentOS Stream + libvirt)
  ├─ bastion VM (CentOS Stream)   192.168.222.10 / 192.168.10.2
  │    dnsmasq · squid · HAProxy · NFS · chrony · oc
  └─ SNO master VM (RHCOS)        192.168.10.10
       control-plane · etcd · ingress · kubelet … all on one node

Networks
  default_network   192.168.222.0/24  NAT  host ↔ bastion (management)
  sno01_network     192.168.10.0/24   NAT  bastion ↔ master (cluster L2)
```

## Host Requirements

| Resource | Minimum | Notes |
|---|---|---|
| CPU | 12 cores / threads | Hardware virtualization (VT-x / AMD-V) required |
| RAM | 36 GB | 32 GB for VMs + host OS |
| Disk | 200 GB free | 175 GB for VM images + host OS |

**VM breakdown (default `vars.yml`):**

| VM | vCPU | RAM | Disk |
|---|---|---|---|
| bastion (CentOS Stream) | 4 | 8 GB | 25 GB |
| SNO master (RHCOS) | 8 | 24 GB | 150 GB |

> Adjust VM sizes in `vars.yml` before running.

## Prerequisites

- Fedora / RHEL 9+ / CentOS Stream 9 + libvirt/KVM
- `ansible-core` / `opentofu` / `sshpass`
- OpenShift pull secret (`~/openshift-pull-secret/openshift-pull-secret.txt`)  
  → Download from [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret).

  | Account type | Use case |
  |---|---|
  | **Red Hat Developer Account (free)** | Sufficient for development and testing. [Register here](https://developers.redhat.com/) |
  | **Red Hat Subscription (paid)** | For production environments with full support |

  How to obtain:  
  1. Log in to [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) with either account type  
  2. Click "Download pull secret" to download the JSON file  
  3. Place it at `~/openshift-pull-secret/openshift-pull-secret.txt`

### Fedora

```bash
sudo dnf install -y ansible-core opentofu sshpass
```

### RHEL 9+ / CentOS Stream 9

```bash
# RHEL only: enable EPEL (provides sshpass)
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Add OpenTofu repo and install packages
sudo curl -Lo /etc/yum.repos.d/opentofu.repo \
  https://packages.opentofu.org/opentofu/tofu/config_file.repo?type=rpm
sudo dnf install -y ansible-core opentofu sshpass
```

### libvirt daemons

```bash
# Fedora / RHEL 9+ / CentOS Stream 9 (modular daemons)
for drv in qemu interface network nodedev nwfilter secret storage; do
  sudo systemctl enable --now virt${drv}d.service
done

# RHEL 8 (monolithic daemon)
# sudo systemctl enable --now libvirtd
```

## Configuration

Edit `vars.yml` to set the cluster name, IPs, MAC addresses, OCP version, etc.  
Review all items marked with `[CHANGE]`.

## Usage

```bash
git clone https://github.com/nogunix/sno-auto-builder.git
cd sno-auto-builder

# Install Ansible collection dependencies
ansible-galaxy collection install -r requirements.yml

# Step 1: provision bastion VM + generate Agent ISO on localhost (~5 min)
ansible-playbook 01-infra-bastion.yml

# Step 2: boot SNO master VM and monitor installation to completion (60–120 min)
ansible-playbook 02-create-sno-cluster.yml
```

`02-create-sno-cluster.yml` boots the master VM and then waits for installation to finish using `openshift-install agent wait-for`. The playbook exits once all cluster operators are available.

When complete, credentials are at:

```
~/sno-lab/work/generated/ocp4/auth/kubeconfig
~/sno-lab/work/generated/ocp4/auth/kubeadmin-password
```

> Replace `ocp4` with your `sno_cluster_name` if you changed it in `vars.yml`.

Access the cluster from the host:

```bash
export KUBECONFIG=~/sno-lab/work/generated/ocp4/auth/kubeconfig
oc get nodes
oc get clusterversion
oc get clusteroperators
```

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

Run the following playbook to expose the console to your home network via an nginx stream proxy on the Fedora host:

```bash
ansible-playbook 03-expose-console.yml
```

This installs nginx, configures SSL passthrough to the SNO ingress VIP, and opens ports 80/443/6443 in firewalld.

At the end of the playbook, the required `/etc/hosts` entries are printed. Add them to each device on your home network:

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

## Teardown

```bash
ansible-playbook 99-destroy-all.yml
```
