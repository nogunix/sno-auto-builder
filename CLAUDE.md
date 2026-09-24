# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Automates deployment of **OpenShift Single Node (SNO)** on a Fedora/RHEL/CentOS Stream/Ubuntu host using Ansible + OpenTofu + libvirt/KVM. Two VMs are provisioned: a bastion (CentOS Stream) and an SNO master (RHCOS).

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

# Optional: run openshift-mcp-server on the host, pointed at the cluster
ansible-playbook 04-deploy-mcp-server.yml

# Tear everything down
ansible-playbook 99-destroy-all.yml
```

`04-deploy-mcp-server.yml` is tagged so its stages can run on their own:
`rbac` (ServiceAccount + bindings), `kubeconfig` (token → kubeconfig →
`secret.yaml`), `hosts` (the `/etc/hosts` block), `deploy` (render + `podman
kube play` + verify), and `verify` alone to re-check a live deployment.

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
shellcheck test/test-console.sh test/cycle-test.sh test/mock-run.sh test/mock-run-host.sh

# 2. Syntax-check all playbooks
ansible-playbook --syntax-check -i test/inventory \
  01-infra-bastion.yml 02-create-sno-cluster.yml 03-expose-console.yml 99-destroy-all.yml

# 3. Render templates with default vars, then validate the generated .tf
ansible-playbook test-render.yml          # writes to /tmp/sno-rendered
cd /tmp/sno-rendered && tofu init -backend=false && tofu validate && tofu fmt -check -diff
```

`test-render.yml` (repo root) renders `infra.tf.j2`, `bastion.tf.j2`, `master.tf.j2`, `install-config.yaml.j2`, and `agent-config.yaml.j2` — no libvirt or VMs needed, so this is safe to run anywhere.

## Mocked end-to-end run (task coverage)

`test/mock-run.sh` runs `01` and `02` to completion against shims in `test/mock-bin/` (`tofu`, `virsh`, `semanage`, `restorecon`, `openshift-install`). It exists because **`--check` is nearly useless here**: every `command` task is skipped in check mode, so the facts the playbooks register come back empty and the run dies at the first assert — `01` reaches 8 of its 35 tasks, `02` reaches 3 of 16. With the shims on `PATH` the registers are real, `when:` branches evaluate, and `get_url`/`unarchive` actually run against a `file://` tarball built from the fake installer.

```bash
podman run --rm -v "$PWD":/repo:Z -w /repo fedora:44 bash -c \
  'dnf install -y ansible-core tar openssh-server openssh-clients sshpass && \
   ansible-galaxy collection install -r requirements.yml && ./test/mock-run.sh'
```

- **It refuses to run outside a container or CI** unless given `--force`: `02` appends to `/etc/hosts` and the bastion plays create a local user. Keep that guard.
- `HOME` is redirected into the scratch workspace so the fake pull secret never lands in the caller's home directory.
- The script stands up a real `sshd` on `127.0.0.1:22` and a local `redhat` account so the `hosts: bastion_server` plays run; the mock `tofu output -raw bastion_ip` returns `127.0.0.1` to match. Without a usable `sshd` it falls back to `--limit localhost` plus a bare TCP listener on port 22 (which `wait_for` still needs) and the bastion plays are skipped.
- It pre-creates `/etc/helper_node_setup_info` so the bastion block takes its documented idempotency-guard path instead of actually running `helper_node.sh`.
- The last phase is a **negative test**: `MOCK_TOFU_OUTPUT_MISSING=1` makes the mock reproduce the documented gotcha — a missing output warns on *stdout* and exits 0 — and the script asserts that `01` fails at `Assert the bastion received a DHCP lease`. That is the regression test for the IPv4-shape validation; check mode can never reach it.
- `sno_installer_url` (`vars.yml`) exists so this run can point `get_url` at a local file. It also lets a real deployment use an internal mirror.

`test/mock-run-host.sh` is the companion for `03`, `04` and `99`. Those need more than PATH shims — `03`/`99` drive systemd units and firewalld, and `04` talks to a Kubernetes API — so it runs inside the systemd image built from `test/Containerfile.mock-host`:

```bash
podman build -t sno-mock-host -f test/Containerfile.mock-host .
podman run -d --name sno-mock-host --systemd=always --cap-add=NET_ADMIN,NET_RAW \
  -v "$PWD":/repo:Z sno-mock-host
podman exec -w /repo sno-mock-host ansible-galaxy collection install -r requirements.yml
podman exec -w /repo sno-mock-host ./test/mock-run-host.sh
```

