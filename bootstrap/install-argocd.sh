#!/usr/bin/env bash
# ============================================================
# bootstrap/install-argocd.sh
# Cài ArgoCD và bootstrap App-of-Apps
# Chạy 1 lần trên master node sau khi K8s cluster sẵn sàng
# ============================================================
set -euo pipefail

GITOPS_REPO="https://github.com/dz1194/DevOps-project.git"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }
export KUBECONFIG=/root/.kube/config

# ── Lấy version ArgoCD mới nhất từ GitHub API ───────────────
# Để pin version cụ thể: ARGOCD_VERSION="v2.13.3" bash bootstrap/install-argocd.sh
if [[ -z "${ARGOCD_VERSION:-}" ]]; then
    info "Đang lấy ArgoCD version mới nhất..."
    ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$ARGOCD_VERSION" ]] && ARGOCD_VERSION="v2.13.3"  # fallback
fi
info "ArgoCD version: ${ARGOCD_VERSION}"

# ── Tạo namespace ────────────────────────────────────────────
info "Tạo namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ── Cài ArgoCD (server-side apply + Kustomize LoadBalancer patch) ──
# --server-side: tránh lỗi "annotation too long" (CRD > 262144 bytes)
#   kubectl apply mặc định lưu toàn bộ manifest vào annotation
#   kubectl.kubernetes.io/last-applied-configuration → CRD ArgoCD quá lớn
#   Server-side apply chuyển logic lên API server, không cần annotation đó
#
# Kustomize patch: override argocd-server service sang LoadBalancer ngay
#   khi apply, không cần bước patch riêng sau đó
info "Cài ArgoCD ${ARGOCD_VERSION}..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml
patches:
  - target:
      kind: Service
      name: argocd-server
    patch: |-
      - op: replace
        path: /spec/type
        value: LoadBalancer
EOF

kubectl apply --server-side -n argocd -k "$TMPDIR"
success "ArgoCD applied"

# ── Chờ ArgoCD ready ─────────────────────────────────────────
info "Chờ ArgoCD server ready (tối đa 5 phút)..."
kubectl rollout status deploy/argocd-server -n argocd --timeout=300s
success "ArgoCD server running"

# ── Chờ External IP từ MetalLB ───────────────────────────────
info "Chờ External IP từ MetalLB..."
for i in $(seq 1 12); do
    ARGOCD_IP=$(kubectl get svc argocd-server -n argocd \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [[ -n "$ARGOCD_IP" ]] && break
    echo -n "."; sleep 5
done
echo ""

# ── Lấy initial admin password ───────────────────────────────
INITIAL_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 --decode)

# ── Tạo Grafana admin secret ─────────────────────────────────
warn "Tạo Grafana admin secret mặc định (admin123)..."
warn "Đổi password sau:"
warn "  kubectl create secret generic grafana-admin-secret -n monitoring \\"
warn "    --from-literal=admin-user=admin --from-literal=admin-password=STRONG_PASS \\"
warn "    --dry-run=client -o yaml | kubectl apply -f -"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin-secret \
    -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password=admin123 \
    --dry-run=client -o yaml | kubectl apply -f -

# ── Bootstrap App-of-Apps ────────────────────────────────────
info "Apply App-of-Apps..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/app-of-apps.yaml"

# ── Kết quả ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ArgoCD HOÀN THÀNH                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
if [[ -n "${ARGOCD_IP:-}" ]]; then
    echo -e "  ArgoCD UI:  ${CYAN}https://${ARGOCD_IP}${NC}"
else
    echo -e "  ArgoCD UI:  ${YELLOW}(chưa có IP — kubectl get svc argocd-server -n argocd)${NC}"
fi
echo -e "  Username:   ${CYAN}admin${NC}"
echo -e "  Password:   ${CYAN}${INITIAL_PASS}${NC}"
echo ""
echo -e "${YELLOW}ArgoCD đang sync infrastructure từ:${NC}"
echo -e "  ${CYAN}${GITOPS_REPO}${NC}"
echo ""
echo -e "Theo dõi: ${CYAN}https://${ARGOCD_IP:-<IP>}/applications${NC}"
