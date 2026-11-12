# disconnected / ベアメタル模擬環境の実機検証メモ (elitemini / Fedora 45 KVM)

- 対象: disconnected (閉域) 環境における SNO + ワーカー構成のベアメタル模擬検証 (OMR 2.0.12、Agent ベースインストール、NMState / iSCSI 構成)
- 実施日: 2026-11-12
- 環境: elitemini (Ryzen 9 8945HS / 60 GB RAM / Fedora 45)、libvirt/KVM。sno-auto-builder (本リポジトリ) で構築
- 版: OCP **4.20.42** / oc-mirror **4.22.18** (`oc-mirror version` の表示は `4.22.0-202610061703.p2...`。z-stream の番号は表示されない) / OMR **2.0.12** (オフライン版)
- ブランチ: `feat/baremetal-verification` (`feat/ocp5-support` 2626062 から分岐。main には disconnected 対応がないため)
- 構成の対応関係: SNO を物理ノード1台の代わりとした。bastion VM (CentOS Stream 9) が DNS (dnsmasq)、LB (haproxy)、NTP (chrony)、OMR、iSCSI ターゲットを兼ねる。クラスタのネットワークは libvirt の isolated (外部へ出られない) とした

> 表記: **【実機確認】** = 本検証で実際にコマンドを実行して確認したもの。**【未実施】** = 実行していないもの。
> 検証で得られた実機挙動の注意点やハマりどころを中心に記録している。

---

## 1. 結果一覧

