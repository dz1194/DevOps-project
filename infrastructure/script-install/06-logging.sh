#!/usr/bin/env bash
# ============================================================
# 06-logging.sh — Cài PLG Stack: Promtail + Loki
# Tích hợp vào Grafana đã cài ở bước 05-monitoring.sh
# Yêu cầu: Grafana (kube-prometheus-stack) đã chạy
# Storage: filesystem/emptyDir (chưa cần Ceph)
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
command -v helm &>/dev/null    || error "helm không tìm thấy. Chạy 05-monitoring.sh trước."

MONITORING_NS="monitoring"

# ============================================================
step "PHASE 1 — Thêm Grafana Helm repo"
# ============================================================
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
success "Helm repos updated"

# ============================================================
step "PHASE 2 — Cài Loki"
# ============================================================
cat > /tmp/loki-values.yaml << 'EOF'
loki:
  commonConfig:
    replication_factor: 1

  storage:
    type: filesystem

  # Không dùng persistent storage (chưa có Ceph)
  persistence:
    enabled: false

  auth_enabled: false

  # Schema config bắt buộc từ Loki v3+
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  limits_config:
    retention_period: 7d
    ingestion_rate_mb: 8
    ingestion_burst_size_mb: 16

  compactor:
    retention_enabled: true
    delete_request_store: filesystem

  server:
    http_listen_port: 3100

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Single binary mode — đủ cho lab
deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  persistence:
    enabled: false
  extraVolumes:
    - name: loki-storage
      emptyDir: {}
  extraVolumeMounts:
    - name: loki-storage
      mountPath: /var/loki

# Tắt cache (memcached) — tốn RAM, không cần cho lab
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Tắt components không cần
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

# Tắt self-monitoring để giảm tải
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  lokiCanary:
    enabled: false

# Tắt test
test:
  enabled: false
EOF

if helm list -n "$MONITORING_NS" | grep -q "^loki"; then
    warn "Loki đã cài. Upgrade..."
    helm upgrade loki grafana/loki \
        --namespace "$MONITORING_NS" \
        --values /tmp/loki-values.yaml \
        --timeout 5m --wait
else
    info "Cài Loki..."
    helm install loki grafana/loki \
        --namespace "$MONITORING_NS" \
        --values /tmp/loki-values.yaml \
        --timeout 5m --wait
fi

success "Loki installed"

# ============================================================
step "PHASE 3 — Cài Grafana Alloy (thay thế Promtail)"
# ============================================================
# Alloy là thế hệ mới của Promtail — thu thập logs + metrics + traces
cat > /tmp/alloy-values.yaml << 'EOF'
alloy:
  configMap:
    create: true
    content: |-
      // ── Thu thập logs từ tất cả pods ─────────────────────
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "node"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
          separator     = "/"
          target_label  = "__path__"
          replacement   = "/var/log/pods/*$1/*.log"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }

      // ── Ghi log về Loki ───────────────────────────────────
      loki.write "default" {
        endpoint {
          url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
        }
      }

  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

# Tolerations để chạy trên tất cả nodes kể cả master
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule

controller:
  type: daemonset
EOF

# Xóa promtail cũ nếu đã cài
if helm list -n "$MONITORING_NS" | grep -q "^promtail"; then
    warn "Xóa Promtail cũ (deprecated)..."
    helm uninstall promtail --namespace "$MONITORING_NS"
fi

if helm list -n "$MONITORING_NS" | grep -q "^alloy"; then
    warn "Alloy đã cài. Upgrade..."
    helm upgrade alloy grafana/alloy \
        --namespace "$MONITORING_NS" \
        --values /tmp/alloy-values.yaml \
        --timeout 3m --wait
else
    info "Cài Grafana Alloy (DaemonSet trên tất cả nodes)..."
    helm install alloy grafana/alloy \
        --namespace "$MONITORING_NS" \
        --values /tmp/alloy-values.yaml \
        --timeout 3m --wait
fi

success "Grafana Alloy installed"

# ============================================================
step "PHASE 4 — Thêm Loki datasource vào Grafana"
# ============================================================
# Grafana sidecar tự động pick up ConfigMap có label grafana_datasource=1
cat > /tmp/loki-datasource.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki-gateway.monitoring.svc.cluster.local
        access: proxy
        isDefault: false
        jsonData:
          maxLines: 1000
          timeout: 60
EOF

kubectl apply -f /tmp/loki-datasource.yaml
success "Loki datasource ConfigMap created"

# Sidecar tự động detect ConfigMap mới và reload datasource — không cần restart Grafana
info "Đợi sidecar load Loki datasource (30s)..."
sleep 30
success "Loki datasource sẽ tự động xuất hiện trong Grafana"

# ============================================================
step "PHASE 5 — Kiểm tra"
# ============================================================
echo ""
info "Pods trong namespace $MONITORING_NS:"
kubectl get pods -n "$MONITORING_NS"

echo ""
info "Kiểm tra Loki health..."
LOKI_POD=$(kubectl get pod -n "$MONITORING_NS" -l "app.kubernetes.io/name=loki" \
    --no-headers -o custom-columns=":metadata.name" | head -1)
if [[ -n "$LOKI_POD" ]]; then
    if kubectl exec -n "$MONITORING_NS" "$LOKI_POD" -- \
        wget -qO- http://localhost:3100/ready 2>/dev/null | grep -q "ready"; then
        success "Loki is ready"
    else
        warn "Loki chưa ready, đợi thêm vài giây"
    fi
fi

echo ""
info "Promtail DaemonSet:"
kubectl get daemonset -n "$MONITORING_NS" -l "app.kubernetes.io/name=promtail"

# ============================================================
step "TỔNG KẾT"
# ============================================================
GRAFANA_IP=$(kubectl get svc -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=grafana" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  PLG Stack HOÀN THÀNH                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Flow:${NC} Pods → Promtail → Loki → Grafana"
echo ""

if [[ -n "$GRAFANA_IP" ]]; then
    echo -e "  Grafana: ${CYAN}http://${GRAFANA_IP}${NC}"
fi

echo ""
echo -e "${YELLOW}Xem logs trong Grafana:${NC}"
echo -e "  1. Vào Grafana → Explore (biểu tượng la bàn)"
echo -e "  2. Chọn datasource: ${CYAN}Loki${NC}"
echo -e "  3. Dùng LogQL để query:"
echo -e "     ${CYAN}{namespace=\"kube-system\"}${NC}              ← logs namespace kube-system"
echo -e "     ${CYAN}{namespace=\"monitoring\"}${NC}               ← logs namespace monitoring"
echo -e "     ${CYAN}{pod=~\"cilium.*\"}${NC}                      ← logs Cilium"
echo -e "     ${CYAN}{namespace=\"default\"} |= \"error\"${NC}       ← filter từ 'error'"
echo ""
echo -e "${YELLOW}Lưu ý:${NC} Data mất khi pod restart (chưa có Ceph)."
