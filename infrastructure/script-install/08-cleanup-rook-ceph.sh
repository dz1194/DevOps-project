#!/usr/bin/env bash
# ============================================================
# 07-cleanup-rook-ceph.sh — Xóa sạch Rook-Ceph khỏi cluster
# Thứ tự: CRs → StorageClass → namespace → CRDs → disk
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════${NC}"; }

ROOK_NS="rook-ceph"

# ── Kiểm tra namespace tồn tại không ───────────────────────
if ! kubectl get namespace "$ROOK_NS" &>/dev/null; then
    warn "Namespace $ROOK_NS không tồn tại — bỏ qua bước xóa CRs"
fi

# ============================================================
step "BƯỚC 1 — Xóa finalizers + CRs (phải làm trước namespace)"
# ============================================================
# Thứ tự quan trọng: xóa dependent trước, CephCluster sau
CEPH_CRS=(
    cephfilesystemmirror
    cephrbdmirror
    cephnfs
    cephclient
    cephobjectstoreuser
    cephobjectstore
    cephobjectrealm
    cephobjectzonegroup
    cephobjectzone
    cephfilesystemsubvolumegroup
    cephblockpoolradosnamespace
    cephfilesystem
    cephblockpool
    cephcluster
)

for cr in "${CEPH_CRS[@]}"; do
    RESOURCES=$(kubectl get "$cr" -n "$ROOK_NS" -o name 2>/dev/null || true)
    if [[ -n "$RESOURCES" ]]; then
        info "Xóa $cr..."
        echo "$RESOURCES" | while read -r res; do
            kubectl patch "$res" -n "$ROOK_NS" \
                --type merge -p '{"metadata":{"finalizers":[]}}' \
                2>/dev/null || true
            kubectl delete "$res" -n "$ROOK_NS" \
                --ignore-not-found --wait=false 2>/dev/null || true
        done
    fi
done

# Chờ CRs xóa xong (tối đa 60s)
info "Chờ CRs xóa xong..."
for i in $(seq 1 12); do
    REMAINING=0
    for cr in cephcluster cephblockpool cephfilesystem; do
        COUNT=$(kubectl get "$cr" -n "$ROOK_NS" --no-headers 2>/dev/null | wc -l)
        REMAINING=$((REMAINING + COUNT))
    done
    [[ "$REMAINING" -eq 0 ]] && break
    echo -n "."; sleep 5
done
echo ""
success "CRs đã xóa"

# ============================================================
step "BƯỚC 2 — Xóa StorageClasses (cluster-scoped)"
# ============================================================
for sc in rook-ceph-block rook-cephfs; do
    kubectl delete storageclass "$sc" --ignore-not-found && \
        success "StorageClass $sc đã xóa" || true
done

# ============================================================
step "BƯỚC 3 — Xóa namespace (sau khi CRs đã sạch)"
# ============================================================
force_delete_namespace() {
    kubectl get namespace "$ROOK_NS" -o json \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['spec']['finalizers'] = []
print(json.dumps(d))
" | kubectl replace --raw "/api/v1/namespaces/$ROOK_NS/finalize" -f - \
        2>/dev/null && success "Namespace $ROOK_NS đã xóa (force)" \
        || warn "Force delete không thực hiện được"
}

if kubectl get namespace "$ROOK_NS" &>/dev/null; then
    kubectl delete namespace "$ROOK_NS" --ignore-not-found --wait=false

    info "Chờ namespace xóa (tối đa 10s)..."
    for i in $(seq 1 2); do
        if ! kubectl get namespace "$ROOK_NS" &>/dev/null; then
            echo ""; success "Namespace $ROOK_NS đã xóa"; break
        fi
        echo -n "."; sleep 5
    done
    echo ""

    # Namespace vẫn còn — force patch ngay, không scan api-resources
    if kubectl get namespace "$ROOK_NS" &>/dev/null; then
        warn "Namespace stuck — force patch finalize endpoint..."
        force_delete_namespace
        sleep 2
        ! kubectl get namespace "$ROOK_NS" &>/dev/null \
            || warn "Namespace vẫn còn — tiếp tục các bước còn lại"
    fi
else
    success "Namespace $ROOK_NS không tồn tại — bỏ qua"
fi

# ============================================================
step "BƯỚC 4 — Xóa CRDs (sau khi namespace đã xóa)"
# ============================================================
CRDS=$(kubectl get crd 2>/dev/null | grep rook | awk '{print $1}')
if [[ -n "$CRDS" ]]; then
    echo "$CRDS" | while read -r crd; do
        kubectl patch crd "$crd" \
            --type merge -p '{"metadata":{"finalizers":[]}}' \
            2>/dev/null || true
        kubectl delete crd "$crd" --ignore-not-found
        success "CRD $crd đã xóa"
    done
else
    success "Không có Rook CRDs"
fi

# ============================================================
step "BƯỚC 5 — Xóa RBAC cluster-scoped còn sót"
# ============================================================
kubectl get clusterrolebinding 2>/dev/null | grep rook | awk '{print $1}' \
    | xargs -r kubectl delete clusterrolebinding --ignore-not-found 2>/dev/null || true
kubectl get clusterrole 2>/dev/null | grep rook | awk '{print $1}' \
    | xargs -r kubectl delete clusterrole --ignore-not-found 2>/dev/null || true
success "RBAC cluster-scoped đã xóa"

# ============================================================
step "VERIFY — Kiểm tra còn sót gì không"
# ============================================================
echo ""
CRD_COUNT=$(kubectl get crd 2>/dev/null | grep -c rook || true)
SC_COUNT=$(kubectl get storageclass 2>/dev/null | grep -c rook || true)
NS_EXISTS=$(kubectl get namespace "$ROOK_NS" &>/dev/null && echo "CÒN" || echo "đã xóa")

echo -e "  Namespace rook-ceph : ${CYAN}$NS_EXISTS${NC}"
echo -e "  Rook CRDs còn lại  : ${CYAN}$CRD_COUNT${NC}"
echo -e "  Rook StorageClasses: ${CYAN}$SC_COUNT${NC}"

echo ""
if [[ "$CRD_COUNT" -eq 0 && "$NS_EXISTS" == "đã xóa" ]]; then
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Cleanup HOÀN THÀNH — cluster sạch       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Bước tiếp theo — wipe disks trên TỪNG node:${NC}"
    echo -e "  ${CYAN}sudo rm -rf /var/lib/rook${NC}"
    echo -e "  ${CYAN}sudo wipefs -a /dev/sdb && sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100${NC}"
    echo -e "  ${CYAN}sudo wipefs -a /dev/nvme0n1 && sudo dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=100${NC}"
    echo ""
    echo -e "${YELLOW}Sau khi wipe xong, chạy lại:${NC}"
    echo -e "  ${CYAN}sudo bash 07-rook-ceph.sh${NC}"
else
    warn "Còn sót — kiểm tra thủ công:"
    kubectl get crd | grep rook || true
    kubectl get namespace "$ROOK_NS" 2>/dev/null || true
fi
