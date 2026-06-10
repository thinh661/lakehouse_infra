# Hướng dẫn Cài đặt và Vận hành Spark Operator bằng ArgoCD

Thư mục này chứa tài liệu và manifest GitOps để triển khai **Spark Operator** quản trị các ứng dụng Apache Spark trên cụm RKE2 HA lakehouse, tích hợp với **cert-manager** để quản lý certificate webhook và **Volcano Batch Scheduler** để tối ưu hóa việc phân bổ tài nguyên.

Phiên bản mục tiêu:
```text
Spark Operator: v2.4.0 (Kubeflow community)
Helm chart: vendored in Git at rke2/spark_operator/charts/spark-operator-v2.4.0
Namespace: spark-operator
GitOps owner: ArgoCD
```

---

## 1. Nguyên tắc triển khai và Thứ tự cài đặt

Spark Operator là thành phần cấp phát và quản trị các cụm Spark Driver/Executors động theo công việc (Workload). Để vận hành trơn chu trong hệ thống Data Platform, Spark Operator được tích hợp với 2 dịch vụ nền tảng:
1.  **cert-manager:** Dùng để tự động tạo và gia hạn chứng chỉ TLS cho API Webhook của Spark Operator.
2.  **Volcano Scheduler:** Dùng làm scheduler điều phối tài nguyên cho các Pod Spark (Gang Scheduling) tránh hiện tượng treo cụm khi chạy đồng thời nhiều job.

**Thứ tự triển khai khuyến nghị:**
```text
RKE2 HA -> ArgoCD -> cert-manager -> Longhorn -> Keycloak -> Volcano -> Spark Operator -> JupyterHub & Airflow
```
*Lưu ý quan trọng:* **Nên cài Volcano trước Spark Operator**. Nếu cài Spark Operator trước, hệ thống vẫn khởi động thành công nhờ có sẵn cấu hình sẵn sàng tích hợp, nhưng khi bạn chạy thử job SparkApplication có cấu hình Volcano, các Pod Spark sẽ ở trạng thái `Pending` cho đến khi cụm Volcano được deploy hoàn tất.

---

## 2. Cấu trúc thư mục của Module

```text
rke2/spark_operator/
  ├── .clinerules
  ├── README.md
  ├── spark_operator_design.md
  ├── values-production.yaml
  ├── spark-operator.default-values.yaml
  ├── argocd-application.yaml
  └── charts/
      └── spark-operator-v2.4.0/
```

Vai trò các file:
*   [values-production.yaml](values-production.yaml): Cấu hình production Helm values cho Spark Operator (tích hợp cert-manager, bật tích hợp Volcano làm scheduler mặc định, phân quyền multi-namespace).
*   [spark-operator.default-values.yaml](spark-operator.default-values.yaml): Default values gốc từ Helm chart để đối chiếu.
*   [argocd-application.yaml](argocd-application.yaml): Manifest của ArgoCD Application để đồng bộ cụm qua GitOps.
*   `charts/spark-operator-v2.4.0/`: Thư mục Helm chart đã được vendor sẵn trong Git repo.

---

## 3. Chuẩn bị trên Bastion

SSH vào Bastion node:
```bash
ssh thinh1@192.168.49.144
```

Kiểm tra trạng thái sẵn sàng của cert-manager:
```bash
kubectl get clusterissuer lakehouse-ca
```

Đồng bộ repo code từ máy Windows lên Bastion (chạy từ máy Windows):
```powershell
scp -r d:\workspace_thinh1\lakehouse_infra\lakehouse_infra\rke2 thinh1@192.168.49.144:~/
```

---

## 4. Chuẩn bị Image cho Môi trường Offline (Air-gapped)

Đối với cụm RKE2 chạy offline không thể kết nối Internet để kéo Docker images, bạn phải tải trước các container images cần thiết trên máy có mạng, đóng gói và nạp vào các RKE2 node.

Image cần thiết cho Spark Operator v2.4.0:
```text
ghcr.io/kubeflow/spark-operator/controller:v2.4.0
```
*(Nếu sau này chạy Spark Application mẫu, bạn cần chuẩn bị thêm Spark base image, ví dụ: `docker.io/apache/spark:3.5.0`)*

Thực hiện đóng gói trên máy có Internet:
```bash
docker pull ghcr.io/kubeflow/spark-operator/controller:v2.4.0
docker pull docker.io/apache/spark:3.5.0

docker save \
  ghcr.io/kubeflow/spark-operator/controller:v2.4.0 \
  docker.io/apache/spark:3.5.0 \
  -o spark-operator-offline.tar
```

Copy tệp `.tar` lên tất cả các RKE2 node (`192.168.49.141`, `192.168.49.142`, `192.168.49.143`) và đặt vào thư mục tự động import của RKE2:
```bash
sudo mkdir -p /var/lib/rancher/rke2/agent/images/
sudo cp spark-operator-offline.tar /var/lib/rancher/rke2/agent/images/
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
      path: rke2/spark_operator/charts/spark-operator-v2.4.0
      ...
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Thay bằng URL repo của bạn
      targetRevision: main
      ref: values
```

