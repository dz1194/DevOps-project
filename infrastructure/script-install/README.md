# K8s Cluster Install Scripts
## Stack: Kubernetes + Cilium CNI + MetalLB

### Cluster:
- 1 Master:   192.168.100.101
- 1 Worker-1: 192.168.100.102
- 1 Worker-2: 192.168.100.103

---

## Thứ tự chạy

### Bước 1 — Cấu hình (đọc trước)
Mở `config.env`, kiểm tra IPs và versions phù hợp với môi trường của bạn.

### Bước 2 — Chạy trên TẤT CẢ 3 nodes (song song)
```bash
sudo bash 01-prepare.sh
```

### Bước 3 — Chạy trên MASTER
```bash
sudo bash 02-master.sh
```
Script này sẽ:
- `kubeadm init` → khởi tạo control plane
- Cài **Cilium** thay thế kube-proxy
- Cài **MetalLB** + cấu hình IP pool
- Tạo file `/tmp/k8s-join.sh`

### Bước 4 — Copy join command sang workers
```bash
# Chạy trên từng worker
scp root@192.168.100.101:/tmp/k8s-join.sh /tmp/k8s-join.sh
```

### Bước 5 — Chạy trên TỪNG WORKER
```bash
sudo bash 03-worker.sh
```

### Bước 6 — Kiểm tra toàn bộ cluster (trên master)
```bash
sudo bash 04-verify.sh
```

---

## Cấu hình mặc định

| Thành phần | Giá trị |
|---|---|
| Kubernetes | v1.31 |
| Cilium | v1.16.4 |
| MetalLB | v0.14.8 |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| MetalLB IP range | 192.168.100.200 – 192.168.100.220 |
