# Hướng dẫn cài đặt các thành phần còn thiếu

> So sánh với `of1-cloud-main` (production stack Beelogistics) và lựa chọn giải pháp tốt hơn

## Tổng quan so sánh

| Thành phần | of1-cloud (production) | Stack mới (khuyến nghị) | Lý do lựa chọn |
|---|---|---|---|
| **Ingress** | RKE2 built-in NGINX | Helm chart `ingress-nginx` | GitOps-managed, explicit version, dễ upgrade |
| **Cert-Manager** | Helm + HTTP01 only | Helm + Self-signed CA + LE option | Self-signed cho internal, LE khi cần public |
| **Ceph RGW** | Multi-realm/zone (multi-site) | Simple CephObjectStore | Multi-realm chỉ cần cho multi-cluster replication |
| **RBD Mirroring** | CephRBDMirror + manual peer | Giống of1-cloud | Proven approach |
| **KubeVirt** | Operator + CDI | + KubeVirt Manager UI | Web UI để quản lý VM trực quan |
| **Monitoring** | Prometheus cơ bản | kube-prometheus + Loki + Alloy | Full observability stack |
| **GitOps** | Không có | ArgoCD | Đã thêm |
| **Multus CNI** | Thick daemonset | Optional | Chỉ cần khi VM cần nhiều NIC |

## Trạng thái hiện tại — vấn đề cần fix ngay

### ⚠️ Fix Grafana Multi-Attach (làm TRƯỚC khi tiếp tục)

Lỗi: `Multi-Attach error for volume — Volume is already used by pod grafana-xxx`
Nguyên nhân: PVC `rook-ceph-block` (RWO) không thể mount bởi 2 pod cùng lúc.
Fix đã thực hiện: đổi sang `rook-cephfs` (RWX) trong `infrastructure/monitoring/values.yaml`.

Chạy lệnh sau để áp dụng:

```bash
# Scale down Grafana
kubectl scale deployment kube-prometheus-stack-grafana -n monitoring --replicas=0

# Xoá PVC cũ (RWO/rook-ceph-block)
kubectl delete pvc -n monitoring \
  $(kubectl get pvc -n monitoring --no-headers | grep grafana | awk '{print $1}')

# Force ArgoCD sync để tạo PVC mới (RWX/rook-cephfs)
kubectl annotate app monitoring -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Kiểm tra PVC mới được tạo
kubectl get pvc -n monitoring -w
```

---

## Phase 1: Network Infrastructure

### 1.1 Ingress NGINX

**Tại sao cần:** Expose services qua HTTP/HTTPS domain, thay vì dùng nhiều LoadBalancer IP riêng lẻ.

**Khác biệt với of1-cloud:** of1-cloud dùng RKE2 built-in NGINX (cài qua RKE2 config). Stack mới dùng Helm chart → GitOps-managed, explicit version control.

**Files đã tạo:**
- `gitops/ingress-nginx.yaml` — ArgoCD Application
- `infrastructure/ingress-nginx/values.yaml` — Helm values

**Apply:**
```bash
# Khi push lên GitHub, ArgoCD tự sync từ gitops/ingress-nginx.yaml
# Hoặc apply thủ công để test:
git add gitops/ingress-nginx.yaml infrastructure/ingress-nginx/
git commit -m "feat: add ingress-nginx"
git push
```

**Verify:**
```bash
# Kiểm tra ingress controller chạy
kubectl get pods -n ingress-nginx

# Lấy External IP (MetalLB cấp)
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Test: tạo Ingress đơn giản
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: test.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes
            port:
              number: 443
EOF
```

---

### 1.2 Cert-Manager

**Tại sao cần:** Tự động cấp và renew TLS certificates cho Ingress resources.

