#!/usr/bin/env bash
# ============================================================
# 05-monitoring.sh — Cài / Upgrade Prometheus + Grafana
# Yêu cầu: K8s cluster đã chạy, MetalLB đã cấu hình
# Storage: tự động dùng rook-ceph-block nếu có, fallback emptyDir
# Chạy lại script sau khi cài Ceph để tự động upgrade persistent storage
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
command -v kubectl &>/dev/null || error "kubectl không tìm thấy"

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin123}"
MONITORING_NS="monitoring"
STORAGE_CLASS="rook-ceph-block"

# Tự detect Ceph storage
if kubectl get storageclass "$STORAGE_CLASS" &>/dev/null \
    && [[ "$(kubectl get cephcluster rook-ceph -n rook-ceph \
        -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; then
    USE_CEPH=true
    info "Ceph storage detected — dùng persistent storage ($STORAGE_CLASS)"
else
    USE_CEPH=false
    warn "Ceph chưa sẵn sàng — dùng emptyDir (chạy lại sau khi cài Ceph để upgrade)"
fi

# ============================================================
step "PHASE 1 — Cài Helm"
# ============================================================
if command -v helm &>/dev/null; then
    warn "Helm đã có: $(helm version --short)"
else
    info "Downloading Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    success "Helm installed: $(helm version --short)"
fi

# ============================================================
step "PHASE 2 — Thêm Helm repo"
# ============================================================
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
success "Helm repos updated"

# ============================================================
step "PHASE 3 — Tạo namespace monitoring"
# ============================================================
kubectl get namespace "$MONITORING_NS" &>/dev/null \
    || kubectl create namespace "$MONITORING_NS"
success "Namespace $MONITORING_NS ready"

# ============================================================
step "PHASE 4 — Tạo values file"
# ============================================================
if [[ "$USE_CEPH" == "true" ]]; then
    GRAFANA_PERSISTENCE="
  persistence:
    enabled: true
    storageClassName: ${STORAGE_CLASS}
    size: 5Gi
    accessModes:
      - ReadWriteOnce"
    PROMETHEUS_STORAGE="
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS}
          accessModes: [\"ReadWriteOnce\"]
          resources:
            requests:
              storage: 20Gi"
    ALERTMANAGER_STORAGE="
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS}
          accessModes: [\"ReadWriteOnce\"]
          resources:
            requests:
              storage: 2Gi"
    RETENTION="15d"
else
    GRAFANA_PERSISTENCE="
  persistence:
    enabled: false"
    PROMETHEUS_STORAGE="
    storageSpec: {}"
    ALERTMANAGER_STORAGE="
    storage: {}"
    RETENTION="7d"
fi

cat > /tmp/monitoring-values.yaml << EOF
# ── Grafana ─────────────────────────────────────────────────
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"

  service:
    type: LoadBalancer
${GRAFANA_PERSISTENCE}

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  defaultDashboardsEnabled: true
  defaultDashboardsTimezone: Asia/Ho_Chi_Minh

  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/"
    security:
      allow_embedding: true

# ── Prometheus ───────────────────────────────────────────────
prometheus:
  prometheusSpec:
${PROMETHEUS_STORAGE}

    retention: ${RETENTION}

    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi

    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# ── Alertmanager ─────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:
${ALERTMANAGER_STORAGE}

    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi

# ── Node Exporter ────────────────────────────────────────────
nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
EOF

success "Values file created: /tmp/monitoring-values.yaml"

# ============================================================
step "PHASE 5 — Cài kube-prometheus-stack"
# ============================================================
if helm list -n "$MONITORING_NS" | grep -q "kube-prometheus-stack"; then
    warn "kube-prometheus-stack đã cài. Upgrade..."
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace "$MONITORING_NS" \
        --values /tmp/monitoring-values.yaml \
        --timeout 10m \
        --wait
else
    info "Cài kube-prometheus-stack..."
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace "$MONITORING_NS" \
        --values /tmp/monitoring-values.yaml \
        --timeout 10m \
        --wait
fi

success "kube-prometheus-stack installed"

# ============================================================
step "PHASE 6 — Kiểm tra"
# ============================================================
info "Pods trong namespace $MONITORING_NS:"
kubectl get pods -n "$MONITORING_NS"

echo ""
info "Chờ Grafana LoadBalancer IP..."
for i in $(seq 1 12); do
    GRAFANA_IP=$(kubectl get svc -n "$MONITORING_NS" \
        -l "app.kubernetes.io/name=grafana" \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$GRAFANA_IP" ]]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

# ============================================================
step "TỔNG KẾT"
# ============================================================
echo ""
kubectl get svc -n "$MONITORING_NS"
echo ""

if [[ -n "${GRAFANA_IP:-}" ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Monitoring HOÀN THÀNH                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Grafana:     ${CYAN}http://${GRAFANA_IP}${NC}"
    echo -e "  Username:    ${CYAN}admin${NC}"
    echo -e "  Password:    ${CYAN}${GRAFANA_ADMIN_PASSWORD}${NC}"
    echo ""
    if [[ "$USE_CEPH" == "true" ]]; then
        echo -e "${YELLOW}Persistent storage (Ceph):${NC} Prometheus 20Gi | Grafana 5Gi | Alertmanager 2Gi"
        kubectl get pvc -n "$MONITORING_NS" 2>/dev/null || true
    else
        echo -e "${YELLOW}Lưu ý:${NC} Data sẽ mất khi pod restart (chưa có Ceph)."
        echo -e "Chạy lại script này sau khi cài Rook-Ceph để tự động upgrade persistent storage."
    fi
else
    warn "Grafana chưa có External IP. Kiểm tra MetalLB:"
    echo -e "  kubectl get svc -n $MONITORING_NS"
    echo ""
    echo -e "Truy cập tạm qua port-forward:"
    echo -e "  ${CYAN}kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n $MONITORING_NS${NC}"
    echo -e "  Mở: http://localhost:3000 (admin/${GRAFANA_ADMIN_PASSWORD})"
fi

echo ""
echo -e "${CYAN}Một số lệnh hữu ích:${NC}"
echo -e "  kubectl get pods -n $MONITORING_NS"
echo -e "  kubectl get svc -n $MONITORING_NS"
echo -e "  helm list -n $MONITORING_NS"