| 項目 | 実行 | 結果 | 注意点 / 気付き |
|---|---|---|---|
| ベースライン (repo の既定 disconnected フロー: registry:2 + m2m) | 実機確認 | 01: 26.6 分 (ミラー 22 分)、02: 41.5 分 (bootstrap 15.7 分、install-complete 25.7 分、リトライなし) | repo のバグはなし |
| mirror-to-disk (m2d) | 実機確認 | dry-run 2 分、mapping.txt 216 件。本実行 26.5 分 RC=0、190/190 + 26/26。アーカイブ 28.5 GiB | ① 同じホストで2本並行すると `[Executor] 55000 is already bound` で即座に exit 1 になり、`--port` が必要。② **同じ作業ディレクトリで再実行すると差分アーカイブになる** (§3 の A) |
| チェックサムの照合 (持ち込み前後) | 実機確認 | `sha256sum -c` OK (30.6 GB で 39 秒) | なし |
| OMR 用データ領域 (by-id, nofail) | 実機確認 | `/dev/disk/by-id/wwn-0x5000c500a1b2c301` で mkfs.xfs と fstab への登録、マウント OK | なし |
| OMR 2.0.12 install | 実機確認 (CentOS Stream 9。**OMR のサポート対象 OS ではない**) | 2 分 20 秒で成功 | **`--sslCert/--sslKey` (独自 CA) を指定した場合は `quay-rootCA/rootCA.pem` が作られない**。rootCA.pem の有無による成否判定は自己署名の場合にしか使えない (§3 の C) |
| OMR 信頼登録・ログイン・稼働確認 | 実機確認 | update-ca-trust、`/v2/` が 401、`podman login --authfile` OK。quay-app (quay-rhel8:v3.12.21)、quay-redis、DB_URI は sqlite | curl で `-u` (Basic 認証) を使って OMR の /v2 API を確認しようとすると 401 `Invalid bearer token format` になる (§3 の D) |
| disk-to-mirror (d2m, 並列度 1/1) | 実機確認 | 955 秒、190/190 + 26/26、413/502 は発生せず | なし |
| d2m 生成物 (CS/IDMS/ITMS/署名 CM) | 実機確認 | `cs-/cc-redhat-operator-index-v4-20.yaml`、`idms-`/`itms-oc-mirror.yaml`、`signature-configmap.*` が生成 | なし |
| platform: none / machineNetwork | 実機確認 (SNO) | `platform: none`、machineNetwork 1件でインストール成功。infrastructure の platform=None | なし |
| LB (haproxy) | 実機確認 | 6443/22623/443/80 で待ち受けていることを確認 | **RHEL9/CS9 の最小構成には `netstat` がない** (net-tools は非推奨)。`ss -nltp` を使う。`haproxy_connect_any` が off でも、`semanage port -a -t http_port_t` (6443/22623) で動作する (setsebool の代替) |
| DNS (dnsmasq) | 実機確認 | api / api-int / *.apps / master0 の正引き、.10 / .100 の逆引き OK (dnsmasq は /etc/hosts から PTR も返す) | なし |
| NTP (chrony) | 一部 | additionalNTPSources=bastion で "Host NTP is synced" | **NTP に到達できない場合の挙動は【未実施】** |
| ミラーからの oc / openshift-install 抽出 | 実機確認 | 両方成功。release image はミラーの digest を指す | なし |
| Agent ISO 作成 (base ISO 事前配置なし) | 実機確認 (bastion の default route を削除し、キャッシュを空にして実施) | RC=0 (50 秒)。base ISO は machine-os-images からミラー経由で取り出された | **ミラー設定がある場合、事前配置は不要**。**networkConfig を書く場合は ISO を作るホストに `nmstate` (nmstatectl) が必要** (§3 の E) |
| bond0 (active-backup) | 実機確認 | NMState で bond0 を ens3 と ens4 で構成。インストール後、bond0 は br-ex の OVS ポートになる | networkConfig の名前 (eno1/eno2) が実名 (ens3/ens4) と違っても、`interfaces[].macAddress` で対応付けされた |
| rootDeviceHints (wwn 指定) | 実機確認 | `wwn` 指定で、120G ディスク (ゲストでの名前は **sdc**) に導入された | **ゲスト内の /dev/sdX の順序はハイパーバイザの定義順と一致しない** (§3 の F)。**さらに起動順の問題でインストールが無限ループした** (§3 の B) |
| マルチパス | 実機確認 | 導入後のノードでは multipathd が inactive で、multipath.conf もない | ライブ ISO では既定で有効だが、導入後は無効 |
| VLAN (ワーカー起動時設定) | 実機確認 (ワーカーで起動時に VLAN を構成) | bond0.20 が up し、疎通 OK。タイムアウトは発生せず | 対象 z-stream では問題なく動作 |
| cluster-manifests によるミラー・CA 設定 | 実機確認 | `mirror/registries.conf` と `mirror/ca-bundle.crt` が作成された | ミラーから取り出した installer では、「imageDigestSources に releaseImage と一致する source がない」という WARNING が出る (実害なし) |
| インストール完了まで | 実機確認 | 成功 (起動順の修正後) | **`no clusterID known` は版の不一致以外でも出る** (§3 の B, G) |
| CSR 承認 | 実機確認 (ワーカー追加時) | クライアント → サーバーの順に承認して正常化 | **サーバー CSR を承認する前に node は Ready になり、`oc logs` が `remote error: tls: internal error` で失敗する**。承認後は logs/exec とも OK |
| 内部レジストリ有効化 | 実機確認 | 初期状態は Removed。NFS の RWX PV + patch で Managed、2 レプリカで動作 | **Removed の状態でも `oc get co image-registry` は True/False/False と表示される** (§3 の H) |
| 既定 StorageClass なし時の挙動 | 実機確認 | SC 0 件、PVC は Pending、イベントは Type=**Normal** FailedBinding | 異常時でもイベント種別は Normal になる |
| ノードのミラー・CA 設定確認 | 実機確認 | registries.conf にミラーがあり、CA はノードの信頼ストアにある | **`grep -c "CN=<FQDN>" tls-ca-bundle.pem` は CA があっても 0 になる** (§3 の I) |
| Operator CatalogSource / IDMS / ITMS | 実機確認 | CatalogSource は 3 分以内に READY。registry-cas ConfigMap と additionalTrustedCA を設定。ITMS にしかない source はなし。IDMS の適用ではノードは再起動しなかった | なし |
| `oc adm node-image` でワーカー追加 | 実機確認 | `oc adm node-image create` 274 秒 (disconnected で動作) → 起動 → CSR 承認 → Ready。label / taint OK | ABI (Agent-Based Installer) 環境のワーカー追加では `oc adm node-image create` がそのまま利用できる |
| ストレージセグメント (NMState / 静的ルート / iSCSI) | 実機確認 | NNCP が Available。静的ルートがある場合だけ到達できることを確認。iSCSI のログインと PV のマウント OK | §3 の J |
| 事後ヘルスチェック (CSR / logs / registry / NTP / LB / DNS) | 実機確認 | 保留 CSR 0 件、logs/exec OK、レジストリは Managed、chrony 同期、LB 待ち受け、dig OK | レジストリの状態確認は `co` ではなく `configs.imageregistry` で見る (§3 の H)。LB 待ち受け確認は `ss` を使う |

---

## 2. 実行したコマンド (要点)

