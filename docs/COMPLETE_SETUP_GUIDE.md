# Hướng dẫn Setup Lab từ Đầu
## Private Cloud: Kubernetes + Rook-Ceph + ArgoCD + Full Stack

**Môi trường**: 1 host, 32GB RAM, VMware Workstation  
**Mục tiêu**: Lab mirror production — học vận hành và deploy via GitOps

---

## Mục lục

1. [Kiến trúc & Stack](#1-kiến-trúc--stack)
2. [Phase 1: VMware Networks](#2-phase-1-vmware-networks)
3. [Phase 2: Tạo VMs + Cài OS](#3-phase-2-tạo-vms--cài-os)
4. [Phase 3: Kubernetes Cluster](#4-phase-3-kubernetes-cluster)
5. [Phase 4: ArgoCD (GitOps Bootstrap)](#5-phase-4-argocd-gitops-bootstrap)
6. [Phase 5: Core Stack qua ArgoCD](#6-phase-5-core-stack-qua-argocd)
7. [Phase 6: Network Layer (Ingress + TLS)](#7-phase-6-network-layer-ingress--tls)
8. [Phase 7: Storage Extensions (RGW + Mirror)](#8-phase-7-storage-extensions-rgw--mirror)
9. [Phase 8: VM Platform (KubeVirt)](#9-phase-8-vm-platform-kubevirt)
10. [Phase 9: Optional (Multus CNI)](#10-phase-9-optional-multus-cni)
11. [Verification Checklist](#11-verification-checklist)
12. [Lab Exercises](#12-lab-exercises)
13. [Troubleshooting & Ghi chú](#13-troubleshooting--ghi-chú)

---

## 1. Kiến trúc & Stack

### Sơ đồ hạ tầng

```
┌─────────────────────────────────────────────────────────────┐
│  Host Machine (32GB RAM, VMware Workstation)                │
│                                                             │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────── │
│  │ k8s-node-01      │  │ k8s-node-02      │  │ k8s-node-03 │
│  │ Control + Worker │  │ Worker           │  │ Worker      │
│  │ 8GB RAM, 4 vCPU  │  │ 8GB RAM, 4 vCPU  │  │ 8GB, 4vCPU │
│  │                  │  │                  │  │            │
│  │ /dev/sda  50GB OS│  │ /dev/sda  50GB OS│  │ /dev/sda   │
│  │ /dev/sdb  20GB ──┼──┼─────────────────SSD pool (Ceph)  │
│  │ /dev/sdc  50GB ──┼──┼─────────────────HDD pool (Ceph)  │
│  └──────────────────┘  └──────────────────┘  └────────────┘
│         │                     │                    │
│  ───────┴──── VMnet8 (NAT 192.168.100.0/24) ───────┘
│  ───────┴──── VMnet2 (K8s 10.10.10.0/24) ──────────
│  ───────┴──── VMnet3 (Ceph 10.20.20.0/24) ─────────
└─────────────────────────────────────────────────────────────┘
```

### Node layout

| VM | RAM | CPU | IP Management | IP K8s | IP Ceph |
|----|-----|-----|---------------|--------|---------|
| k8s-node-01 | 8GB | 4 | 192.168.100.11 | 10.10.10.11 | 10.20.20.11 |
| k8s-node-02 | 8GB | 4 | 192.168.100.12 | 10.10.10.12 | 10.20.20.12 |
| k8s-node-03 | 8GB | 4 | 192.168.100.13 | 10.10.10.13 | 10.20.20.13 |

### Stack components

| Layer | Component | Version | Quản lý bởi |
|-------|-----------|---------|-------------|
| K8s | kubeadm | v1.31 | Script (one-time) |
| CNI | Cilium | v1.16.4 | Script (one-time) |
| LoadBalancer | MetalLB | v0.14.8 | Script (one-time) → ArgoCD |
| Storage | Rook-Ceph | v1.16.x | ArgoCD |
| Monitoring | kube-prometheus-stack | latest | ArgoCD |
| Logging | Loki + Grafana Alloy | latest | ArgoCD |
| Ingress | ingress-nginx | latest | ArgoCD |
| TLS | cert-manager | latest | ArgoCD |
| S3 | Ceph RGW | via Rook | ArgoCD |
| GitOps | ArgoCD | latest | Script (one-time) |
| VMs | KubeVirt + CDI | latest | ArgoCD |
| VM UI | KubeVirt Manager | v1.5.2 | ArgoCD |

### So sánh với of1-cloud (production)

| Thành phần | of1-cloud | Stack lab này | Lý do lựa chọn |
|---|---|---|---|
| Ingress | RKE2 built-in | Helm ingress-nginx | GitOps-managed, explicit versioning |
| Cert-Manager | HTTP01 only | Self-signed CA + LE option | Lab internal + prod ready |
| Ceph RGW | Multi-realm/zone | Single CephObjectStore | Đủ cho single-cluster |
| KubeVirt | Operator + CDI | + KubeVirt Manager UI | Web UI quản lý VM |
| GitOps | Không có | ArgoCD App-of-Apps | Reproducible infra |
| Monitoring | Prometheus cơ bản | kube-prometheus + Loki + Alloy | Full observability |
| `osd_pool_default_size` | **1** (nguy hiểm!) | **3** (mặc định an toàn) | Đủ redundancy |

---

## 2. Phase 1: VMware Networks

### Mở Virtual Network Editor

**VMware Workstation → Edit → Virtual Network Editor → Change Settings**

Tạo 3 virtual networks:

**VMnet2** (Host-only):
- Subnet IP: `10.10.10.0`
- Subnet mask: `255.255.255.0`
- Tắt DHCP

**VMnet3** (Host-only):
- Subnet IP: `10.20.20.0`
- Subnet mask: `255.255.255.0`
- Tắt DHCP (Ceph dedicated network)

**VMnet8** (NAT) — giữ nguyên mặc định:
- Subnet: `192.168.100.0/24`
- MetalLB dùng range: `192.168.100.200 – 192.168.100.220`

---

## 3. Phase 2: Tạo VMs + Cài OS

### Bước 2.1 — Tạo VM đầu tiên (k8s-node-01)

**VMware → File → New Virtual Machine → Custom:**

```
Guest OS:    Linux → Debian 12 (64-bit)
Name:        k8s-node-01
vCPU:        4
RAM:         8192 MB
Disk 1 (OS): 50GB, thin provisioned, SCSI → /dev/sda
Disk 2:      20GB, thin provisioned, SCSI → /dev/sdb  (Ceph SSD pool)
Disk 3:      50GB, thin provisioned, SCSI → /dev/sdc  (Ceph HDD pool)
NIC 1:       VMnet8 (NAT)
NIC 2:       VMnet2 (Host-only)
NIC 3:       VMnet3 (Host-only)
```

> **Quan trọng — Nested Virtualization** (cần cho KubeVirt):  
> VM Settings → Processors → tick **"Virtualize Intel VT-x/EPT or AMD-V/RVI"**

### Bước 2.2 — Cài Debian 12

Download: `https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/` (netinstall)

Khi cài:
- Hostname: `k8s-node-01`
- Partition: chỉ `/dev/sda` (OS disk) — **bỏ qua sdb, sdc**
- Software: chỉ chọn **SSH server** + **standard system utilities** (không desktop)

### Bước 2.3 — Cấu hình network (k8s-node-01)

```bash
# Xem tên interface
ip link show
# Thường: ens33 (VMnet8), ens36 (VMnet2), ens38 (VMnet3)

cat > /etc/network/interfaces << 'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# NIC1 — Management/Internet (VMnet8)
auto ens33
iface ens33 inet static
    address 192.168.100.11
    netmask 255.255.255.0
    gateway 192.168.100.2
    dns-nameservers 8.8.8.8

# NIC2 — K8s Internal (VMnet2)
auto ens36
iface ens36 inet static
    address 10.10.10.11
    netmask 255.255.255.0

# NIC3 — Ceph Storage Network (VMnet3)
auto ens38
iface ens38 inet static
    address 10.20.20.11
    netmask 255.255.255.0
EOF

systemctl restart networking
```

### Bước 2.4 — Clone VM (tạo node-02, node-03)

1. Shutdown k8s-node-01
2. Right-click → **Clone → Full Clone** → đặt tên `k8s-node-02`
3. Làm lại → `k8s-node-03`

Sau khi clone, đổi hostname và IP trên từng VM:

```bash
# Trên k8s-node-02
hostnamectl set-hostname k8s-node-02
# Sửa /etc/network/interfaces: ens33=192.168.100.12, ens36=10.10.10.12, ens38=10.20.20.12
systemctl restart networking

# Trên k8s-node-03
hostnamectl set-hostname k8s-node-03
# Sửa /etc/network/interfaces: ens33=192.168.100.13, ens36=10.10.10.13, ens38=10.20.20.13
systemctl restart networking
```

### Bước 2.5 — Xóa disk signatures sau clone

```bash
# Trên TẤT CẢ 3 nodes — Ceph cần disks hoàn toàn trống
wipefs -a /dev/sdb
wipefs -a /dev/sdc
dd if=/dev/zero of=/dev/sdb bs=1M count=100
dd if=/dev/zero of=/dev/sdc bs=1M count=100
```

---

## 4. Phase 3: Kubernetes Cluster

Dùng scripts có sẵn trong `infrastructure/script-install/`. Copy folder lên từng node:

```bash
# Trên Windows/host, copy scripts lên master
scp -r infrastructure/script-install/ root@192.168.100.11:/root/k8s-install/
```

### Bước 3.1 — Cấu hình (đọc trước khi chạy)

```bash
# Trên k8s-node-01
cat /root/k8s-install/config.env
# Kiểm tra IPs và versions phù hợp với môi trường
```

### Bước 3.2 — Prepare ALL nodes (chạy song song trên cả 3)

```bash
# Trên TẤT CẢ 3 nodes đồng thời
cd /root/k8s-install
bash 01-prepare.sh
```

Script này cài: containerd, kubeadm, kubelet, kubectl, kernel modules, sysctl params.

### Bước 3.3 — Init master (chỉ trên k8s-node-01)

```bash
cd /root/k8s-install
bash 02-master.sh
```

Script này:
- `kubeadm init` với Cilium (skip kube-proxy)
- Cài Cilium CNI
- Cài MetalLB + cấu hình IP pool (192.168.100.200-220)
- Tạo `/tmp/k8s-join.sh`

```bash
# Sau khi xong, kiểm tra
kubectl get nodes
# k8s-node-01   Ready   control-plane   ...

kubectl get pods -n kube-system
kubectl get pods -n cilium-system   # hoặc -n kube-system tùy version Cilium
```

### Bước 3.4 — Join workers

```bash
# Copy join script từ master sang từng worker
scp root@192.168.100.11:/tmp/k8s-join.sh /tmp/k8s-join.sh

# Trên k8s-node-02 và k8s-node-03
cd /root/k8s-install
bash 03-worker.sh
```

### Bước 3.5 — Verify cluster

```bash
# Trên k8s-node-01
bash 04-verify.sh

# Hoặc thủ công:
kubectl get nodes -o wide
# Expected: 3 nodes, all Ready

cilium status
# Expected: Cilium OK

kubectl get svc -A | grep LoadBalancer
# MetalLB sẽ cấp IP cho services type LoadBalancer
```

> **Nested virtualization verify** (trước khi dùng KubeVirt sau này):
> ```bash
> egrep -c '(vmx|svm)' /proc/cpuinfo   # Phải > 0 trên mỗi node
> ```

---

## 5. Phase 4: ArgoCD (GitOps Bootstrap)

### Bước 4.1 — Clone repo về master

```bash
# Trên k8s-node-01
git clone https://github.com/dz1194/DevOps-project.git
cd DevOps-project
```

### Bước 4.2 — Cài ArgoCD

```bash
bash bootstrap/install-argocd.sh
```

Script này tự động:
- Detect ArgoCD version mới nhất từ GitHub API
- Apply với Kustomize inline patch (type: LoadBalancer cho argocd-server)
- Dùng `--server-side` để tránh lỗi CRD annotation too large
- Chờ ArgoCD pods ready

```bash
# Lấy ArgoCD External IP
kubectl get svc argocd-server -n argocd
# EXTERNAL-IP: 192.168.100.20x

# Lấy admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Truy cập: https://192.168.100.20x
# Login: admin / <password trên>
```

### Bước 4.3 — Tạo secret cho Grafana

```bash
# Tạo trước khi bootstrap — ArgoCD cần secret này tồn tại
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin-secret \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=Admin@2024
```

### Bước 4.4 — Bootstrap App-of-Apps (1 lần duy nhất)

```bash
kubectl apply -f bootstrap/app-of-apps.yaml
```

ArgoCD bây giờ quản lý toàn bộ `gitops/` directory. Bất cứ file `.yaml` nào trong `gitops/` sẽ được tự động deploy.

```bash
# Theo dõi ArgoCD sync
kubectl get applications -n argocd -w

# Hoặc dùng Web UI: https://192.168.100.20x
```

---

## 6. Phase 5: Core Stack qua ArgoCD

Sau khi App-of-Apps được apply, ArgoCD tự deploy tất cả Applications trong `gitops/`.  
Theo dõi tiến trình:

```bash
watch kubectl get applications -n argocd
```

### 6.1 MetalLB Config (gitops/metallb-config.yaml)

MetalLB controller đã được cài trong bước 3.3. ArgoCD chỉ deploy config (IPAddressPool + L2Advertisement).

```bash
# Verify
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

### 6.2 Rook-Ceph (gitops/rook-ceph-operator.yaml + rook-ceph-cluster.yaml)

Đây là bước lâu nhất (~10-15 phút). ArgoCD deploy:
1. Rook operator (CRDs + operator pod)
2. CephCluster CR → Rook tạo MONs, OSDs, MGR

```bash
# Theo dõi Ceph pods
watch kubectl get pods -n rook-ceph

# Khi tất cả Running, kiểm tra sức khỏe
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
# Expected: HEALTH_OK, 6 OSDs (2×3 nodes), 3 MONs

# Xem OSDs
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Lấy Ceph Dashboard password
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Dashboard External IP
kubectl get svc rook-ceph-mgr-dashboard-lb -n rook-ceph
# Truy cập: http://<IP> (admin / <password>)
```

### 6.3 Monitoring (gitops/monitoring.yaml)

kube-prometheus-stack + Grafana (2 replicas, CephFS RWX storage).

```bash
# Chờ Ceph HEALTH_OK trước — Grafana cần Ceph storage
kubectl get pods -n monitoring -w

# Sau khi healthy, lấy Grafana External IP
kubectl get svc -n monitoring kube-prometheus-stack-grafana
# Truy cập: http://<IP> (admin / Admin@2024)
```

**Dashboards tự động được load** — không cần import tay:

| Folder | Dashboard | Nguồn |
|--------|-----------|-------|
| Kubernetes | K8s Cluster, Nodes, Pods, Namespaces, PVs, Networking | `defaultDashboardsEnabled` (mixin bundled) |
| Kubernetes | Node Exporter summary | `defaultDashboardsEnabled` |
| Ceph | Ceph Cluster (ID 2842) | Download từ grafana.com |
| Ceph | Ceph OSD (ID 5336) | Download từ grafana.com |
| Ceph | Ceph Pools (ID 5342) | Download từ grafana.com |
| Logging | Loki Logs (ID 13639) | Download từ grafana.com |
| GitOps | ArgoCD (ID 14584) | Download từ grafana.com |

**Cách hoạt động (3 cơ chế song song):**

```
1. defaultDashboardsEnabled: true
   → Helm chart tạo ConfigMaps chứa dashboard JSON (kubernetes-mixin, node-exporter-mixin)
   → Grafana sidecar detect label grafana_dashboard: "1" → mount vào /var/lib/grafana/dashboards/

2. grafana.dashboards (values.yaml)
   → Grafana init container download JSON từ grafana.com theo gnetId
   → Lưu vào /var/lib/grafana/dashboards/<folder>/

3. Custom ConfigMap (bất kỳ namespace nào)
   → Tạo ConfigMap với label grafana_dashboard: "1"
   → Sidecar searchNamespace: ALL → phát hiện và mount tự động
   → Dùng cho dashboards nội bộ không có trên grafana.com
```

### 6.4 Logging (gitops/loki.yaml + gitops/alloy.yaml)

Loki: log storage. Grafana Alloy: DaemonSet thu thập logs từ tất cả pods.

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy

# Verify trong Grafana: Explore → Loki → {namespace="monitoring"} → xem logs
```

---

## 7. Phase 6: Network Layer (Ingress + TLS)

### Bước 6.1 — Push Ingress NGINX Application

Files đã có trong repo. Chỉ cần push (hoặc nếu đã push, ArgoCD tự sync):

```bash
# Kiểm tra Application đã sync chưa
kubectl get application ingress-nginx -n argocd

# Verify
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP: 192.168.100.2xx (từ MetalLB)
```

Từ giờ, expose services qua domain thay vì IP riêng lẻ → tiết kiệm MetalLB IP pool.

### Bước 6.2 — Cert-Manager

```bash
# Kiểm tra
kubectl get application cert-manager -n argocd
kubectl get pods -n cert-manager

# Verify ClusterIssuers đã tạo
kubectl get clusterissuer
# Expected:
# selfsigned-cluster-issuer   True
# ca-cluster-issuer           True
```

**Export CA cert để import vào browser** (cho HTTPS nội bộ):

```bash
kubectl get secret internal-ca-root-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > internal-ca.crt

# Import internal-ca.crt vào browser/OS:
# Chrome: Settings → Privacy → Manage Certificates → Authorities → Import
# Ubuntu: sudo cp internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```

### Bước 6.3 — Expose services qua Ingress

Sau khi có Ingress + Cert-Manager, expose bất kỳ service nào qua domain:

```yaml
# Ví dụ: expose ArgoCD UI
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: "ca-cluster-issuer"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.lab.local
      secretName: argocd-tls
  rules:
    - host: argocd.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

Thêm vào `/etc/hosts` (hoặc DNS server nội bộ):
```
192.168.100.200   argocd.lab.local grafana.lab.local ceph.lab.local
```

### Kích hoạt Let's Encrypt (khi có public domain + IP)

```bash
# Edit infrastructure/cert-manager/manifests/cluster-issuer.yaml
# Uncomment section Let's Encrypt PRODUCTION
# Thay email

# Edit infrastructure/cert-manager/values.yaml
# Đổi defaultIssuerName: "letsencrypt-prod"

git add infrastructure/cert-manager/
git commit -m "feat: enable letsencrypt issuer"
git push
# ArgoCD tự sync
```

---

## 8. Phase 7: Storage Extensions (RGW + Mirror)

### 8.1 Ceph RGW (S3 Object Storage)

File đã có: `infrastructure/rook-ceph/cluster/object-store.yaml`

ArgoCD sẽ deploy tự động khi Rook-Ceph Application sync (file nằm trong path của rook-ceph-cluster Application).

```bash
# Kiểm tra RGW pod
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# Lấy External IP của S3 endpoint (LoadBalancer)
kubectl get svc -n rook-ceph rook-ceph-rgw-object-store-lb

# Lấy S3 credentials
S3_IP=$(kubectl get svc -n rook-ceph rook-ceph-rgw-object-store-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ACCESS_KEY=$(kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin \
  -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin \
  -o jsonpath='{.data.SecretKey}' | base64 -d)

echo "S3 Endpoint: http://$S3_IP"
echo "Access Key:  $ACCESS_KEY"
echo "Secret Key:  $SECRET_KEY"
```

**Test S3 API:**
```bash
# pip install awscli
aws s3 mb s3://test-bucket \
  --endpoint-url http://$S3_IP \
  --access-key $ACCESS_KEY \
  --secret-key $SECRET_KEY

aws s3 ls \
  --endpoint-url http://$S3_IP \
  --access-key $ACCESS_KEY \
  --secret-key $SECRET_KEY
```

**App tạo bucket tự động qua Object Bucket Claim:**
```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-app-bucket
  namespace: my-namespace
spec:
  storageClassName: rook-ceph-bucket
  generateBucketName: my-app
# Rook tạo Secret + ConfigMap với endpoint, access key, secret key
```

### 8.2 RBD Mirroring (DR — cần 2 cluster)

> Bỏ qua nếu chỉ có 1 cluster. Cần thiết khi setup HN ↔ HP DR.

**Bước 1: Deploy RBD Mirror daemon (cả 2 cluster)**

File `infrastructure/rook-ceph/cluster/rbd-mirror.yaml` đã tạo và ArgoCD tự deploy.

```bash
kubectl get pods -n rook-ceph -l app=rook-ceph-rbd-mirror
```

**Bước 2: Enable mirroring trên pool**

Sửa `infrastructure/rook-ceph/cluster/ceph-blockpool.yaml`, thêm:
```yaml
spec:
  mirroring:
    enabled: true
    mode: image
    snapshotSchedules:
      - interval: "24h"
        startTime: "02:00:00-00:00"
```

**Bước 3: Bootstrap peer giữa 2 cluster**

```bash
# Trên cluster HN — lấy token
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool peer bootstrap create \
  --site-name hn-cluster replicapool
# Output: base64 token

# Trên cluster HP — import token
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool peer bootstrap import \
  --site-name hp-cluster \
  --token <TOKEN_TỪ_HN> \
  replicapool

# Verify mirror status
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool status replicapool
# Expected: summary: health: OK
```

**Bước 4: Enable mirroring cho image cụ thể**

```bash
# Enable image-level mirroring
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror image enable replicapool/<image-name> snapshot

# Theo dõi sync
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror image status replicapool/<image-name>
```

---

## 9. Phase 8: VM Platform (KubeVirt)

### 9.1 Kiểm tra version KubeVirt mới nhất

```bash
# Kiểm tra trước khi deploy
curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
  | grep '"tag_name"' | cut -d'"' -f4

# Nếu khác v1.4.0, cập nhật infrastructure/kubevirt/kustomization.yaml
# Tương tự cho CDI: https://github.com/kubevirt/containerized-data-importer/releases
```

### 9.2 Deploy KubeVirt + CDI + Manager

Files đã có, ArgoCD deploy từ `gitops/kubevirt.yaml`, `gitops/cdi.yaml`, `gitops/kubevirt-manager.yaml`.

```bash
# Theo dõi KubeVirt (mất 3-5 phút)
kubectl get pods -n kubevirt -w

# Verify KubeVirt ready
kubectl get kubevirt kubevirt -n kubevirt
# PHASE: Deployed, STATUS: True

# CDI
kubectl get cdi cdi -n cdi

# Cài virtctl (công cụ quản lý VM)
KUBEVIRT_VERSION=$(kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.observedKubeVirtVersion}')
curl -L -o /usr/local/bin/virtctl \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
chmod +x /usr/local/bin/virtctl
```

### 9.3 KubeVirt Manager Web UI

```bash
# Lấy External IP
kubectl get svc -n kubevirt-manager kubevirt-manager-lb
# Truy cập: http://<IP>
```

### 9.4 Tạo VM đầu tiên (test)

**Cách 1: Container Disk (nhanh, không cần CDI)**

```bash
cat > test-vm.yaml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: debian-test
  namespace: default
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: debian-test
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
            cpu: 1
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/debian:12
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: testpass
              chpasswd:
                expire: false
              ssh_pwauth: true
EOF

kubectl apply -f test-vm.yaml
virtctl start debian-test
virtctl console debian-test
# Login: debian / testpass
```

**Cách 2: Import disk từ URL (dùng CDI)**

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ubuntu-disk
  namespace: default
spec:
  source:
    http:
      url: https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
    storageClassName: rook-ceph-block
```

### 9.5 VM với Ceph persistent storage

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: prod-vm
  namespace: default
spec:
  running: false
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
        resources:
          requests:
            memory: 4Gi
            cpu: 2
      volumes:
        - name: rootdisk
          dataVolume:
            name: ubuntu-disk   # DataVolume đã tạo ở trên
```

---

## 10. Phase 9: Optional — Multus CNI

**Khi nào cần**: VM cần kết nối trực tiếp vào physical network qua VLAN (như of1-cloud).  
**Bỏ qua** nếu VMs chỉ cần kết nối K8s cluster network.

```bash
# Apply Multus thick daemonset
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

# Verify
kubectl get pods -n kube-system -l app=multus

# Tạo NetworkAttachmentDefinition cho VLAN
cat <<EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan100
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "ens33",
      "mode": "bridge",
      "ipam": { "type": "dhcp" }
    }
EOF
```

**Sử dụng trong VM:**
```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: vlan100
```

---

## 11. Verification Checklist

Chạy sau khi hoàn thành toàn bộ setup:

```bash
# === K8s Cluster ===
kubectl get nodes -o wide
# Expected: 3 nodes, all STATUS=Ready

# === Cilium CNI ===
cilium status
# Expected: Cilium: OK, KubeProxyReplacement: True

# === MetalLB ===
kubectl get ipaddresspools -n metallb-system
kubectl get svc -A | grep LoadBalancer

# === Ceph Health ===
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
# Expected: HEALTH_OK, 6 OSDs

# === Storage Classes ===
kubectl get storageclass
# Expected: rook-ceph-block, rook-cephfs, rook-ceph-bucket

# === ArgoCD Applications ===
kubectl get applications -n argocd
# Expected: tất cả Synced + Healthy

# === Monitoring ===
kubectl get pods -n monitoring
kubectl get svc -n monitoring kube-prometheus-stack-grafana

# === Logging ===
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy

# === Ingress NGINX ===
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller

# === Cert-Manager ===
kubectl get pods -n cert-manager
kubectl get clusterissuer

# === Ceph RGW ===
kubectl get cephobjectstore -n rook-ceph
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# === KubeVirt ===
kubectl get kubevirt -n kubevirt
kubectl get pods -n kubevirt

# === CDI ===
kubectl get cdi -n cdi

# === KubeVirt Manager ===
kubectl get svc -n kubevirt-manager kubevirt-manager-lb
```

### Dashboard Access Summary

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD | https://192.168.100.20x | admin / (từ secret) |
| Grafana | http://192.168.100.2xx | admin / Admin@2024 |
| Ceph Dashboard | http://192.168.100.2xx | admin / (từ secret) |
| KubeVirt Manager | http://192.168.100.2xx | (không auth mặc định) |
| S3 (RGW) | http://192.168.100.2xx | (access/secret key) |

```bash
# Script lấy tất cả External IPs
echo "=== External IPs ==="
echo "ArgoCD:          $(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Grafana:         $(kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Ceph Dashboard:  $(kubectl get svc rook-ceph-mgr-dashboard-lb -n rook-ceph -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "KubeVirt Mgr:    $(kubectl get svc kubevirt-manager-lb -n kubevirt-manager -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "S3 RGW:          $(kubectl get svc rook-ceph-rgw-object-store-lb -n rook-ceph -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo ""
echo "=== Credentials ==="
echo "ArgoCD admin pw: $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)"
echo "Ceph Dashboard:  $(kubectl get secret rook-ceph-dashboard-password -n rook-ceph -o jsonpath='{.data.password}' | base64 -d)"
```

---

## 12. Lab Exercises

### Exercise 1: Ceph Basic Operations

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

# Đọc hiểu cluster
ceph status
ceph osd tree
ceph df

# Tạo pool thủ công
ceph osd pool create test-pool 32
ceph osd pool set test-pool size 3
ceph df

# Tạo RBD image
rbd create test-pool/test-image --size 1G
rbd info test-pool/test-image
rbd ls test-pool

# Dọn dẹp
rbd rm test-pool/test-image
ceph osd pool rm test-pool test-pool --yes-i-really-really-mean-it
```

### Exercise 2: OSD Failure Simulation

```bash
# 1. Trạng thái ban đầu
ceph status   # HEALTH_OK

# 2. Tắt 1 OSD
kubectl -n rook-ceph scale deployment rook-ceph-osd-0 --replicas=0

# 3. Theo dõi Ceph tự heal
watch kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
# Sẽ thấy: HEALTH_WARN, degraded PGs, recovery in progress

# 4. Bật lại
kubectl -n rook-ceph scale deployment rook-ceph-osd-0 --replicas=1

# 5. Theo dõi quay về HEALTH_OK
watch ceph status
```

### Exercise 3: PVC Snapshot & Restore

```bash
# 1. Tạo PVC và viết data
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: snap-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: snap-test-pod
spec:
  containers:
    - name: app
      image: busybox
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: snap-test-pvc
EOF

# 2. Viết data
kubectl exec snap-test-pod -- sh -c "echo 'test data' > /data/test.txt"

# 3. Tạo snapshot
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: snap-test
spec:
  volumeSnapshotClassName: csi-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: snap-test-pvc
EOF

# 4. Xóa data
kubectl exec snap-test-pod -- rm /data/test.txt

# 5. Restore từ snapshot
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: snap-restored-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: snap-test
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# 6. Verify data restored
kubectl exec snap-test-pod -- cat /data/test.txt   # Phải thấy "test data"
```

### Exercise 4: GitOps Workflow

```bash
# 1. Thay đổi Grafana replicas
# Edit: infrastructure/monitoring/values.yaml
# Đổi: replicas: 2 → replicas: 3

git add infrastructure/monitoring/values.yaml
git commit -m "test: scale grafana to 3 replicas"
git push

# 2. Theo dõi ArgoCD sync (~3 phút)
kubectl get application monitoring -n argocd -w

# 3. Verify
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

# 4. Rollback
git revert HEAD
git push
```

### Exercise 5: Deploy App với Ceph Storage

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install postgresql bitnami/postgresql \
  --namespace default \
  --set primary.persistence.storageClass=rook-ceph-block \
  --set primary.persistence.size=5Gi \
  --set auth.postgresPassword=postgres123

# Verify
kubectl get pvc | grep postgresql
kubectl get pods | grep postgresql
```

---

## 13. Troubleshooting & Ghi chú

### Quy trình cập nhật config (GitOps workflow)

```bash
# Mọi thay đổi đều theo flow này:
# 1. Edit file trong infrastructure/ hoặc gitops/
# 2. Commit + push
git add .
git commit -m "update: <mô tả>"
git push
# 3. ArgoCD tự sync trong ~3 phút
# 4. Theo dõi: kubectl get applications -n argocd
```

### Fix Grafana Multi-Attach Error

```bash
# Lỗi: Multi-Attach error for volume — already used by another pod
# Nguyên nhân: PVC RWO không thể mount bởi 2 pods

# Fix: scale down → xóa PVC → ArgoCD tạo PVC mới (RWX/CephFS)
kubectl scale deployment kube-prometheus-stack-grafana -n monitoring --replicas=0
kubectl delete pvc -n monitoring \
  $(kubectl get pvc -n monitoring --no-headers | grep grafana | awk '{print $1}')
kubectl annotate app monitoring -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl get pvc -n monitoring -w
```

### ArgoCD không sync sau khi push

```bash
# Force refresh
kubectl annotate app <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Hoặc từ Web UI: App → Refresh → Hard Refresh
```

### Ceph HEALTH_WARN — common fixes

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

# Xem chi tiết cảnh báo
ceph health detail

# PG không đủ replicas (degraded)
ceph pg stat      # xem trạng thái PGs

# OSD down
ceph osd stat
kubectl get pods -n rook-ceph | grep osd

# Disk gần đầy (>85%)
ceph df
# → Thêm disk mới hoặc xóa data
```

### Script không chạy được — CRLF error

```bash
# Lỗi: /usr/bin/env: 'bash\r': No such file or directory
# Fix: chuyển line ending từ CRLF sang LF
sed -i 's/\r//' <script>.sh
```

### Ghi chú quan trọng

**RAM tight**: 3×8GB = 24GB + Host 8GB = đúng 32GB. Không chạy nhiều VMs cùng lúc.

**Disk thin provision**: VMware thin → host chỉ dùng thực tế, không phải allocated size.

**Interface names**: Tên `ens33`, `ens36` có thể khác. Luôn kiểm tra `ip link show` trước.

**Ceph needs clean disks**: `/dev/sdb` và `/dev/sdc` PHẢI trống. Sau khi clone VM → luôn chạy wipefs.

**Secrets không commit vào Git**: Passwords, API keys → dùng `kubectl create secret`. Repo chỉ chứa config, không chứa credentials.

**osd_pool_default_size = 1 của of1-cloud**: KHÔNG sao chép cấu hình này. Stack mới dùng size=3 (mặc định an toàn, cần ít nhất 3 OSD/host cho failureDomain=host).

**Thứ tự install bắt buộc**:
```
VMs + OS → K8s init → Cilium → MetalLB → ArgoCD → App-of-Apps
         (scripts 01-04)                (bootstrap/)  (1 kubectl apply)

Sau đó ArgoCD quản lý:
Ceph → Monitoring → Logging → Ingress → Cert-Manager → KubeVirt → CDI
```

### Ước tính thời gian

| Phase | Thời gian |
|-------|-----------|
| VMware setup + VMs | 2-3 giờ |
| K8s cluster (scripts) | 30 phút |
| ArgoCD bootstrap | 15 phút |
| Ceph healthy | 15-20 phút |
| Monitoring + Logging | 10 phút |
| Ingress + Cert-Manager | 10 phút |
| KubeVirt + CDI | 10 phút |
| **Tổng** | **~5-6 giờ** |
