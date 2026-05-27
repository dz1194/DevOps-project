#!/usr/bin/env bash
# ============================================================
# 01-prepare.sh — Chạy trên TẤT CẢ nodes (master + workers)
# Ubuntu 22.04 / 24.04
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

# ── Detect OS ────────────────────────────────────────────────
. /etc/os-release
[[ "$ID" != "ubuntu" ]] && error "Script chỉ hỗ trợ Ubuntu. OS hiện tại: $ID"
info "Detected: Ubuntu $VERSION_ID"

# ============================================================
step "PHASE 1 — System update & packages"
# ============================================================
apt-get update -qq
apt-get install -y --no-install-recommends \
    curl wget git vim ca-certificates gnupg apt-transport-https \
    net-tools iputils-ping iotop htop \
    socat conntrack ipset \
    open-iscsi nfs-common \
    lvm2 jq
success "System packages installed"

# ============================================================
step "PHASE 2 — Disable swap"
# ============================================================
swapoff -a
# Xóa swap khỏi fstab (comment dòng swap)
sed -i '/\bswap\b/s/^/#/' /etc/fstab
# Disable systemd swap nếu có
if systemctl is-active --quiet swap.target 2>/dev/null; then
    systemctl mask swap.target
fi
info "Swap status: $(swapon --show | wc -l) entries (phải = 0)"
success "Swap disabled"

# ============================================================
step "PHASE 3 — Kernel modules"
# ============================================================
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
rbd
EOF

modprobe overlay
modprobe br_netfilter
# rbd có thể không có trên Ubuntu vanilla — bỏ qua nếu lỗi
modprobe rbd 2>/dev/null || warn "rbd module không có, sẽ load sau khi cài Ceph"

success "Kernel modules loaded"

# ============================================================
step "PHASE 4 — Sysctl (networking)"
# ============================================================
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Cilium requirements
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF

sysctl --system -q
success "Sysctl applied"

# ============================================================
step "PHASE 5 — Cài containerd"
# ============================================================
# Gỡ docker cũ nếu có
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Thêm Docker GPG key + repo
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y containerd.io

# Config containerd — bật SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
success "containerd installed & configured"

# ============================================================
step "PHASE 6 — Cài kubeadm / kubelet / kubectl"
# ============================================================
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
success "kubeadm $(kubeadm version -o short) installed"

# ============================================================
step "PHASE 7 — /etc/hosts"
# ============================================================
# Xóa entries cũ nếu có, thêm mới
sed -i "/$MASTER_HOSTNAME/d;/$WORKER1_HOSTNAME/d;/$WORKER2_HOSTNAME/d" /etc/hosts
cat >> /etc/hosts << EOF

# K8s Cluster
$MASTER_IP   $MASTER_HOSTNAME
$WORKER1_IP  $WORKER1_HOSTNAME
$WORKER2_IP  $WORKER2_HOSTNAME
EOF
success "/etc/hosts updated"

# ============================================================
echo -e "\n${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  01-prepare.sh HOÀN THÀNH            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Bước tiếp theo:"
echo -e "  Master : ${YELLOW}sudo bash 02-master.sh${NC}"
echo -e "  Workers: ${YELLOW}sudo bash 03-worker.sh${NC}  (sau khi master xong)"
