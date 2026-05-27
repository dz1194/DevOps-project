#!/usr/bin/env bash
# ============================================================
# 07-rook-ceph.sh — Cài Rook-Ceph trên MASTER
# Yêu cầu:
#   - K8s cluster đã chạy (01-04 xong)
#   - Mỗi node có ít nhất 1 disk trống (không partition)
#   - /dev/sdb (50GB) và /dev/nvme0n1 (20GB) chưa được format
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════${NC}"; }

[[ $EUID -ne 0 ]] && error "Phải chạy với quyền root: sudo bash $0"
export KUBECONFIG=/root/.kube/config

ROOK_VERSION="${ROOK_VERSION:-v1.16.4}"
CEPH_IMAGE="${CEPH_IMAGE:-quay.io/ceph/ceph:v19.2.0}"
ROOK_NS="rook-ceph"
ROOK_DIR="/tmp/rook-${ROOK_VERSION}"
PREFLIGHT_FAILED=0

# ============================================================
step "PHASE 0 — Kiểm tra trước khi cài đặt"
# ============================================================

# ── 0.1 Tools ───────────────────────────────────────────────
info "Kiểm tra tools..."
for cmd in kubectl helm git curl; do
    if command -v "$cmd" &>/dev/null; then
        success "$cmd: $(command -v $cmd)"
    else
        warn "$cmd: KHÔNG TÌM THẤY"
        PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1))
    fi
done

# ── 0.2 K8s cluster health ──────────────────────────────────
echo ""
info "Kiểm tra K8s cluster..."

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)

kubectl get nodes -o wide
echo ""

if [[ "$READY_NODES" -eq "$TOTAL_NODES" && "$TOTAL_NODES" -ge 3 ]]; then
    success "Cluster OK: $READY_NODES/$TOTAL_NODES nodes Ready"
else
    warn "Cluster chưa đủ: $READY_NODES/$TOTAL_NODES nodes Ready"
    PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1))
fi

# ── 0.3 Kiểm tra namespace rook-ceph chưa tồn tại ──────────
echo ""
info "Kiểm tra Rook-Ceph chưa cài..."
if kubectl get namespace "$ROOK_NS" &>/dev/null; then
    ROOK_PODS=$(kubectl get pods -n "$ROOK_NS" --no-headers 2>/dev/null | wc -l)
    if [[ "$ROOK_PODS" -gt 0 ]]; then
        warn "Namespace $ROOK_NS đã có $ROOK_PODS pods — Rook có thể đã cài"
        warn "Nếu muốn cài lại: kubectl delete namespace $ROOK_NS"
    fi
else
    success "Namespace $ROOK_NS chưa tồn tại — OK"
fi

# ── 0.4 Kiểm tra kernel module rbd ─────────────────────────
echo ""
info "Kiểm tra kernel module 'rbd'..."
if lsmod | grep -q "^rbd"; then
    success "rbd module đã load"
else
    warn "rbd module chưa load — đang load..."
    modprobe rbd 2>/dev/null && success "rbd module loaded" \
        || warn "Không load được rbd — sẽ tự load khi Ceph cần"
fi

# ── 0.5 Kiểm tra disks trên từng node ──────────────────────
echo ""
info "Kiểm tra disks trên tất cả nodes..."
echo ""

# Deploy DaemonSet tạm thời để kiểm tra disk từ xa
cat > /tmp/disk-checker.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: disk-checker
  namespace: default
spec:
  selector:
    matchLabels:
      app: disk-checker
  template:
    metadata:
      labels:
        app: disk-checker
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      hostPID: true
      hostNetwork: true
      containers:
        - name: checker
          image: ubuntu:22.04
          command: ["sleep", "3600"]
          securityContext:
            privileged: true
          volumeMounts:
            - name: host
              mountPath: /host
      volumes:
        - name: host
          hostPath:
            path: /
EOF

kubectl apply -f /tmp/disk-checker.yaml > /dev/null
info "Chờ disk-checker pods ready..."
kubectl wait --for=condition=ready pod \
    -l app=disk-checker \
    --timeout=60s 2>/dev/null || true
sleep 3