Hãy commit và push thay đổi lên Git repo trước khi thực hiện bước tiếp theo.

---

## 6. Cài đặt Spark Operator qua ArgoCD

Apply file cấu hình ứng dụng từ Bastion node:
```bash
cd ~/rke2/spark_operator
kubectl apply -f argocd-application.yaml
```

ArgoCD sẽ tự động:
1.  Tạo namespace `spark-operator`.
2.  Tạo và gán Certificate Webhook cho cert-manager sử dụng ClusterIssuer `lakehouse-ca`.
3.  Cài đặt CRDs cần thiết của Spark (như `sparkapplications.sparkoperator.k8s.io`).
4.  Khởi chạy Spark Operator Controller và Webhook Server.

Theo dõi tiến trình triển khai:
```bash
# Theo dõi ứng dụng qua ArgoCD CLI
kubectl get application spark-operator -n argocd

# Xem trạng thái các Pod
kubectl get pods -n spark-operator -w
```
Khi trạng thái Pod chuyển sang `Running` và ArgoCD báo `Synced`/`Healthy`, hệ thống đã sẵn sàng.

---

## 7. Chạy thử Spark Application với Volcano Scheduler

Sau khi cài đặt xong cả **Volcano** và **Spark Operator**, bạn có thể chạy thử một ứng dụng tính toán Spark mẫu để kiểm tra tính năng Gang Scheduling.

#### Bước 1: Khởi tạo file manifest SparkApplication mẫu
Tạo file `spark-pi.yaml` tại Bastion node:

```yaml
apiVersion: "sparkoperator.k8s.io/v1beta2"
kind: SparkApplication
metadata:
  name: spark-pi
  namespace: spark-operator
spec:
  type: Scala
  mode: cluster
  image: "docker.io/apache/spark:3.5.0"
  imagePullPolicy: IfNotPresent
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: "local:///opt/spark/examples/jars/spark-examples_2.12-3.5.0.jar"
  sparkVersion: "3.5.0"
  # Tích hợp Volcano Scheduler
  batchScheduler: "volcano"
  driver:
    cores: 1
    coreLimit: "1200m"
    memory: "512m"
    labels:
      version: 3.5.0
    serviceAccount: spark-service-account # Được tạo sẵn tự động bởi Helm chart
  executor:
    cores: 1
    instances: 2
    memory: "512m"
    labels:
      version: 3.5.0
```

#### Bước 2: Deploy và theo dõi
Chạy thử Job Spark:
```bash
kubectl apply -f spark-pi.yaml
```

Kiểm tra trạng thái Spark Application:
```bash
kubectl get sparkapplication -n spark-operator
```

Theo dõi quá trình khởi chạy Pod (Driver chạy trước, sau đó gọi 2 Executor):
```bash
kubectl get pods -n spark-operator -l spark-role=driver
kubectl get pods -n spark-operator -w
```

Xem kết quả log tính toán số Pi từ Driver Pod:
```bash
kubectl logs -n spark-operator spark-pi-driver --tail=100
```
*(Nếu tính toán thành công, bạn sẽ thấy dòng chữ: `Pi is roughly 3.1415...` trong logs).*

Xóa Job sau khi hoàn thành:
```bash
kubectl delete -f spark-pi.yaml
```

---

## 8. Vận hành và Xử lý sự cố

### 8.1. Kiểm tra logs của Operator
Khi Job Spark không khởi chạy hoặc bị lỗi submit:
```bash
kubectl logs -n spark-operator deployment/spark-operator --tail=200
```

### 8.2. Lỗi Webhook Certificate
Nếu gặp lỗi `Internal error occurred: failed calling webhook...`:
1.  Kiểm tra xem cert-manager đã cấp chứng chỉ thành công chưa:
    ```bash
    kubectl get certificate -n spark-operator
    kubectl describe certificate spark-operator-webhook-cert -n spark-operator
    ```
2.  Kiểm tra xem Pod webhook của spark-operator có đang chạy không:
    ```bash
    kubectl get pods -n spark-operator -l app.kubernetes.io/name=spark-operator
    ```

### 8.3. Lỗi Job Spark treo ở trạng thái Pending vô hạn (Volcano Scheduler)
Nếu bạn đặt `batchScheduler: "volcano"` nhưng Pod Driver không được tạo hoặc ở trạng thái `Pending`:
1.  Kiểm tra xem Volcano đã được cài đặt và đang chạy bình thường chưa:
    ```bash
    kubectl get pods -n volcano -A
    ```
2.  Kiểm tra sự kiện lỗi (Events) trên cụm:
    ```bash
    kubectl describe podGroup spark-pi -n spark-operator
    kubectl get event -n spark-operator --sort-by='.metadata.creationTimestamp'
    ```