### 2.1 mirror-to-disk (接続側 = ホスト)
```sh
oc-mirror -c imageset-config.yaml file://$HOME/sno-mirror-run2/archive --v2 --port 55100 \
  --cache-dir $HOME/sno-mirror-run2/.cache --authfile <pull-secret> --dry-run
oc-mirror -c imageset-config.yaml file://$HOME/sno-mirror-run2/archive --v2 --port 55100 \
  --cache-dir $HOME/sno-mirror-run2/.cache --authfile <pull-secret>
```
ImageSetConfiguration: `stable-4.20`、4.20.42 で固定。operators は redhat-operator-index:v4.20 の `cluster-logging` と `kubernetes-nmstate-operator` (既定チャネルの先頭)。

### 2.2 OMR install (閉域側 = bastion、root、HOME=/root USER=root)
```sh
./mirror-registry install --quayHostname bastion0.ocp4.example.com:8443 \
  --quayRoot /data/quay-install --quayStorage /data/registry-storage/quay-storage \
  --sqliteStorage /data/registry-storage/sqlite-storage --image-archive image-archive.tar \
  --sslCert registry.crt --sslKey registry.key --initUser init --initPassword '***' \
  --targetUsername root --targetHostname localhost
```
installer は `/root/.ssh/quay_installer` を生成し、authorized_keys に追記した (cloud-init の disable_root 環境でも動作)。

### 2.3 disk-to-mirror (bastion)
```sh
sha256sum -c CARRY-LIST.sha256
oc-mirror -c imageset-config.yaml --from file:///data/carry docker://bastion0.ocp4.example.com:8443 --v2 \
  --cache-dir /data/oc-mirror-cache --authfile /root/.config/containers/auth.json \
  --parallel-images=1 --parallel-layers=1 --image-timeout 30m --retry-times 8 --retry-delay 10s
```

### 2.4 agent-config (master、抜粋)
```yaml
rootDeviceHints:
  wwn: '0x5000c500a1b2c312'
interfaces: [{name: eno1, macAddress: ..:10}, {name: eno2, macAddress: ..:11}, {name: eno3, macAddress: ..:12}]
networkConfig:
  interfaces:
    - {name: bond0, type: bond, link-aggregation: {mode: active-backup, options: {miimon: "100"}, port: [eno1, eno2]}, ipv4: ...}
```

### 2.5 NNCP (インストール後)
```yaml
interfaces:
  - {name: storage0, type: ethernet, identifier: mac-address, mac-address: "52:54:00:26:A1:12", ipv4: {address: [{ip: 192.168.30.10, prefix-length: 24}]}}
  - {name: bond0.20, type: vlan, vlan: {base-iface: bond0, id: 20}, ipv4: {address: [{ip: 192.168.120.10, prefix-length: 24}]}}
routes:
  config: [{destination: 192.168.31.0/24, next-hop-address: 192.168.30.1, next-hop-interface: storage0}]
```

### 2.6 ワーカーの追加
```sh
oc adm node-image create --dir worker --registry-config <ミラー認証を含む auth.json> --report
oc adm node-image monitor --ip-addresses 192.168.10.20 -a <auth.json>
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve   # 2回 (クライアント → サーバー)
```

---

## 3. 検証で得られた知見・注意点 (詳細)

### A. 【重要】mirror-to-disk の再実行は差分アーカイブを作るが、ログでは区別できない
- 同じ ImageSetConfiguration、同じアーカイブ出力先、同じキャッシュで m2d を2回目に実行した。ログは `190 / 190 release images` / `26 / 26 operator images mirrored successfully` で exit 0。それでも **`mirror_000001.tar` は 3.6 GiB** だった (1回目は 28.5 GiB)。
- これを**空の OMR** に d2m すると、46 秒で rc=4 になった:
  `collect catalog "registry.redhat.io/redhat/redhat-operator-index:v4.20": ... 127.0.0.1:55000/redhat/redhat-operator-index: manifest unknown`
- 原因は `<archive-dir>/working-dir/.history/.history-<timestamp>`。前回の m2d の内容を記録しており、次の m2d はそれとの差分だけをアーカイブにする。
- **終了コード 0 や件数一致 (X/X)、アーカイブファイルの存在確認だけでは、完全なアーカイブと差分アーカイブを区別できない。**
- 運用上の注意点:
  - 初回 (空のレジストリへの投入) に使うアーカイブは、`.history` のない作業ディレクトリで作る。
  - アーカイブのサイズが dry-run の想定と合っているかを確認する。
  - 差分更新の持ち込みと初回の持ち込みとで、作業ディレクトリの扱い (`.history` を残すか消すか) が逆になる点に注意する。