- **nginx, dnsmasq, firewalld and systemd are real** in that container — that is the point, since `03` is mostly about whether the generated nginx config loads.
- **Cluster access is faked by shadowing collections, not by editing the playbooks.** `test/mock-collections/` holds test doubles for `kubernetes.core.k8s`/`k8s_info` and `containers.podman.podman_pod`/`podman_pod_info`/`podman_secret`, and `ANSIBLE_COLLECTIONS_PATH` puts that directory ahead of the real ones. Note that variable *replaces* the default search path rather than extending it, so the script has to read the real paths out of `ansible-config dump` and append them — drop that and `03`/`99` lose `ansible.posix.firewalld`.
- `04` runs **before** `03` deliberately: its verification stubs listen on 443, which `03` then hands to the nginx stream proxy.
- The script generates a throwaway CA, signs a server certificate for the three monitoring-route names, and embeds that CA in the fake kubeconfig — so `04`'s `ca_path` verification is exercised for real rather than skipped. The CA needs explicit `basicConstraints`/`keyUsage` extensions or Python rejects it with `CA cert does not include key usage extension`.
- `sno_ingress_vip` is overridden to `127.0.0.1` so the `/etc/hosts` block `04` writes points at those stubs.
- `MOCK_LOG` lives **outside** `WORKDIR`, because `WORKDIR` is `sno_base_dir` and `99` deletes it — same reasoning as `test/cycle-test.sh`'s log directory.
- After `99` the script asserts that both `/etc/hosts` marker blocks, the nginx backend JSON, the nginx stream and HTTP configs and the dnsmasq config are gone. That is the executable form of the "markers must stay byte-identical" rule below; a rename in `03`/`04` without the matching change in `99` fails here.

## Verifying a live cluster

`test/test-console.sh` is the end-to-end check; it needs a running lab and is **not** part of CI.

```bash
./test/test-console.sh      # exits non-zero if any check fails
```

It reads the bastion IP from `tofu output -raw bastion_ip` (same source as the playbooks), SSHes in as the bastion user, and checks `oc`/`openshift-install`, node readiness, clusterversion, all ClusterOperators, nginx, and console HTTP reachability. It also prints the kubeadmin password, so avoid pasting its raw output into anything shared.

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
| `01-infra-bastion.yml` | localhost → bastion → localhost | Renders OpenTofu templates, calls `tofu apply` to create pool/networks/bastion VM, SSHes into bastion to install helper services (dnsmasq, squid, HAProxy, NFS, chrony), then generates the Agent ISO on **localhost** via `openshift-install agent create image` (built in `sno_manifests_dir`, then copied to `sno_tf_dir`) |
| `02-create-sno-cluster.yml` | localhost | Renders `master.tf.j2`, calls `tofu apply` to create the SNO master VM which boots from the Agent ISO |
| `03-expose-console.yml` | localhost | Installs nginx on the host, configures **SNI-based stream proxy** (multiple clusters share ports 443/6443 via `ssl_preread`) plus a **Host-header HTTP proxy** for port 80, opens ports 80/443/6443 in firewalld, adds the console `/etc/hosts` block on this host, writes `hosts-entries.txt` for fallback, and sets up **dnsmasq wildcard DNS** (`*.apps` → host LAN IP) so LAN clients only need a one-line resolver config. Each cluster registers a backend JSON in `/etc/nginx/stream.d/backends.d/` |
| `04-deploy-mcp-server.yml` | localhost | Creates a read-only `mcp-metrics` ServiceAccount plus a long-lived token on the cluster, injects that token into a copy of the cluster kubeconfig, renders the pod manifest, adds the monitoring-route `/etc/hosts` block, and runs `openshift-mcp-server` under podman on the host |
| `99-destroy-all.yml` | localhost | Removes the MCP pod/secret, `tofu destroy`, manual `virsh undefine` fallbacks, removes `sno_base_dir`, cleans up this cluster's nginx backend (rebuilds the stream and HTTP configs if other clusters remain, otherwise tears nginx down), removes per-cluster dnsmasq DNS config, and all three `/etc/hosts` entries |

### Template rendering flow

All files in `templates/` are Jinja2 templates, rendered at runtime by the playbooks (most by `01`; `master.tf.j2` by `02`). Destinations vary as noted below:

- `infra.tf.j2` → `infra.tf` — `required_version`/provider pin, libvirt pool, `default_network` (NAT, `sno_mgmt_network`, DHCP), `sno_prefix_network` (NAT, no DHCP)
- `bastion.tf.j2` → `sno_prefix_bastion0.tf` — bastion VM with cloud-init (user/password, static IP on cluster NIC) plus the `bastion_ip` output
- `master.tf.j2` → `sno_prefix_cluster_master0.tf` — SNO master VM booting from Agent ISO as cdrom
- `helper_node.sh.j2` → runs on bastion — installs dnsmasq/squid/HAProxy/NFS/chrony, downloads `oc` + `openshift-install` from `mirror.openshift.com`
- `install-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`
- `agent-config.yaml.j2` → rendered on localhost into `sno_manifests_dir`; `openshift-install agent create image` then generates the ISO
- `nginx.conf.j2` → `/etc/nginx/nginx.conf` — `stream` block including `/etc/nginx/stream.d/*.conf` and an `http` block including only `/etc/nginx/http.d/*.conf` (rendered by `03`)
- `nginx-sno-stream.conf.j2` → `/etc/nginx/stream.d/sno.conf` — SNI-based stream proxy for ports 443/6443, supports multiple clusters via `ssl_preread` routing (rendered by `03`, rebuilt by `99`)
- `nginx-sno-http.conf.j2` → `/etc/nginx/http.d/sno.conf` — Host-header reverse proxy for port 80, one `server` per cluster (rendered by `03`, rebuilt by `99`)
- `dnsmasq-sno.conf.j2` → `/etc/dnsmasq.d/sno-<cluster>.<domain>.conf` — per-cluster wildcard DNS for `*.apps` and `api`/`api-int` (rendered by `03`)
- `openshift-mcp-server-pod.yaml.j2` → `sno_mcp_dir/openshift-mcp-server-pod.yaml` — podman kube manifest, two documents (ConfigMap holding the server's `config.toml`, then the Pod) (rendered by `04`)

### Network topology

```
Host (libvirt)
  ├─ default_network  192.168.222.0/24  NAT  DHCP — host ↔ bastion management NIC
  └─ sno_network      192.168.10.0/24   NAT  no DHCP — bastion cluster NIC ↔ master
       bastion eth1:  192.168.10.2 (proxy_ip) + .100 (api_vip) + .101 (ingress_vip)
       master enp1s0: 192.168.10.10
```

### Key design decisions

- **OpenTofu state is split**: infra (pool, networks, bastion) is managed by `01-infra-bastion.yml`; the master VM is managed by `02-create-sno-cluster.yml`. Playbook `01` explicitly removes `libvirt_domain.sno_prefix_master0` from state before applying, so re-running `01` never touches the master. **Re-run safety:** `01` is safe to re-run — it leaves a running master untouched (and the bastion setup is idempotency-guarded). Re-running `02` re-renders `master.tf` and re-applies the master VM, so only re-run it when you intend to recreate/reconfigure the master.
- **Bastion IP comes from an OpenTofu output, not `virsh`**: the bastion's management NIC is DHCP, and `bastion.tf.j2` exposes the lease as the `bastion_ip` output (`wait_for_lease = true` guarantees it is populated at apply time). `01`, `02` and `test/test-console.sh` all read it with `tofu output -raw bastion_ip`. There is **no** `sno_bastion_ip` variable in `vars.yml` — it is a runtime fact only.
  - **Gotcha:** when the output is missing (e.g. state predating this change), `tofu output -raw` writes a *warning to stdout* and still **exits 0**. An emptiness or exit-code check would treat that warning text as an IP, so every caller validates the IPv4 shape instead. Keep that validation if you touch these call sites.
- **`/etc/hosts` is written by two playbooks, pointing at two different IPs — deliberately.** `02-create-sno-cluster.yml` adds one plain line for `api`/`api-int` → `sno_api_vip`, because the host reaches the VIP directly over the libvirt NAT network and `openshift-install wait-for` needs it during the install. `03-expose-console.yml` adds a marker block for the `apps.*` names → the *host's* LAN IP, which goes through the nginx stream proxy. Do **not** add `api` to the 03 block: two entries for the same name would shadow each other. Devices other than the host cannot reach the VIP at all, so `hosts-entries.txt` lists `api` → host IP for them. `99-destroy-all.yml` removes both, and the marker/line there must stay byte-identical to what 02 and 03 write or teardown silently leaks a stale entry.
- **Secrets are marked `no_log`**: the tasks that render `login_bastion.sh` (mode `0700`, it embeds the password) and that `add_host` the bastion with `ansible_password` both set `no_log: true`. Do not remove it to make debugging easier. In `04-deploy-mcp-server.yml` the same applies to every task that touches the ServiceAccount token or the kubeconfig body.
- **`04`'s `/etc/hosts` block is what makes the metrics tools work, not the pod's `hostAliases`.** Under `hostNetwork: true`, `podman kube play` silently ignores `hostAliases` and seeds the container's `/etc/hosts` from the *host's* file. The manifest keeps its `hostAliases` as documentation and as a fallback if `hostNetwork` is ever dropped, but the host block is load-bearing — without it the tools fail with `dial tcp: lookup ...: no such host`. Its names point straight at `sno_ingress_vip`, unlike `03`'s console block which goes via the host's LAN IP: the MCP server runs on this host and reaches the VIP directly, so the nginx hairpin would be pointless. The two name sets are disjoint, so neither shadows the other.
- **The MCP kubeconfig carries a client certificate *and* a token, deliberately.** The monitoring routes sit behind `kube-rbac-proxy`, which only accepts a bearer token — a client certificate alone gets `401`, so `auth_mode = "kubeconfig"` needs a token in the file. Both credentials coexist: the Kubernetes API authenticates the certificate first and keeps admin access, and only the routes use the token. `cluster-monitoring-view` covers Thanos Querier; Alertmanager additionally needs the namespaced `monitoring-alertmanager-view` or it answers `403`. The bindings are named after the ServiceAccount rather than the ClusterRole, because `oc adm policy add-cluster-role-to-user` would reuse a generic shared binding that teardown could not remove safely.
- **`04`'s verification requests pass `ca_path`, not the system trust store.** The server validates the route certificate against the kubeconfig CA bundle, which carries the ingress CA; this host's system store does not. A plain `validate_certs: true` check therefore fails on a perfectly good deployment, so the playbook writes the bundle to `sno_mcp_dir/cluster-ca.crt` and points `uri` at it.
- **`04` only redeploys when something changed**: redeploying restarts the server, so the pod/secret teardown and `podman kube play` are gated on the rendered manifest or `secret.yaml` having changed, or the pod not being `Running`. Keep that guard — without it every re-run bounces a healthy pod.
- **Provider is pinned to `dmacvicar/libvirt` 0.8.3 deliberately**: 0.9.x is a plugin-framework rewrite with an incompatible schema (`devices = { disks = [...] }`, `os = { boot_devices = [...] }` replace `disk`/`network_interface`/`cloudinit`/`boot_device`). Do not "upgrade" the pin without rewriting all three `.tf` templates.
- **`03-expose-console.yml` is RedHat-family only** and asserts so up front: it uses `dnf`, `semanage`, `seboolean`, `firewalld`, and the `/etc/nginx/stream.d` / `http.d` layout. The other playbooks are portable. CI syntax-checks Ubuntu, but syntax-check does not execute these tasks.
- **nginx uses SNI-based routing to support multiple clusters on the same host.** Ports 443 and 6443 use `ssl_preread` + `map` to inspect the TLS ClientHello SNI and route to the correct cluster's VIP. Each cluster registers its backend definition as a JSON file in `/etc/nginx/stream.d/backends.d/<cluster>.<domain>.json`; `03-expose-console.yml` discovers all registered backends and renders a single unified stream config. `99-destroy-all.yml` removes only the destroyed cluster's backend file and rebuilds the config for remaining clusters (or tears nginx down entirely if none remain). Port 80 has no TLS and so no SNI; it is served by an `http` block instead (`/etc/nginx/http.d/sno.conf`) that routes on the `Host` header with one `server_name *.<apps_domain>` per cluster, falling back to the first registered cluster. `99` rebuilds that file alongside the stream config, or deletes it with the last cluster. That `http` block includes `http.d/*.conf`, **not** `conf.d/*.conf`: `conf.d` is shared with other packages (php-fpm, nginx.org's `default.conf` on port 80), and the original stream-only design existed precisely to keep such configs out. Its proxy settings (`client_max_body_size 0`, HTTP/1.1 with `Upgrade`, no buffering, 10 min timeouts) exist to keep port 80 behaving like the raw TCP proxy it replaced — without them uploads over 1 MB get `413` and plain-HTTP WebSockets break. Do not use firewall `forward-port` rules for cluster traffic — they bypass nginx and conflict with SNI routing.
- **dnsmasq wildcard DNS complements `/etc/hosts`, not replaces it.** `/etc/hosts` on the host ensures resolution even if dnsmasq is down; dnsmasq on the host's LAN IP provides `*.apps` wildcard so every Route resolves for LAN clients without per-name entries. dnsmasq uses `listen-address` + `bind-dynamic` to bind only the LAN IP, avoiding port 53 conflicts with systemd-resolved (which listens on 127.0.0.53). It must stay `bind-dynamic`, **not** `bind-interfaces`: the LAN address is normally a DHCP lease, and stock `dnsmasq.service` is ordered `After=network.target` only, so at boot the address does not exist yet and `bind-interfaces` aborts the service with `failed to create listening socket ...: Cannot assign requested address`. Note the directive is global to dnsmasq, so a single stale `/etc/dnsmasq.d/*.conf` still carrying `bind-interfaces` brings the bug back for every cluster. The config also sets `no-hosts`, and that is load-bearing: without it dnsmasq serves this host's `/etc/hosts` too, and those entries win over the `address=` lines. `02` writes `api`/`api-int` → `sno_api_vip` and `04` writes the monitoring routes → `sno_ingress_vip` there — both libvirt NAT addresses that LAN clients cannot reach — so dropping `no-hosts` hands out unreachable answers for exactly the names this file exists to fix ("the console alone won't open").
- **Idempotency guard on bastion setup**: `helper_node.sh` writes `/etc/helper_node_setup_info` on completion; `01-infra-bastion.yml` skips the block if that file exists.
- **ISO handoff**: the Agent ISO is generated on **localhost** (not the bastion) by `openshift-install agent create image` into `sno_manifests_dir`, then copied to `sno_tf_dir`; the master VM references it as a local file path in its disk block.
- **Bastion cluster NIC**: assigned a static IP via cloud-init network config in `bastion.tf.j2`; `helper_node.sh` then adds the api/ingress VIPs as additional addresses via `nmcli`.
- **Bastion kubeconfig lives at the bastion user's `~/.kube/config`** (default user `redhat`), copied there by `02-create-sno-cluster.yml` — *not* `/root/kubeconfig`, and there is no `KUBECONFIG` env var. `oc`/`kubectl` find it via the default path. **Anything that runs `oc` on the bastion must run as the bastion user, not root** — root has no kubeconfig. `test/test-console.sh` uses `sudo -iu "$BASTION_USER"` for this reason; do not change it to `sudo -i` (root). The `oc`/`openshift-install` binaries are in `/usr/local/bin` (on the login PATH).

## Configuration

All tunable parameters are in `vars.yml`. Fields marked `[CHANGE]` must be reviewed before first run:

- `sno_base_dir` — where OpenTofu state, pool, and ISO land on the host (default: `~/sno-lab`)
- `sno_cluster_version` — OCP release stream (e.g. `stable`, `stable-4.21`)
- `sno_bastion_password` / `sno_bastion_os_image` — bastion credentials and cloud image URL
- `sno_cluster_name` / `sno_base_domain` — cluster FQDN components
- `sno_master_mac` / `sno_interface` — must match the libvirt NIC definition in `master.tf.j2`
- MAC addresses for bastion NICs (`sno_bastion_mac_mgmt`, `sno_bastion_mac_sno`) — must be unique on the host
- `sno_mgmt_network` / `sno_mgmt_bridge` — CIDR and bridge name for `default_network` (were hardcoded in `infra.tf.j2` before)

The bastion's management IP is deliberately **absent** from `vars.yml` — see the OpenTofu-output design decision above.

## CI

- **Lint** (`.github/workflows/lint.yml`): runs `ansible-lint` on every push/PR to `main`
- **Test** (`.github/workflows/test.yml`): runs on every push/PR to `main`
  - **Syntax check**: `ansible-playbook --syntax-check` on all 4 playbooks, across 6 distros (Fedora 43/44, CentOS Stream 9/10, Ubuntu 24.04/26.04) using container jobs
  - **Template render + tofu validate**: renders all Jinja2 templates with default vars, then runs `tofu init -backend=false`, `tofu validate` and `tofu fmt -check -diff` on the generated `.tf` files (uses `opentofu/setup-opentofu@v1` with `tofu_wrapper: false`). Templates must therefore render *already formatted* — run `tofu fmt` on `/tmp/sno-rendered` and port any change back into the `.j2` source.
  - Test playbook is `test-render.yml` (repo root); minimal inventory for syntax check is `test/inventory`
- **OCP version check** (`.github/workflows/ocp-version-check.yml`): runs weekly (Monday 00:00 UTC), fetches the current stable OCP version, verifies download URLs for `oc`/`openshift-install`, re-runs `ansible-lint`, and opens a GitHub issue (or adds a comment to an existing one) if anything fails