echo ""
echo -e "${BLUE}─── Trạng thái disks trên từng node ───${NC}"
for NODE in "$MASTER_HOSTNAME" "$WORKER1_HOSTNAME" "$WORKER2_HOSTNAME"; do
    POD=$(kubectl get pod -l app=disk-checker \
        --field-selector="spec.nodeName=$NODE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    echo ""
    echo -e "${CYAN}Node: $NODE${NC}"
    if [[ -n "$POD" ]]; then
        kubectl exec "$POD" -- lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null \
            | grep -v "^loop" || echo "  (không đọc được)"
    else
        warn "Không tìm thấy pod trên $NODE"
    fi
done

echo ""
kubectl delete -f /tmp/disk-checker.yaml > /dev/null 2>&1 || true

# ── 0.6 Hướng dẫn wipefs ────────────────────────────────────
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  QUAN TRỌNG: Ceph cần disks HOÀN TOÀN SẠCH         ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Chạy lệnh sau trên ${RED}TỪNG NODE${NC} (master + worker-01 + worker-02):"
echo ""
echo -e "  ${CYAN}# Xem disks hiện tại${NC}"
echo -e "  lsblk"
echo ""
echo -e "  ${CYAN}# Xóa signatures trên 2 disks Ceph: sdb (50GB) và nvme0n1 (20GB)${NC}"
echo -e "  sudo wipefs -a /dev/sdb && sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100 status=progress"
echo -e "  sudo wipefs -a /dev/nvme0n1 && sudo dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=100 status=progress"
echo ""

# ── 0.7 Kết quả preflight ───────────────────────────────────
echo ""
if [[ "$PREFLIGHT_FAILED" -gt 0 ]]; then
    error "$PREFLIGHT_FAILED vấn đề cần xử lý trước khi cài. Xem các [WARN] ở trên."
fi

read -rp "Bạn đã wipefs disks trên TẤT CẢ nodes chưa? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || error "Hãy wipefs disks trước. Chạy lại script sau khi xong."

success "Preflight checks PASSED — bắt đầu cài đặt"

# ============================================================
step "PHASE 1 — Tải Rook manifests"
# ============================================================
if [[ -d "$ROOK_DIR" ]]; then
    warn "Rook $ROOK_VERSION đã có tại $ROOK_DIR"
else
    info "Clone Rook $ROOK_VERSION..."
    git clone \
        --single-branch \
        --branch "$ROOK_VERSION" \
        --depth 1 \
        https://github.com/rook/rook.git \
        "$ROOK_DIR"
    success "Rook cloned: $ROOK_DIR"
fi

cd "$ROOK_DIR/deploy/examples"

# ============================================================
step "PHASE 3 — Deploy Rook Operator"
# ============================================================
info "Apply CRDs..."
kubectl apply -f crds.yaml
sleep 3

info "Apply common resources..."
kubectl apply -f common.yaml

info "Apply Rook operator..."
kubectl apply -f operator.yaml

info "Chờ Rook operator ready (tối đa 3 phút)..."
kubectl -n "$ROOK_NS" rollout status deploy/rook-ceph-operator --timeout=180s
success "Rook operator running"

# Apply monitoring RBAC trước khi tạo CephCluster
# (Rook operator cần quyền này để tạo ServiceMonitor cho Prometheus)
info "Apply monitoring RBAC..."
kubectl apply -f monitoring/rbac.yaml 2>/dev/null \
    && success "Monitoring RBAC applied" \
    || warn "Không tìm thấy monitoring/rbac.yaml — bỏ qua (sẽ apply ở PHASE 9)"

# ============================================================
step "PHASE 4 — Tạo Ceph Cluster"
# ============================================================
info "Tạo CephCluster config..."

cat > /tmp/ceph-cluster.yaml << EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: ${CEPH_IMAGE}
    allowUnsupported: false

  dataDirHostPath: /var/lib/rook

  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false

  mon:
    count: 3
    allowMultiplePerNode: false

  mgr:
    count: 1
    modules:
      - name: pg_autoscaler
        enabled: true
      - name: rook
        enabled: true

  dashboard:
    enabled: true
    ssl: false

  monitoring:
    enabled: true

  network:
    connections:
      encryption:
        enabled: false
      compression:
        enabled: false

  storage:
    useAllNodes: true
    useAllDevices: false
    devices:
      - name: "sdb"
      - name: "nvme0n1"

  resources:
    mon:
      requests:
        cpu: "200m"
        memory: "512Mi"
      limits:
        memory: "1Gi"
    osd:
      requests:
        cpu: "200m"
        memory: "512Mi"
      limits:
        memory: "2Gi"
    mgr:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        memory: "1Gi"
    prepareosd:
      requests:
        cpu: "100m"
        memory: "50Mi"

  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30

  healthCheck:
    daemonHealth:
      mon:
        interval: 45s
      osd:
        interval: 60s
      status:
        interval: 60s
EOF

kubectl apply -f /tmp/ceph-cluster.yaml
success "CephCluster CR applied"

info "Theo dõi quá trình khởi tạo (mất 5-15 phút)..."
echo -e "${YELLOW}Bạn có thể mở terminal khác và chạy:${NC}"
echo -e "  ${CYAN}watch kubectl -n rook-ceph get pods${NC}"
echo ""

# Hàm chờ pod tồn tại, in diagnostic nếu timeout
wait_for_pods_exist() {
    local ns="$1" selector="$2" timeout="${3:-600}"
    local elapsed=0
    info "Chờ pods xuất hiện: $selector ..."
    until kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | grep -q .; do
        if [[ "$elapsed" -ge "$timeout" ]]; then
            echo ""
            warn "Timeout ${timeout}s — pods $selector chưa xuất hiện"
            echo -e "${YELLOW}─── Operator log (30 dòng cuối) ───${NC}"
            kubectl logs -n "$ns" deploy/rook-ceph-operator --tail=30 2>/dev/null || true
            echo -e "${YELLOW}─── Pods hiện tại ───${NC}"
            kubectl get pods -n "$ns" -o wide 2>/dev/null || true
            echo -e "${YELLOW}─── Events ───${NC}"
            kubectl get events -n "$ns" --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
            error "Dừng tại đây — xem log phía trên để debug"
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""
}

# Hàm chờ pods ready, in diagnostic nếu timeout
wait_for_pods_ready() {
    local ns="$1" selector="$2" timeout="${3:-600}" label="${4:-$2}"
    info "Chờ $label ready..."
    wait_for_pods_exist "$ns" "$selector" "$timeout"
    if ! kubectl wait --namespace "$ns" \
        --for=condition=ready pod \
        --selector="$selector" \
        --timeout="${timeout}s" 2>/dev/null; then
        echo ""
        warn "Một số pods chưa Ready — xem trạng thái:"
        kubectl get pods -n "$ns" -l "$selector" -o wide
        kubectl get pods -n "$ns" -l "$selector" -o name \
            | while read -r pod; do
                echo -e "${YELLOW}--- Log: $pod ---${NC}"
                kubectl logs -n "$ns" "$pod" --tail=20 --all-containers 2>/dev/null || true
            done
        error "$label chưa Ready sau ${timeout}s"
    fi
    success "$label ready"
}

wait_for_pods_ready "$ROOK_NS" "app=rook-ceph-mon" 600 "Ceph MONs"
wait_for_pods_ready "$ROOK_NS" "app=rook-ceph-mgr" 300 "Ceph MGR"

info "Chờ Ceph OSDs ready..."
wait_for_pods_exist "$ROOK_NS" "app=rook-ceph-osd" 600
# Kiểm tra osd-prepare jobs có lỗi không
FAILED_PREPARE=$(kubectl get pods -n "$ROOK_NS" --no-headers 2>/dev/null \
    | grep "osd-prepare" | grep -v "Completed" | grep -v "Running" || true)
if [[ -n "$FAILED_PREPARE" ]]; then
    warn "Một số osd-prepare pods gặp vấn đề:"
    echo "$FAILED_PREPARE"
    echo -e "${YELLOW}─── Log osd-prepare bị lỗi ───${NC}"
    kubectl get pods -n "$ROOK_NS" --no-headers | grep "osd-prepare" \
        | grep -v "Completed" | awk '{print $1}' \
        | while read -r pod; do
            echo "--- $pod ---"
            kubectl logs -n "$ROOK_NS" "$pod" --all-containers --tail=30 2>/dev/null || true
        done
fi
kubectl wait --namespace "$ROOK_NS" \
    --for=condition=ready pod \
    --selector=app=rook-ceph-osd \
    --timeout=600s || {
        warn "Một số OSD pods chưa Ready:"
        kubectl get pods -n "$ROOK_NS" -l app=rook-ceph-osd -o wide
        error "OSDs chưa Ready sau 600s — xem log phía trên"
    }
success "Ceph OSDs ready"

# ============================================================
step "PHASE 5 — Deploy Ceph Toolbox"
# ============================================================
kubectl apply -f toolbox.yaml
kubectl -n "$ROOK_NS" rollout status deploy/rook-ceph-tools --timeout=120s
success "Ceph toolbox deployed"

info "Kiểm tra Ceph status..."
sleep 10
kubectl -n "$ROOK_NS" exec deploy/rook-ceph-tools -- ceph status
echo ""
kubectl -n "$ROOK_NS" exec deploy/rook-ceph-tools -- ceph osd tree

# ============================================================
step "PHASE 5b — Expose Ceph Dashboard qua LoadBalancer"
# ============================================================
# Tạo Service riêng thay vì patch service Rook quản lý (patch sẽ bị revert)
cat > /tmp/ceph-dashboard-lb.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: rook-ceph-mgr-dashboard-lb
  namespace: rook-ceph
  labels:
    app: rook-ceph-mgr
spec:
  type: LoadBalancer
  ports:
    - name: dashboard
      port: 80
      protocol: TCP
      targetPort: 7000
  selector:
    app: rook-ceph-mgr
    rook_cluster: rook-ceph
EOF

kubectl apply -f /tmp/ceph-dashboard-lb.yaml
success "Ceph Dashboard LoadBalancer service created"

# Chờ lấy IP
info "Chờ Ceph Dashboard External IP..."
for i in $(seq 1 12); do
    DASHBOARD_IP=$(kubectl get svc rook-ceph-mgr-dashboard-lb -n "$ROOK_NS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$DASHBOARD_IP" ]]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