### B. 【重要】ファームウェアの起動順が rootDeviceHints のディスクに向いていないと、インストールが無限ループする
- 3ディスクのうち2台目 (wwn 指定) に導入した。"Writing image to disk 100%" の後に再起動したが、BIOS の `boot dev=hd` は**1台目のディスクしか試さない**。そのため空のデータディスクから起動できず、Agent ISO から起動し直した。rendezvous ホストは**新しいクラスタとしてインストールを最初からやり直し**、これを繰り返した。
- `agent wait-for bootstrap-complete` には、`Unable to retrieve cluster metadata from Agent Rest API: [GET /v2/clusters/{cluster_id}][404] v2GetClusterNotFound` が延々と出るだけだった。明示的なエラーは出ず、60 分のタイムアウトで終了した。
- 実機での注意点: **rootDeviceHints で選んだディスク (UEFI の場合はそのブートエントリ) が、ISO より先に起動する順序にする。ISO の起動は one-time boot にする。**
- repo 側は、master の起動順をデバイスごと (root ディスク → cdrom) に XSLT で設定して回避した。

### C. `--sslCert/--sslKey` を使うと `quay-rootCA/rootCA.pem` は作られない
- 自己署名証明書を使う場合は `/data/quay-install/quay-rootCA/rootCA.pem` が生成されるが、`--sslCert/--sslKey` で独自 CA の証明書を指定した場合は `rootCA.pem` は作られない。
- 独自 CA の場合は `quay-install/quay-config/config.yaml` (または `ssl.cert`) の存在と、`podman ps` で稼働を確認する。

### D. OMR の /v2 API には Basic 認証が使えない
- `curl -u init:*** https://<omr>:8443/v2/<repo>/tags/list` は 401 `{"error": "Invalid bearer token format"}` になる。
- token フローが必要: `GET /v2/auth?service=<host>:8443&scope=repository:<repo>:pull`。**service にはポートまで含める必要があり、含めないと `Audience doesn't match`** になる。
- 疎通確認には curl よりも podman / skopeo / oc を使う方が簡単。

### E. ISO 作成ホストには nmstate が必要。CoreOS ISO の事前配置は不要
- `agent create image` は、networkConfig の検証に `nmstatectl` を使う。ない場合は次のエラーになる:
  `failed to validate network yaml for host 0, install nmstate package, exec: "nmstatectl": executable file not found in $PATH`
- **閉域側に持ち込む RHEL パッケージに `nmstate` を含める必要がある。**
- インターネットなし・`~/.cache/agent` 空の状態で、`Extracting base ISO from release payload` → `Using mirror configuration` → `oc adm release info --image-for=machine-os-images ... <mirror>` → `Base ISO obtained from release and cached` となった。事前配置しなくても成功した。
  - 事前配置なしだとタイムアウトするのは、ミラー設定がない環境の話と考えられる。
  - なお、内部で実行される oc は `--insecure=true` で呼ばれている。

### F. /dev/sdX の順序は信用できない
- libvirt の定義は sda=40G(c311)、sdb=120G(c312)、sdc=20G(c313)。ゲスト内では **sda=40G、sdb=20G、sdc=120G** だった。
- `deviceName: /dev/sda` だけでなく、定義順から推測した `/dev/sdb` でも誤ったディスクを選ぶことになる。
- `udevadm info` の結果は `ID_WWN` = `ID_WWN_WITH_EXTENSION` = `0x5000c500a1b2c312`。この値を `wwn` に指定して正しく選択された。
- `deviceName` ではなく `wwn` を指定する方式の有効性を確認できた。

### G. `no clusterID known for the cluster` は版の不一致以外でも出る
- ワーカーの node-image monitor の最初に一時的に出た (版は一致しており、その後は正常に進んだ)。
- B の無限ループでも、近い内容のメッセージ (404 cluster not found) だけが出続けた。
- 「このメッセージ = 版の不一致」とは限らないため、継続して出力され続けるかどうかで切り分ける必要がある。

### H. image-registry の ClusterOperator は Removed でも True と表示される
- インストール直後は `spec.managementState: Removed`。それでも `oc get co image-registry` は `True False False` と表示される。
- このため `oc get co image-registry` だけでは Managed と区別できない。**`oc get configs.imageregistry cluster -o jsonpath='{.spec.managementState}'` を確認する。**
- `config.image/cluster` への patch (`storage.managementState: Unmanaged` + `pvc.claim`、`replicas: 2`) はそのまま受理され、動作した。
  - NFS の RWX 静的 PV を使用。status.storageManaged=false。
  - 2 レプリカは master とワーカーに分散した。
  - SNO では kube-apiserver が新しいリビジョンに切り替わり、authentication / openshift-apiserver が約5分 Available=False になってから回復した。