**Khác biệt với of1-cloud:** of1-cloud chỉ dùng Let's Encrypt HTTP01. Stack mới thêm:
- `selfsigned-cluster-issuer` — cho internal certs (không cần domain)
- `ca-cluster-issuer` — CA-signed internal certs (browser trust với 1 lần import)
- Let's Encrypt — commented, bật khi có public domain

**Files đã tạo:**
- `gitops/cert-manager.yaml` — ArgoCD Application
- `infrastructure/cert-manager/values.yaml` — Helm values
- `infrastructure/cert-manager/manifests/cluster-issuer.yaml` — ClusterIssuers

**⚠️ Quan trọng:** Cert-Manager CRDs phải được install trước ClusterIssuer.
ArgoCD xử lý điều này qua `SkipDryRunOnMissingResource=true` — sẽ retry cho đến khi CRDs sẵn sàng.

**Apply:**
```bash
git add gitops/cert-manager.yaml infrastructure/cert-manager/
git commit -m "feat: add cert-manager with internal CA issuer"
git push

# Sau khi ArgoCD sync, verify:
kubectl get clusterissuer
# Expected:
# ca-cluster-issuer       True   ...
# selfsigned-cluster-issuer  True  ...
```

**Sử dụng cert trong Ingress:**
```yaml
# Thêm vào Ingress resource
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "ca-cluster-issuer"
spec:
  tls:
    - hosts:
        - myapp.internal
      secretName: myapp-tls
  rules:
    - host: myapp.internal
      ...
```

**Kích hoạt Let's Encrypt (khi có public domain):**
```bash
# 1. Edit cluster-issuer.yaml, uncomment section Let's Encrypt
# 2. Thay your-email@beelogistics.com
# 3. Đổi defaultIssuerName trong values.yaml thành "letsencrypt-prod"
# 4. Push → ArgoCD sync
```

---

## Phase 2: Storage Extensions

### 2.1 Ceph RGW (S3 Object Storage)

**Tại sao cần:** S3-compatible API để lưu files, VM disk images, backups, logs archives.

**Khác biệt với of1-cloud:**
- of1-cloud: multi-realm/zone (`bee-vietnam-prod`, `bee-global`) cho cross-cluster replication
- Stack mới: single CephObjectStore — đơn giản hơn, đủ cho single-cluster hoặc khi chưa cần multi-site
- Khi cần multi-site: nâng cấp lên multi-realm (tham khảo of1-cloud)

**Files đã tạo:**
- `infrastructure/rook-ceph/cluster/object-store.yaml` — CephObjectStore + StorageClass + LB

**Apply:**
```bash
git add infrastructure/rook-ceph/cluster/object-store.yaml
git commit -m "feat: add ceph RGW object store"
git push

# Kiểm tra RGW pod
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# Lấy External IP của S3 endpoint
kubectl get svc -n rook-ceph rook-ceph-rgw-object-store-lb

# Lấy credentials của s3-admin user
kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin -o jsonpath='{.data.AccessKey}' | base64 -d
kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin -o jsonpath='{.data.SecretKey}' | base64 -d
```

**Test S3 API:**
```bash
# Cài awscli nếu chưa có
# pip install awscli

S3_IP=$(kubectl get svc -n rook-ceph rook-ceph-rgw-object-store-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ACCESS_KEY=$(kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret -n rook-ceph rook-ceph-object-user-object-store-s3-admin -o jsonpath='{.data.SecretKey}' | base64 -d)

aws s3 ls --endpoint-url http://$S3_IP \
  --no-verify-ssl \
  --access-key $ACCESS_KEY \
  --secret-key $SECRET_KEY
```

**Object Bucket Claim (cách app tạo bucket tự động):**
```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-app-bucket
  namespace: my-app
spec:
  storageClassName: rook-ceph-bucket
  generateBucketName: my-app
```

---

### 2.2 RBD Mirroring (Disaster Recovery)

**Tại sao cần:** Đồng bộ RBD volumes từ cluster HN sang HP (hoặc ngược lại) để DR.

