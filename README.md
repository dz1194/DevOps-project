# DevOps Project — GitOps with ArgoCD

Kubernetes infrastructure managed via GitOps (ArgoCD App-of-Apps pattern).

## Stack

| Component | Tool | Managed by |
|---|---|---|
| K8s Cluster | kubeadm v1.31 | Script (one-time) |
| CNI | Cilium v1.16.4 | Script (one-time) |
| LoadBalancer | MetalLB v0.14.8 | ArgoCD |
| Storage | Rook-Ceph v1.16.4 | ArgoCD |
| Monitoring | kube-prometheus-stack | ArgoCD |
| Virtualization | KubeVirt | ArgoCD |

## Repository Structure

```
.
├── bootstrap/               # Run ONCE manually
│   ├── install-argocd.sh    # Step 1: Install ArgoCD
│   └── app-of-apps.yaml     # Step 2: Bootstrap root Application
│
├── gitops/                  # ArgoCD Application CRs (App-of-Apps)
│   ├── metallb-config.yaml
│   ├── rook-ceph-operator.yaml
│   ├── rook-ceph-cluster.yaml
│   └── monitoring.yaml
│
├── infrastructure/          # Actual manifests / Helm values
│   ├── metallb/             # IP pools, L2 advertisement
│   ├── rook-ceph/
│   │   └── cluster/         # CephCluster, StorageClass, etc.
│   └── monitoring/          # Helm values for kube-prometheus-stack
│
└── apps/                    # Application workloads
    ├── production/
    └── staging/
```

## Getting Started

### Prerequisites
- K8s cluster running (scripts 01-04 done)
- Rook-Ceph running (script 07 done)
- `kubectl` access from master node

### Step 1 — Install ArgoCD

```bash
bash bootstrap/install-argocd.sh
```

### Step 2 — Create Grafana admin secret

```bash
kubectl create secret generic grafana-admin-secret \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=YOUR_PASSWORD
```

### Step 3 — Bootstrap App-of-Apps

```bash
kubectl apply -f bootstrap/app-of-apps.yaml
```

ArgoCD sẽ tự động sync toàn bộ infrastructure từ repo này.

## Workflow hàng ngày

```bash
# Thay đổi bất kỳ config nào
git add . && git commit -m "update: ..."
git push
# ArgoCD tự detect và sync trong ~3 phút
```

## Lưu ý quan trọng

- `rook-ceph-cluster`: `prune: false` — KHÔNG bao giờ tự động xóa CephCluster
- Secrets (passwords) KHÔNG commit vào Git — dùng `kubectl create secret` thủ công
- Trước khi xóa bất kỳ file trong `infrastructure/rook-ceph/cluster/`, phải hiểu rõ tác động