if [[ -n "${DASHBOARD_IP:-}" ]]; then
    success "Ceph Dashboard: http://${DASHBOARD_IP}"
else
    warn "Chưa có External IP — kiểm tra MetalLB. Dùng tạm: kubectl port-forward svc/rook-ceph-mgr-dashboard 7000 -n rook-ceph"
fi

# ============================================================
step "PHASE 6 — Tạo StorageClass cho RBD (Block Storage)"
# ============================================================
cat > /tmp/ceph-blockpool.yaml << 'EOF'
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
    requireSafeReplicaSize: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
mountOptions:
  - discard
EOF

kubectl apply -f /tmp/ceph-blockpool.yaml
success "RBD StorageClass 'rook-ceph-block' created (default)"

# ============================================================
step "PHASE 7 — Tạo StorageClass cho CephFS (Shared Filesystem)"
# ============================================================
cat > /tmp/ceph-filesystem.yaml << 'EOF'
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: myfs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 3
  dataPools:
    - name: data0
      replicated:
        size: 3
  preserveFilesystemOnDelete: false
  metadataServer:
    activeCount: 1
    activeStandby: true
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        memory: "1Gi"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: myfs
  pool: myfs-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

kubectl apply -f /tmp/ceph-filesystem.yaml
success "CephFS StorageClass 'rook-cephfs' created"

