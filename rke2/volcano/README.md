# Hướng dẫn Cài đặt và Vận hành Volcano Scheduler bằng ArgoCD

Thư mục này chứa tài liệu và manifest GitOps để triển khai **Volcano Batch Scheduler** và **Volcano Dashboard (UI)** trên cụm RKE2 HA lakehouse, làm nền tảng lên lịch điều phối tài nguyên cho Spark Operator, JupyterHub và các tác vụ Big Data/AI khác.

Phiên bản mục tiêu:
```text
Volcano Scheduler: v1.15.0
Volcano Dashboard: latest
Helm chart: vendored in Git at rke2/volcano/charts/volcano-v1.15.0
Namespace: volcano-system
GitOps owner: ArgoCD
Domain Dashboard: volcano.lakehouse.local
```

---

## 1. Nguyên tắc triển khai và Thứ tự cài đặt

Volcano đóng vai trò là bộ điều phối tài nguyên (Batch Scheduler) lớp lõi của cụm Kubernetes. Để tránh hiện tượng treo (deadlock) tài nguyên khi nhiều Driver/Executors của Spark hoặc các Pod GPU của Jupyter chạy đồng thời, Volcano cung cấp tính năng **Gang Scheduling**.

**Thứ tự triển khai khuyến nghị:**
```text
RKE2 HA -> ArgoCD -> cert-manager -> Longhorn -> Keycloak -> Volcano -> Spark Operator -> JupyterHub & Airflow
```
*Lưu ý quan trọng:* **Volcano phải được cài đặt TRƯỚC Spark Operator**. Việc này đảm bảo khi Spark Operator tạo ra các Pod gán `schedulerName: volcano` và `PodGroup`, Volcano Scheduler đã hoạt động sẵn sàng để lên lịch chạy cho các Pod đó.

---

## 2. Cấu trúc thư mục của Module

```text
rke2/volcano/
  ├── .clinerules
  ├── README.md
  ├── volcano_design.md
  ├── values-production.yaml
  ├── volcano.default-values.yaml
  ├── argocd-application.yaml
  └── manifests/
      ├── volcano-dashboard.yaml
      ├── volcano-grafana-ingress.yaml
      └── queues.yaml
```

Vai trò các file:
*   [values-production.yaml](values-production.yaml): Cấu hình production Helm values cho Volcano (image pull policy offline, cấu hình metrics, cấu hình số lượng bản sao).
*   [volcano.default-values.yaml](volcano.default-values.yaml): Default values gốc của chart để đối chiếu.
*   [argocd-application.yaml](argocd-application.yaml): Manifest của ArgoCD Application để đồng bộ cụm qua GitOps.
*   `manifests/volcano-dashboard.yaml`: Manifest của Dashboard UI, bao gồm ServiceAccount, ClusterRole/Binding (đã cấp quyền đọc Nodes), Deployment, Service và Ingress Traefik tích hợp cert-manager.
*   `manifests/volcano-grafana-ingress.yaml`: Manifest của Grafana Ingress, định nghĩa tên miền `grafana-volcano.lakehouse.local` có SSL/TLS để truy cập giao diện Grafana giám sát.
*   `manifests/queues.yaml`: Manifest định nghĩa tự động tạo hàng đợi `dev` với giới hạn tài nguyên 1 CPU, 1GiB RAM.
*   `charts/volcano-v1.15.0/`: Thư mục Helm chart đã được vendor sẵn trong Git repo.

---

## 3. Chuẩn bị trên Bastion

SSH vào Bastion node:
```bash
ssh thinh1@192.168.49.144
```

Đồng bộ repo code từ máy Windows lên Bastion (chạy từ máy Windows):
```powershell
scp -r d:\workspace_thinh1\lakehouse_infra\lakehouse_infra\rke2 thinh1@192.168.49.144:~/
```

---

## 4. Chuẩn bị Image cho Môi trường Offline (Air-gapped)

Đối với cụm RKE2 chạy offline không thể kết nối Internet để kéo Docker images, bạn phải tải trước các container images cần thiết trên máy có mạng, đóng gói và nạp vào các RKE2 node.

Các image cần thiết cho Volcano v1.15.0:
```text
docker.io/volcanosh/vc-controller-manager:v1.15.0
docker.io/volcanosh/vc-scheduler:v1.15.0
docker.io/volcanosh/vc-webhook-manager:v1.15.0
docker.io/volcanosh/vc-dashboard:latest
```

Thực hiện đóng gói trên máy có Internet:
```bash
docker pull volcanosh/vc-controller-manager:v1.15.0
docker pull volcanosh/vc-scheduler:v1.15.0
docker pull volcanosh/vc-webhook-manager:v1.15.0
docker pull volcanosh/vc-dashboard:latest

docker save \
  volcanosh/vc-controller-manager:v1.15.0 \
  volcanosh/vc-scheduler:v1.15.0 \
  volcanosh/vc-webhook-manager:v1.15.0 \
  volcanosh/vc-dashboard:latest \
  -o volcano-offline.tar
```

