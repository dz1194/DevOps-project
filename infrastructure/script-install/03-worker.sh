#!/usr/bin/env bash
# ============================================================
# 03-worker.sh — Chạy trên TỪNG WORKER NODE
# Yêu cầu: 01-prepare.sh đã chạy xong
#          File /tmp/k8s-join.sh đã được copy từ master
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Guard ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Phải chạy với quyền root: sudo bash $0"

command -v kubeadm &>/dev/null || error "kubeadm không tìm thấy. Chạy 01-prepare.sh trước."

# ============================================================
step "PHASE 1 — Kiểm tra join command"
# ============================================================

# Tìm join command theo thứ tự ưu tiên
JOIN_CMD_FILE=""
for f in /tmp/k8s-join.sh "$SCRIPT_DIR/k8s-join.sh"; do
    [[ -f "$f" ]] && JOIN_CMD_FILE="$f" && break
done

if [[ -z "$JOIN_CMD_FILE" ]]; then
    error "Không tìm thấy join command file.\n\
Cách lấy từ master:\n\
  scp root@${MASTER_IP}:${JOIN_CMD_FILE} /tmp/k8s-join.sh\n\
Hoặc paste thủ công vào /tmp/k8s-join.sh"
fi

info "Dùng join command: $JOIN_CMD_FILE"
cat "$JOIN_CMD_FILE"

# ============================================================
step "PHASE 2 — Kiểm tra kết nối đến master"
# ============================================================
info "Ping master ($MASTER_IP)..."
if ! ping -c 3 -W 2 "$MASTER_IP" &>/dev/null; then
    error "Không ping được master ($MASTER_IP). Kiểm tra network."
fi
success "Master reachable"

info "Kiểm tra port 6443 (K8s API)..."
if command -v nc &>/dev/null; then
    if nc -zw3 "$MASTER_IP" 6443 2>/dev/null; then
        success "Port 6443 open"
    else
        error "Không connect được $MASTER_IP:6443. Đảm bảo master đã init xong."
    fi
else
    warn "nc không có, bỏ qua port check"
fi

# ============================================================
step "PHASE 3 — Join cluster"
# ============================================================

# Kiểm tra đã join chưa (kubelet active = đã join)
if systemctl is-active --quiet kubelet && \
   [[ -f /etc/kubernetes/kubelet.conf ]]; then
    warn "Node này đã join cluster rồi. Bỏ qua."
else
    info "Joining cluster..."
    bash "$JOIN_CMD_FILE"
    success "Join command executed"
fi

# ============================================================
step "PHASE 4 — Verify"
# ============================================================
info "Chờ kubelet start..."
sleep 10

if systemctl is-active --quiet kubelet; then
    success "kubelet is running"
else
    error "kubelet không chạy. Kiểm tra: journalctl -xeu kubelet"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  03-worker.sh HOÀN THÀNH                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Kiểm tra trên MASTER node:${NC}"
echo -e "  ${CYAN}kubectl get nodes -o wide${NC}"
echo ""
echo -e "Worker sẽ xuất hiện với status ${YELLOW}NotReady${NC} vài giây,"
echo -e "sau đó chuyển sang ${GREEN}Ready${NC} khi Cilium agent khởi động."
