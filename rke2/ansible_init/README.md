# Hướng dẫn Cài đặt Cụm RKE2 HA bằng Ansible

Thư mục này chứa toàn bộ mã nguồn Ansible dùng để tự động cài đặt cụm RKE2 Kubernetes đạt chuẩn High Availability (HA) trên 4 máy chủ VM Ubuntu của bạn.

## Cấu trúc thư mục hiện tại

- `inventory.ini`: Khai báo IP các node, tài khoản/mật khẩu SSH.
- `group_vars/all.yml`: Lưu trữ cấu hình dùng chung (phiên bản RKE2, token, danh sách IP,...).
- `playbooks/site.yml`: Playbook tổng để chạy toàn bộ quy trình.
- `playbooks/prereq.yml`: Chuẩn bị OS (tắt swap, kernel module, sysctl, cài socat/curl,...).
- `playbooks/haproxy.yml`: Cài đặt HAProxy trên node Bastion (`144`) làm Load Balancer.
- `playbooks/rke2-first-server.yml`: Khởi tạo và chạy RKE2 Server chính (`141`).
- `playbooks/rke2-join-servers.yml`: Cấu hình và join các Server phụ (`142`, `143`).
- `playbooks/post-install.yml`: Cài đặt `kubectl` trên Bastion và tải cấu hình kubeconfig về quản trị.

---

## Các bước chuẩn bị trước khi chạy

Bạn có thể chạy Ansible trực tiếp từ **máy tính cá nhân của bạn (qua WSL/Linux)** hoặc **từ chính node Bastion (`192.168.49.144`)**.

### Bước 1: Cài đặt Ansible & sshpass
Do file `inventory.ini` đang sử dụng phương thức xác thực bằng mật khẩu (`123123123`), máy chạy Ansible cần cài đặt thêm gói `sshpass`.

**Trên Ubuntu / Debian / WSL (Windows Subsystem for Linux):**
```bash
sudo apt update
sudo apt install -y ansible sshpass
```

### Copy project lên server 144

```bash
scp -r rke2/ thinh1@192.168.49.144:~/rke2
```

### Bước 2: Kiểm tra kết nối SSH (Ping test)
Hãy thử kiểm tra xem Ansible có kết nối và đăng nhập thành công đến các node hay không:

```bash
ansible -i inventory.ini all -m ping
```

> **Lưu ý**: Nếu gặp cảnh báo về SSH key host check, Ansible đã được cấu hình tự động bỏ qua kiểm tra này trong `inventory.ini` thông qua tham số `ansible_ssh_common_args='-o StrictHostKeyChecking=no'`.

---

## Chạy cài đặt cụm RKE2

Chạy lệnh duy nhất sau để tự động hóa toàn bộ quy trình cấu hình hệ thống, cài đặt Load Balancer, cài đặt RKE2 và cấu hình công cụ quản trị:

```bash
ansible-playbook -i inventory.ini playbooks/site.yml
```

Quá trình này sẽ mất từ 5-10 phút tùy thuộc vào tốc độ mạng của các VM khi tải các container image của RKE2.

---

## Kiểm tra sau khi cài đặt hoàn tất

Sau khi playbook chạy thành công, hãy SSH vào node **Bastion (`192.168.49.144`)** bằng tài khoản `thinh1`:

```bash
ssh thinh1@192.168.49.144
```

Chạy lệnh sau để xem trạng thái của cụm Kubernetes:

```bashl
kubectl get nodes -o wide
```

Kết quả mong đợi sẽ hiển thị cả 3 node `192.168.49.141`, `192.168.49.142`, `192.168.49.143` ở trạng thái **Ready**:

```text
NAME            STATUS   ROLES                       AGE   VERSION
rke2-server-1   Ready    control-plane,etcd,master   5m    v1.36.1+rke2r2
rke2-server-2   Ready    control-plane,etcd,master   3m    v1.36.1+rke2r2
rke2-server-3   Ready    control-plane,etcd,master   2m    v1.36.1+rke2r2
```

Kiểm tra tất cả các pod hệ thống:

```bash
kubectl get pods -A
```

---

## Khả năng tùy biến & Tái sử dụng

Để mang bộ script này đi cài đặt cho môi trường hoặc dự án khác, bạn chỉ cần thay đổi hai file sau:

1. **`inventory.ini`**: Cập nhật lại các IP máy chủ và mật khẩu SSH tương ứng.
2. **`group_vars/all.yml`**:
   - Cập nhật `loadbalancer_ip` về IP Load Balancer mới.
   - Cập nhật danh sách IP trong mục `rke2_servers` và `tls_sans`.
   - Có thể đổi `rke2_version` sang phiên bản khác nếu mong muốn.

## Gia hạn chứng chỉ sau 1 năm 

``` sudo rke2 certificate check ```

``` sudo systemctl stop rke2-server ```

``` sudo rke2 certificate rotate ```

``` sudo systemctl start rke2-server ```

## Restart node 
``` 
sudo pkill -9 -f containerd-shim
sudo pkill -9 -f rke2
sudo pkill -9 -f containerd

sudo systemctl reset-failed rke2-server
sudo systemctl daemon-reload

sudo systemctl start rke2-server

sudo systemctl status rke2-server
```