Copy tệp `.tar` lên tất cả các RKE2 node (`192.168.49.141`, `192.168.49.142`, `192.168.49.143`) và đặt vào thư mục tự động import của RKE2:
```bash
sudo mkdir -p /var/lib/rancher/rke2/agent/images/
sudo cp volcano-offline.tar /var/lib/rancher/rke2/agent/images/
sudo systemctl restart rke2-server   # Restart lần lượt trên từng node
```
*Lưu ý: Đối với node agent thì chạy `sudo systemctl restart rke2-agent`.*

---

## 5. Cấu hình repoURL trong ArgoCD Application

Mở tệp [argocd-application.yaml](argocd-application.yaml) và chỉnh sửa `repoURL` trỏ về địa chỉ Git repo thật của bạn:

```yaml
spec:
  sources:
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Thay bằng URL repo của bạn
      targetRevision: main
      path: rke2/volcano/charts/volcano-v1.15.0
      ...
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Thay bằng URL repo của bạn
      targetRevision: main
      ref: values
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Thay bằng URL repo của bạn
      targetRevision: main
      path: rke2/volcano/manifests
```

Hãy commit và push thay đổi lên Git repo trước khi thực hiện bước tiếp theo.

---

## 6. Cài đặt Volcano và Dashboard qua ArgoCD

Apply file cấu hình ứng dụng từ Bastion node:
```bash
cd ~/rke2/volcano
kubectl apply -f argocd-application.yaml
```

ArgoCD sẽ tự động:
1.  Tạo namespace `volcano-system`.
2.  Cài đặt toàn bộ Volcano CRDs (như `jobs.batch.volcano.sh`, `queues.scheduling.volcano.sh`, `podgroups.scheduling.volcano.sh`).
3.  Deploy core components (Scheduler, Controller, Webhook).
4.  Deploy Volcano Dashboard UI, Service và Ingress.
5.   cert-manager tự động tạo chứng chỉ SSL/TLS `volcano-dashboard-tls` cho Ingress.

Theo dõi tiến trình triển khai:
```bash
# Theo dõi ứng dụng qua ArgoCD CLI
kubectl get application volcano -n argocd

# Xem trạng thái các Pod
kubectl get pods -n volcano-system -o wide
```
Khi các Pod (`volcano-admission-*`, `volcano-controller-*`, `volcano-scheduler-*`, và `volcano-dashboard-*`) đều ở trạng thái `Running` và ArgoCD báo `Synced`/`Healthy`, hệ thống đã sẵn sàng.

---

## 7. Hướng dẫn Vận hành và Sử dụng Volcano Dashboard (UI)

### 7.1. Cấu hình File hosts (hoặc DNS nội bộ)
Đảm bảo máy client của bạn trỏ tên miền về Bastion HAProxy IP `192.168.49.144` trong file `C:\Windows\System32\drivers\etc\hosts`:
```text
192.168.49.144 volcano.lakehouse.local
```

### 7.2. Truy cập Giao diện
Mở trình duyệt Web Chrome và truy cập:
```text
https://volcano.lakehouse.local/
```
*(Trình duyệt sẽ hiển thị chứng chỉ HTTPS hợp lệ do cert-manager nội bộ cấp).*

### 7.3. Hướng dẫn các tính năng chính trên UI
Giao diện của Volcano Dashboard gồm 5 khu vực chính:

1.  **Trang tổng quan (Overview):**
    *   Hiển thị biểu đồ tròn biểu thị trạng thái các Job của hệ thống (Running, Pending, Completed, Failed).
    *   Hiển thị danh sách các Hàng đợi (Queues) và tổng số lượng PodGroup đang chạy.
2.  **Quản lý hàng đợi (Queues):**
    *   Hiển thị danh sách các Queue trong cụm. Sau khi đồng bộ qua GitOps, bạn sẽ thấy ít nhất hai queue:
        *   `default`: Queue mặc định của hệ thống.
        *   `dev`: Queue phát triển của chúng ta (đã được cấu hình tự động thông qua file `manifests/queues.yaml` với giới hạn cứng CPU: `1` và Memory: `1Gi`).
    *   Bạn có thể xem thông số của từng Queue:
        *   `Weight` (Trọng số ưu tiên tài nguyên khi có tranh chấp).
        *   `Capability` (Giới hạn tài nguyên tối đa Queue có thể tiêu thụ).
    *   *Tính năng:* Quản trị viên có thể xem trực quan thông số, cấu hình lại tài nguyên hoặc tạo mới Queue trực tiếp trên giao diện.
3.  **Quản lý Job (Volcano Jobs):**
    *   Hiển thị tất cả các Job chạy dưới dạng `vcjob` (Custom Resource của Volcano).
    *   Bạn có thể xem trạng thái chi tiết của từng Job, thời gian chạy, tài nguyên tiêu thụ.
    *   Xem danh sách các Task con bên trong Job và log của từng Pod mà không cần dùng CLI `kubectl logs`.