### I. `tls-ca-bundle.pem` に対する `grep -c "CN=<FQDN>"` は 0 を返す
- `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` には、証明書ごとに `# <ラベル>` (CN の値で、`CN=` は付かない) というコメント行しか出ない。
- 本検証の CA (CN=`SNO Mirror CA (ocp4.example.com)`) では、CA が存在しても 0 になった。
- 確認方法の候補: `trust list | grep -A3 '<CN の値>'` (結果は `trust: anchor`)、または `grep -c '^# <CN の値>'`。
- OMR の自己署名 CA では試していない。

### J. ストレージセグメント (NMState / 静的ルート / iSCSI)
- **libvirt の Linux ブリッジは VLAN タグをそのまま通す**ので、bond0 をトランクとし、ネイティブ VLAN (タグなし) をマシンネットワークにする構成を模擬できた。
- NNCP:
  - ストレージ NIC は nmstate の `identifier: mac-address` で指定した。カーネルでの名前に依存しない。プロファイル名は storage0、実体は ens5。
  - ストレージ側の経路は、ターゲットのサブネット宛ての静的ルートだけを設定した。
  - 管理 VLAN は bond0.20。
  - いずれも数秒で `SuccessfullyConfigured` になった。
- **bond0 が br-ex の OVS ポートになった後でも、bond0 上の VLAN サブインタフェースで通信できた** (bastion の VLAN IP へ ping が 3/3)。
  - 失敗すると予想していたが、4.20.42 のこの構成では動作した。
  - Red Hat のサポート上の扱いは未確認。
- 静的ルートの効果: ルートを削除すると `ip route get` が default (br-ex) を返し、ping は失敗する。ルートがあるときは ens5 経由で通る。
- iSCSI:
  - `iscsiadm` の discovery とログインに成功した。セッションの `Iface IPaddress: 192.168.30.10` で、ストレージ NIC 経由であることを確認した。
  - iscsid の手動有効化は不要だった (ソケット起動)。
  - in-tree の iSCSI 静的 PV を Pod でマウントし、書き込みもできた。
- 注意: 動作確認用のイメージもミラーにあるものを使う必要がある。`registry.redhat.io/ubi9` は RegistryUnavailable になったので、リリースペイロードの cli イメージを digest 指定で使った。

### K. その他
- OMR install は ansible の become (HOME/USER を明示) から実行して問題なかった。
- `oc adm node-image create` のレポートは、OSImage の URL として rhcos.mirror.openshift.com を表示する。ただし実際の取得は「Extracting base image from release payload」(ミラー経由) だった。
- ワーカーの monitor は一時的に `insufficient (Host does not meet the minimum hardware requirements: )` と表示した (理由は空)。約1分で known に変わった。

---

## 4. repo (sno-auto-builder) で見つけた・直した問題
- 【修正】OMR (Quay) に対する tags/list の確認を Basic 認証から token フローに変更した (D)。
- 【修正】m2d の差分アーカイブ問題: 既定で `working-dir/.history` を削除し、毎回完全なアーカイブを作る (`sno_mirror_m2d_incremental: true` で差分モード) (A)。
- 【修正】複数ディスク構成での起動順: XSLT でデバイスごとの boot order を設定する (B)。
- 【既存の問題・記録のみ】bastion の cloud-init network_config は CS9 の cloud-init に全体ごと拒否される (`Address default is not a valid ip network`。原因は `to: default`)。DHCP にフォールバックし、helper_node.sh の nmcli だけが効いている。追加 NIC と VLAN は 05 の nmcli で設定した。
- 【注意】同じホストで oc-mirror を並行実行するとポートが衝突する。

---

## 5. 実施しなかったもの
- NTP に到達できない状態の挙動 (本検証では省略)
- `platform: baremetal` (VIP / keepalived) — SNO は none 必須のため対象外
- UPI / IPI
- OMR の自己署名 CA での信頼ストア・ノード設定確認 (本検証は独自 CA 相当の `--sslCert`)
- LACP 等の active-backup 以外の bond、物理スイッチ側のトランク設定
- 3ノード以上での `platform: none` (LB の 443/80 の振り分けなど)

## 6. 所要時間の記録
| 工程 | 時間 |
|---|---|
| m2m (registry:2) | 22 分 |
| m2d 初回 (コールドキャッシュ) / 再作成 (ウォームキャッシュ) | 26.5 分 / 7 分 |
| bastion への持ち込み (rsync 30.6 GB) | 8.6 分 |
| d2m (OMR、1/1) | 16 分 |
| OMR install | 2.3 分 |
| SNO インストール (bond / 3ディスク、修正後) | 40.5 分 (bootstrap 14 分、install-complete 26 分) |
| node-image create / ワーカー参加 (起動から Ready まで) | 4.6 分 / 約 12 分 |
