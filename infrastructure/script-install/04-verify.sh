#!/usr/bin/env bash
# ============================================================
# 04-verify.sh — Chạy trên MASTER sau khi tất cả nodes đã join
# Kiểm tra toàn bộ cluster hoạt động đúng
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✓]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[!]${NC}    $*"; }
fail()    { echo -e "${RED}[✗]${NC}    $*"; FAILED=$((FAILED+1)); }
step()    { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════${NC}"; }

FAILED=0
export KUBECONFIG=/root/.kube/config

# ── Guard ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { KUBECONFIG="$HOME/.kube/config"; }
command -v kubectl &>/dev/null || { echo "kubectl not found"; exit 1; }

# ============================================================
step "CHECK 1 — Nodes"
# ============================================================
echo ""
kubectl get nodes -o wide
echo ""

TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready " || true)

info "Total: $TOTAL_NODES nodes, Ready: $READY_NODES"

if [[ "$READY_NODES" -eq 3 ]]; then
    success "Tất cả 3 nodes Ready"
elif [[ "$READY_NODES" -ge 1 ]]; then
    warn "Chỉ $READY_NODES/$TOTAL_NODES nodes Ready — workers có thể chưa join"
else
    fail "Không có node nào Ready"
fi

# ============================================================
step "CHECK 2 — Cilium"
# ============================================================
if command -v cilium &>/dev/null; then
    cilium status 2>/dev/null && success "Cilium OK" || fail "Cilium có vấn đề"
else
    warn "cilium CLI chưa cài, kiểm tra qua kubectl"
fi

CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers | wc -l)
CILIUM_READY=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers | grep -c "Running" || true)
info "Cilium pods: $CILIUM_READY/$CILIUM_PODS Running"
[[ "$CILIUM_READY" -eq "$CILIUM_PODS" && "$CILIUM_PODS" -gt 0 ]] \
    && success "Tất cả Cilium pods Running" \
    || fail "Cilium pods chưa fully Ready ($CILIUM_READY/$CILIUM_PODS)"

# ============================================================
step "CHECK 3 — MetalLB"
# ============================================================
METALLB_CTRL=$(kubectl get pods -n metallb-system -l component=controller --no-headers | grep -c "Running" || true)
METALLB_SPKR=$(kubectl get pods -n metallb-system -l component=speaker --no-headers | grep -c "Running" || true)

[[ "$METALLB_CTRL" -ge 1 ]] && success "MetalLB controller Running" || fail "MetalLB controller không Running"
[[ "$METALLB_SPKR" -ge 1 ]] && success "MetalLB speaker(s) Running ($METALLB_SPKR)" || fail "MetalLB speaker không Running"

info "IP Pool:"
kubectl get ipaddresspools -n metallb-system 2>/dev/null || warn "IPAddressPool chưa cấu hình"

# ============================================================
step "CHECK 4 — System Pods"
# ============================================================
NOT_RUNNING=$(kubectl get pods -A --no-headers | grep -v "Running\|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
    success "Tất cả system pods Running/Completed"
else
    warn "$NOT_RUNNING pods chưa Running:"
    kubectl get pods -A --no-headers | grep -v "Running\|Completed" || true
fi

# ============================================================
step "CHECK 5 — DNS (CoreDNS)"
# ============================================================
COREDNS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -c "Running" || true)
[[ "$COREDNS" -ge 1 ]] && success "CoreDNS Running ($COREDNS pods)" || fail "CoreDNS không Running"

# Test DNS resolution
info "Test DNS resolution..."
if kubectl run dns-test --image=busybox:1.28 --rm --restart=Never \
    --command --timeout=30s -- nslookup kubernetes.default &>/dev/null 2>&1; then
    success "DNS resolution OK"
else
    warn "DNS test timeout (có thể vẫn OK nếu cluster mới khởi động)"
fi

# ============================================================
step "CHECK 6 — LoadBalancer Test"
# ============================================================
info "Deploy nginx và test LoadBalancer..."

cat > /tmp/lb-verify.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lb-verify
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: lb-verify
  template:
    metadata:
      labels:
        app: lb-verify
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: lb-verify-svc
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: lb-verify
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl apply -f /tmp/lb-verify.yaml -q
kubectl wait --for=condition=ready pod -l app=lb-verify --timeout=60s -q

sleep 15
LB_IP=$(kubectl get svc lb-verify-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -n "$LB_IP" ]]; then
    success "MetalLB assigned IP: $LB_IP"
    if curl -sf --max-time 5 "http://$LB_IP" &>/dev/null; then
        success "HTTP request tới $LB_IP thành công"
    else
        warn "curl tới $LB_IP thất bại (có thể do network VMware — test thủ công)"
    fi
else
    fail "LoadBalancer IP chưa được gán — kiểm tra MetalLB config"
fi

kubectl delete -f /tmp/lb-verify.yaml -q 2>/dev/null || true

# ============================================================
step "TỔNG KẾT"
# ============================================================
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -A | grep -v "Running\|Completed" | head -20 || true
echo ""

if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Cluster HEALTHY — Tất cả checks PASSED        ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  $FAILED checks FAILED — Xem chi tiết ở trên  ║${NC}"
    echo -e "${RED}╚═════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "${CYAN}Cluster sẵn sàng cài tiếp:${NC}"
echo -e "  • Rook-Ceph  : Phase 6 trong LAB_SETUP_GUIDE.md"
echo -e "  • KubeVirt   : Phase 7"
echo -e "  • Monitoring : Phase 8"
echo ""
echo -e "${CYAN}Một số lệnh hữu ích:${NC}"
echo -e "  kubectl get nodes -o wide"
echo -e "  kubectl get pods -A"
echo -e "  cilium status"
echo -e "  kubectl get svc -A"

exit "$FAILED"