**File đã tạo:**
- `infrastructure/rook-ceph/cluster/rbd-mirror.yaml` — CephRBDMirror daemon

**Quy trình thiết lập (phải làm ở CẢ 2 cluster):**

**Bước 1: Apply CephRBDMirror ở cả hai cluster**
```bash
# Trên HN cluster
git add infrastructure/rook-ceph/cluster/rbd-mirror.yaml
git commit -m "feat: add rbd mirror daemon"
git push
# (ArgoCD sync)

# Trên HP cluster — cũng apply rbd-mirror.yaml
```

**Bước 2: Enable mirroring cho pool cần sync**
```bash
# Edit infrastructure/rook-ceph/cluster/ceph-blockpool.yaml
# Thêm section mirroring (xem comment trong rbd-mirror.yaml)
git add infrastructure/rook-ceph/cluster/ceph-blockpool.yaml
git commit -m "feat: enable rbd mirroring on replicapool"
git push
```

**Bước 3: Bootstrap peer giữa 2 cluster**
```bash
# Trên HN cluster — lấy bootstrap token
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool peer bootstrap create \
  --site-name hn-cluster replicapool

# Output sẽ là một base64 token
# Copy token sang HP cluster

# Trên HP cluster — import token
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool peer bootstrap import \
  --site-name hp-cluster \
  --token <TOKEN_TỪ_HN> \
  replicapool

# Verify mirror status
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror pool status replicapool
```

**Bước 4: Enable mirroring cho specific image**
```bash
# Enable mirroring cho một PVC/image cụ thể
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror image enable replicapool/<image-name> snapshot

# Kiểm tra sync status
kubectl exec -it deploy/rook-ceph-tools -n rook-ceph -- \
  rbd mirror image status replicapool/<image-name>
```

---

## Phase 3: VM Platform

### 3.1 KubeVirt

**Tại sao cần:** Chạy VMs trên Kubernetes, tận dụng infrastructure K8s cho VMs (networking, storage, scheduling).

**Files đã tạo:**
- `gitops/kubevirt.yaml` — ArgoCD Application (prune: false để không xoá VMs)
- `infrastructure/kubevirt/kustomization.yaml` — tải operator từ GitHub release
- `infrastructure/kubevirt/kubevirt-cr.yaml` — KubeVirt config với LiveMigration

**⚠️ Kiểm tra version trước khi apply:**
```bash
# Lấy KubeVirt version mới nhất
curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
  | grep '"tag_name"' | cut -d'"' -f4

# Cập nhật version trong infrastructure/kubevirt/kustomization.yaml
```

**Apply:**
```bash
git add gitops/kubevirt.yaml infrastructure/kubevirt/
git commit -m "feat: add kubevirt"
git push

# Kiểm tra KubeVirt pods (mất vài phút)
kubectl get pods -n kubevirt -w

# Verify KubeVirt ready
kubectl get kubevirt kubevirt -n kubevirt
```

---

### 3.2 CDI (Containerized Data Importer)

**Tại sao cần:** Import VM disk images từ HTTP URLs hoặc S3 vào PVC. Không có CDI, không thể tạo VM từ ISO/QCOW2 images.

**Files đã tạo:**
- `gitops/cdi.yaml` — ArgoCD Application
- `infrastructure/cdi/kustomization.yaml`
- `infrastructure/cdi/cdi-cr.yaml` — với HonorWaitForFirstConsumer feature gate

**⚠️ CDI phải cài SAU KubeVirt:**
```bash
# Chờ KubeVirt healthy trước
kubectl wait kubevirt kubevirt -n kubevirt \
  --for=condition=Available --timeout=300s

git add gitops/cdi.yaml infrastructure/cdi/
git commit -m "feat: add CDI for VM disk import"
git push

# Verify
kubectl get cdi cdi -n cdi
```

**Ví dụ: Import VM disk từ URL:**
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

---