4.  **Quản lý PodGroup (PodGroups) - Giám sát Spark Jobs:**
    *   **Dashboard Volcano có hiển thị các job Spark không?** Có, hiển thị ở mức độ điều phối tài nguyên.
    *   Mỗi khi bạn submit một `SparkApplication` (sử dụng schedulerName `volcano`), Spark Operator sẽ tự động tạo một **PodGroup** tương ứng trong Volcano để quản lý tài nguyên cả nhóm Pod (Driver và Executors).
    *   Tại tab **PodGroups** trên Dashboard UI, bạn sẽ thấy PodGroup đại diện cho Spark Job của bạn. Bạn có thể giám sát trạng thái của nó: xem số lượng Pod tối thiểu cần để khởi chạy (`minMember`), số lượng Pod thực tế đã sẵn sàng (`running`/`ready`), trạng thái hàng đợi và Spark Job đó đang được xếp vào Queue nào (`default`, `dev`, v.v.).
5.  **Quản lý Node và Giám sát tài nguyên toàn cụm (Nodes):**
    *   **Tôi có thể xem được tài nguyên còn lại của toàn cụm k8s không?** Có, bạn có thể xem đầy đủ tại tab **Nodes**.
    *   Nhờ bổ sung quyền đọc `nodes` trong ClusterRole của Dashboard, UI sẽ hiển thị chi tiết tài nguyên của từng node vật lý trong cụm RKE2:
        *   **Capacity:** Tổng dung lượng phần cứng CPU, Memory, GPU mà node đang sở hữu.
        *   **Allocated:** Lượng tài nguyên đã được cấp phát cho các Pod đang chạy trên node.
        *   **Tài nguyên còn lại:** Giúp bạn dễ dàng tính toán xem cụm k8s của bạn còn trống bao nhiêu tài nguyên để lập kế hoạch cấp phát hoặc mở rộng node.
### 7.4. Hướng dẫn truy cập Grafana giám sát Volcano
Prometheus & Grafana đã được tích hợp sẵn bên trong Helm Chart của Volcano dưới namespace `volcano-system`. Bạn có hai cách để truy cập giao diện Grafana:

**Cách 1: Truy cập qua tên miền Ingress HTTPS (Khuyên dùng)**
Chúng tôi đã khai báo một Ingress tại [manifests/volcano-grafana-ingress.yaml](manifests/volcano-grafana-ingress.yaml). Bạn thực hiện các bước sau:
1. Thêm bản ghi DNS/hosts trên máy client (Windows):
   ```text
   192.168.49.144 grafana-volcano.lakehouse.local
   ```
2. Mở trình duyệt Web Chrome và truy cập:
   ```text
   https://grafana-volcano.lakehouse.local/
   ```
   *(Trình duyệt sẽ hiển thị chứng chỉ HTTPS hợp lệ do cert-manager nội bộ cấp tự động).*

**Cách 2: Truy cập qua NodePort của Kubernetes**
Service `grafana` trong namespace `volcano-system` được cấu hình loại `NodePort` với port lắng nghe là `30004`. Bạn có thể truy cập trực tiếp qua IP của bất kỳ node RKE2 nào trong cụm kèm theo port `30004` (không cần cấu hình DNS/hosts):
*   `http://192.168.49.141:30004` (RKE2 Server Node 1)
*   `http://192.168.49.142:30004` (RKE2 Server Node 2)
*   `http://192.168.49.143:30004` (RKE2 Server Node 3)

*Thông tin đăng nhập mặc định:*
*   **Username:** `admin`
*   **Password:** `admin` 

Sau khi vào Grafana, di chuyển đến mục **Dashboards** > **Browse** và tìm kiếm từ khóa **"Volcano"** để mở các biểu đồ hiệu năng scheduler được cấu hình sẵn.

---

## 8. Lệnh CLI Vận hành Hàng ngày

Ngoài giao diện UI, bạn có thể vận hành Volcano bằng các lệnh CLI hữu ích sau:

### 8.1. Kiểm tra danh sách các hàng đợi (Queues)
```bash
kubectl get queues.scheduling.volcano.sh
# Hoặc viết tắt
kubectl get queues
```

### 8.2. Kiểm tra các nhóm PodGroup (do Spark Operator tự sinh ra)
```bash
kubectl get podgroups.scheduling.volcano.sh -A
# Hoặc viết tắt
kubectl get pg -A
```

### 8.3. Xem cấu hình hoạt động của Scheduler
Scheduler của Volcano hoạt động dựa trên file cấu hình `volcano-scheduler.conf`. Để xem các thuật toán (plugins) nào đang được kích hoạt:
```bash
kubectl get configmaps volcano-scheduler-configmap -n volcano-system -o yaml
```
*(Bạn sẽ thấy các plugin mặc định như `gang`, `drf`, `predicates`, `binpack`, `proportion` đang hoạt động).*

---

## 9. Gỡ bỏ cài đặt (Uninstall)

Để xóa sạch Volcano và Dashboard khỏi cụm RKE2:
1.  Xóa Application khỏi ArgoCD:
    ```bash
    kubectl delete -f argocd-application.yaml
    ```
2.  Kiểm tra và xóa thủ công namespace nếu còn sót:
    ```bash
    kubectl delete namespace volcano-system
    ```