# Chờ MDS ready
info "Chờ CephFS MDS ready..."
wait_for_pods_exist "$ROOK_NS" "app=rook-ceph-mds" 300
kubectl wait --namespace "$ROOK_NS" \
    --for=condition=ready pod \
    --selector=app=rook-ceph-mds \
    --timeout=300s
success "CephFS MDS ready"

# ============================================================
step "PHASE 8 — Test PVC"
# ============================================================
info "Test tạo PVC với RBD StorageClass..."

cat > /tmp/test-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rook-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

kubectl apply -f /tmp/test-pvc.yaml
info "Chờ PVC bound..."
for i in $(seq 1 24); do
    STATUS=$(kubectl get pvc rook-test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$STATUS" == "Bound" ]]; then
        success "PVC Bound thành công!"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

kubectl get pvc rook-test-pvc
kubectl delete -f /tmp/test-pvc.yaml --wait=false

# ============================================================
step "PHASE 9 — Upgrade Monitoring để scrape Ceph metrics"
# ============================================================
info "Áp dụng Ceph ServiceMonitor cho Prometheus..."
kubectl apply -f "${ROOK_DIR}/deploy/examples/monitoring/rbac.yaml" 2>/dev/null || true
kubectl apply -f "${ROOK_DIR}/deploy/examples/monitoring/service-monitor.yaml" 2>/dev/null || true
success "Ceph metrics sẽ xuất hiện trong Grafana"

# ============================================================
step "TỔNG KẾT"
# ============================================================
echo ""
echo -e "${CYAN}=== Ceph Status ===${NC}"
kubectl -n "$ROOK_NS" exec deploy/rook-ceph-tools -- ceph status

echo ""
echo -e "${CYAN}=== StorageClasses ===${NC}"
kubectl get storageclass

echo ""
echo -e "${CYAN}=== Rook-Ceph Pods ===${NC}"
kubectl get pods -n "$ROOK_NS"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Rook-Ceph HOÀN THÀNH                            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Lấy lại IP Dashboard (đã tạo ở PHASE 5b)
DASHBOARD_IP=$(kubectl get svc rook-ceph-mgr-dashboard-lb -n "$ROOK_NS" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
DASHBOARD_PASS=$(kubectl -n "$ROOK_NS" get secret rook-ceph-dashboard-password \
    -o jsonpath="{['data']['password']}" 2>/dev/null | base64 --decode 2>/dev/null || echo "(chạy: kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d)")

if [[ -n "$DASHBOARD_IP" ]]; then
    echo -e "  Ceph Dashboard: ${CYAN}http://${DASHBOARD_IP}${NC}"
else
    echo -e "  Ceph Dashboard: ${YELLOW}(chưa có IP — kubectl get svc rook-ceph-mgr-dashboard-lb -n rook-ceph)${NC}"
fi
echo -e "  Username: ${CYAN}admin${NC}"
echo -e "  Password: ${CYAN}${DASHBOARD_PASS}${NC}"
echo ""

echo -e "${YELLOW}StorageClasses đã tạo:${NC}"
echo -e "  ${CYAN}rook-ceph-block${NC}  (default) — Block storage, dùng cho PVC ReadWriteOnce"
echo -e "  ${CYAN}rook-cephfs${NC}               — Shared filesystem, dùng cho PVC ReadWriteMany"
echo ""
echo -e "${YELLOW}Lệnh hữu ích:${NC}"
echo -e "  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
echo -e "  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree"
echo -e "  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df"
echo -e "  kubectl get pvc -A"
echo ""
echo -e "${YELLOW}Bước tiếp theo:${NC}"
echo -e "  Upgrade monitoring để dùng Ceph storage: ${CYAN}sudo bash 05-monitoring.sh${NC}"
echo -e "  Cài KubeVirt: ${CYAN}sudo bash 08-kubevirt.sh${NC}"
echo ""
echo -e "${YELLOW}Nếu cần cài lại từ đầu, chạy theo thứ tự:${NC}"
echo -e "  ${CYAN}# 1. Xóa finalizers + CRs${NC}"
echo -e "  for cr in cephblockpool cephfilesystem cephobjectstore cephcluster; do"
echo -e "    kubectl get \$cr -n rook-ceph -o name 2>/dev/null | xargs -I{} sh -c \\"
echo -e "      'kubectl patch {} -n rook-ceph --type merge -p {\\\"metadata\\\":{\\\"finalizers\\\":[]}} 2>/dev/null; kubectl delete {} -n rook-ceph'"
echo -e "  done"
echo -e "  ${CYAN}# 2. Xóa StorageClass và CRDs${NC}"
echo -e "  kubectl delete storageclass rook-ceph-block rook-cephfs --ignore-not-found"
echo -e "  kubectl get crd | grep rook | awk '{print \$1}' | xargs kubectl delete crd"
echo -e "  ${CYAN}# 3. Xóa namespace CUỐI CÙNG${NC}"
echo -e "  kubectl delete namespace rook-ceph --ignore-not-found"
echo -e "  ${CYAN}# 4. Wipe disks trên từng node${NC}"
echo -e "  sudo rm -rf /var/lib/rook && sudo wipefs -a /dev/sdb && sudo wipefs -a /dev/nvme0n1"