### 3.3 KubeVirt Manager (Web UI)

**Tại sao cần:** Web UI để tạo/quản lý VMs mà không cần dùng kubectl. Giống vSphere/Proxmox Web UI.

**Files đã tạo:**
- `gitops/kubevirt-manager.yaml` — ArgoCD Application
- `infrastructure/kubevirt-manager/manager.yaml` — Deployment + LB Service (từ of1-cloud v1.5.2)

**Apply:**
```bash
git add gitops/kubevirt-manager.yaml infrastructure/kubevirt-manager/
git commit -m "feat: add kubevirt-manager web UI"
git push

# Lấy External IP để truy cập
kubectl get svc -n kubevirt-manager kubevirt-manager-lb
# Truy cập: http://<EXTERNAL-IP>
```

---

## Phase 4: Optional — Multus CNI

**Khi nào cần:** Chỉ cần khi VM cần nhiều network interfaces (ví dụ: VM vừa kết nối K8s cluster network vừa kết nối physical network qua VLAN).

**of1-cloud dùng:** Multus thick daemonset để VMs có thể kết nối trực tiếp vào physical network.

**Cài thủ công (không dùng Helm):**
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
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "dhcp"
      }
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

## Thứ tự cài đặt khuyến nghị

```
1. Fix Grafana Multi-Attach (ngay lập tức)
   ↓
2. Ingress NGINX (foundation cho expose services)
   ↓
3. Cert-Manager (TLS cho Ingress)
   ↓
4. Ceph RGW (S3 storage — nếu cần)
   ↓
5. RBD Mirroring (DR — nếu có 2 cluster)
   ↓
6. KubeVirt (cần cluster healthy)
   ↓
7. CDI (sau KubeVirt)
   ↓
8. KubeVirt Manager (sau CDI)
   ↓
9. Multus CNI (optional — chỉ khi cần VM multi-NIC)
```

---

## Expose services qua Ingress (sau khi có ingress-nginx + cert-manager)

Ví dụ: Expose ArgoCD UI qua domain thay vì LoadBalancer IP:

```yaml
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
        - argocd.internal
      secretName: argocd-tls
  rules:
    - host: argocd.internal
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

Thêm `argocd.internal` vào `/etc/hosts` hoặc DNS server:
```
192.168.x.x   argocd.internal
```

---

## Verification checklist sau khi cài

```bash
# Ingress NGINX
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Cert-Manager
kubectl get pods -n cert-manager
kubectl get clusterissuer

# Ceph RGW
kubectl get cephobjectstore -n rook-ceph
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# RBD Mirror
kubectl get cephrbdmirror -n rook-ceph
kubectl get pods -n rook-ceph -l app=rook-ceph-rbd-mirror

# KubeVirt
kubectl get kubevirt -n kubevirt
kubectl get pods -n kubevirt

# CDI
kubectl get cdi -n cdi
kubectl get pods -n cdi

# KubeVirt Manager
kubectl get pods -n kubevirt-manager
kubectl get svc -n kubevirt-manager kubevirt-manager-lb
```

---

## Ghi chú về của1-cloud critical issues

### ⚠️ osd_pool_default_size: "1" trong of1-cloud

File `of1-cloud/install/rook-ceph/k8s-config/prod-cluster/cluster.yaml` có:
```yaml
cephConfig:
  global:
    osd_pool_default_size: "1"  # NGUY HIỂM: không có redundancy
    mon_warn_on_pool_no_redundancy: "false"  # Tắt cảnh báo
```

Stack mới **KHÔNG** có cấu hình này — mặc định Ceph dùng `osd_pool_default_size: 3` (3 replicas).
Không sao chép cấu hình này sang cluster mới.

### Tại sao of1-cloud dùng size=1?
Likely là để test/dev trên cụm nhỏ hoặc tiết kiệm disk space. Trong production với hardware đầy đủ, PHẢI dùng size=3.
