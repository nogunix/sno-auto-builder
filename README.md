# sno-auto-builder

[![Lint](https://github.com/nogunix/sno-auto-builder/actions/workflows/lint.yml/badge.svg)](https://github.com/nogunix/sno-auto-builder/actions/workflows/lint.yml)
[![Test](https://github.com/nogunix/sno-auto-builder/actions/workflows/test.yml/badge.svg)](https://github.com/nogunix/sno-auto-builder/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![GitHub last commit](https://img.shields.io/github/last-commit/nogunix/sno-auto-builder)

Automatically deploy **OpenShift Single Node (SNO)** on Fedora / RHEL / CentOS Stream / Ubuntu + libvirt using the **Agent-based installer**.

Ansible drives the whole flow; **OpenTofu** provisions the libvirt objects (pool, networks, bastion VM, master VM).

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
- `ansible-core` / `tofu` (OpenTofu) / `sshpass`
- OpenShift pull secret at `~/openshift-pull-secret/openshift-pull-secret.txt`

  A Red Hat Developer account is required (free): https://developers.redhat.com/register  
  Download the pull secret from Red Hat Console: https://console.redhat.com/openshift/install/pull-secret

  > **Note:** Without a paid Red Hat subscription, OpenShift runs as a **60-day evaluation**.  
  > For home lab / learning purposes the evaluation period is typically sufficient.

### Fedora

```bash
sudo dnf install -y ansible-core opentofu sshpass
```

> Not packaged on your release? Use the official installer:
> `curl -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh && chmod +x install-opentofu.sh && ./install-opentofu.sh --install-method rpm`

### RHEL 9+ / CentOS Stream 9+

```bash
# RHEL only: enable EPEL (provides sshpass)
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# OpenTofu is not in the RHEL/CentOS repos — use the official installer
curl -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh && ./install-opentofu.sh --install-method rpm
sudo dnf install -y ansible-core sshpass
```

### Ubuntu 22.04+

```bash
# OpenTofu official installer (adds the deb repo and installs tofu)
curl -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh && ./install-opentofu.sh --install-method deb
sudo apt-get install -y ansible-core sshpass
```

> The playbooks pin the `dmacvicar/libvirt` provider to **0.8.3**, which `tofu init` fetches automatically from `registry.opentofu.org`. The pin is deliberate: 0.9.x is a plugin-framework rewrite with an incompatible resource schema, so it is not a drop-in upgrade.
>
> Migrating a lab that was previously built with Terraform? Its state records the provider under `registry.terraform.io`, which `tofu init` will not install. Either rebuild it (`99-destroy-all.yml`, the clean path) or rewrite the address:
>
> ```bash
> cd ~/sno-lab/work
> tofu state replace-provider \
>   registry.terraform.io/dmacvicar/libvirt registry.opentofu.org/dmacvicar/libvirt
> rm -rf .terraform .terraform.lock.hcl && tofu init
> ```

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

The bastion's **management IP is not configurable** — it comes from the libvirt DHCP lease on `default_network`. The playbooks read it back from the `bastion_ip` OpenTofu output, so there is nothing to keep in sync. The management subnet and bridge themselves are `sno_mgmt_network` / `sno_mgmt_bridge`.

`sno_bastion_password` is stored in plaintext by default. For anything beyond a throwaway lab, encrypt it:

```bash
ansible-vault encrypt_string 'yourpassword' --name sno_bastion_password
```

Ansible behaviour (YAML output, task timing, SSH pipelining) is set in `ansible.cfg` at the repo root.

## Usage

```bash
git clone https://github.com/nogunix/sno-auto-builder.git
cd sno-auto-builder

# Install the collection dependency (also used by the profile_tasks
# callback configured in ansible.cfg)
ansible-galaxy collection install -r requirements.yml

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

# On the bastion — kubeconfig is at ~/.kube/config, so oc works out of the box
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

> **RedHat-family hosts only.** This playbook uses `dnf`, `semanage`, SELinux booleans, `firewalld`, and the `/etc/nginx/stream.d` layout, so it runs on Fedora / RHEL / CentOS Stream. It asserts this up front and stops with a clear message elsewhere. On other distributions, proxy ports 80/443/6443 to the ingress and API VIPs by hand. Playbooks `01`, `02` and `99` are unaffected.

```bash
ansible-playbook 03-expose-console.yml
```

This installs nginx, configures SSL passthrough to the SNO ingress VIP, and opens ports 80/443/6443 in firewalld.

Port 443 routes on SNI (`ssl_preread`), so only known hostnames are forwarded and
the host does not become an open relay for the LAN. `*.apps.<cluster>.<domain>` is
always forwarded. To relay another cluster through the same host — one this repo
did not build, or a second lab — add it to `sno_extra_sni_routes` in `vars.yml`:

```yaml
sno_extra_sni_routes:
  - name: "*.apps.other-lab.home.lab"
    upstream: "192.168.130.10:443"
```

Leave it empty (or omit it) if you only run one cluster.

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

## MCP Server

Run [openshift-mcp-server](https://github.com/openshift/openshift-mcp-server) on
the host so an AI agent can inspect the cluster over MCP:

> **RedHat-family hosts only**, same as `03-expose-console.yml` — it uses `dnf`
> and podman. It asserts this up front.

```bash
ansible-playbook 04-deploy-mcp-server.yml
```

This creates a read-only `mcp-metrics` ServiceAccount on the cluster, adds its
token to a copy of the cluster kubeconfig, writes the `/etc/hosts` entries for
the monitoring routes, and starts the server under podman. It finishes by
querying Thanos Querier and Alertmanager with that token, so a successful run
means the whole path works — not just that the container started.

Register it with your client:

```bash
claude mcp add --transport http openshift-mcp-server http://localhost:8082/mcp --scope user
```

The server is read-only and exposes the `core`, `config`, `openshift` and
`metrics` toolsets. Generated files land in `~/sno-lab/mcp/`; `secret.yaml`
there is mode `0600` because it embeds cluster credentials.

Re-running is safe: the pod is only restarted when the manifest, the kubeconfig
secret, or the pod's running state actually changed. Individual stages can be
run alone with `--tags rbac,kubeconfig,hosts,deploy,verify`.

Adjust `sno_mcp_port`, `sno_mcp_image` and `sno_mcp_toolsets` in `vars.yml` as
needed. Port 8082 is the default because 8080 collides so often.

## Verification

After installation, verify cluster health and console reachability with the included test script:

```bash
bash test/test-console.sh
```

This checks:
- Bastion IP resolves from the `bastion_ip` OpenTofu output
- `oc` and `openshift-install` binaries on the bastion
- Node status (`Ready`)
- Cluster version and all cluster operators (`Available`)
- nginx status and web console HTTP reachability (if `03-expose-console.yml` was run)
- Prints `/etc/hosts` entries needed on client machines and the `kubeadmin` password

### Full lifecycle test

`test/cycle-test.sh` runs create → verify → destroy unattended and prints a
per-phase duration table. Use it to prove a change end-to-end rather than
eyeballing a single playbook run.

```bash
./test/cycle-test.sh --preflight-only   # environment checks only, creates nothing
./test/cycle-test.sh                    # one full cycle (1.5-2.5 h)
./test/cycle-test.sh -n 3               # three back-to-back cycles
./test/cycle-test.sh --keep             # create + verify, skip the teardown
```

Preflight alone is worth running before any long job: it checks the tool
chain, passwordless sudo, libvirt reachability, the pull secret, free
memory/disk, a conflicting `default` pool, and leftovers from a prior run.

> Phase logs land in `~/sno-cycle-logs/<timestamp>/`. The console-check log
> contains the **kubeadmin password**, so the directory is created mode 0700 —
> do not paste raw logs anywhere shared.

## Teardown

```bash
ansible-playbook 99-destroy-all.yml
```

This runs `tofu destroy` and then sweeps up by hand: `virsh undefine` for
anything the state no longer knows about, removal of `sno_base_dir`, the
nginx console config, and the `/etc/hosts` entries the playbooks added. The
manual sweep matters because a lost or partial state file would otherwise
leave orphaned domains and networks behind.

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
  ├─ bastion VM (CentOS Stream)   <DHCP> / 192.168.10.2
  │    dnsmasq · squid · HAProxy · NFS · chrony · oc · openshift-install
  └─ SNO master VM (RHCOS)        192.168.10.10
       control-plane · etcd · ingress · kubelet … all on one node

Networks
  default_network   192.168.222.0/24  NAT  host ↔ bastion (management, DHCP)
  sno01_network     192.168.10.0/24   NAT  bastion ↔ master (cluster L2, static)

VIPs on the bastion cluster NIC: 192.168.10.100 (API) · 192.168.10.101 (ingress)
```

## License

This project is licensed under the [MIT License](LICENSE).

This is my personal project.
It is created and maintained in my personal capacity, and has no relation to my employer's business or confidential information.
