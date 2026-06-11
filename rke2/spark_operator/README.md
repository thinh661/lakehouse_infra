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
  ├── manifests/
  │   ├── spark-sc-dev.yaml
  │   └── spark-sc-ingress.yaml
  └── charts/
      └── spark-operator-v2.4.0/
```

Vai trò các file:
*   [values-production.yaml](values-production.yaml): Cấu hình production Helm values cho Spark Operator (tích hợp cert-manager, bật Ingress tự sinh cho Spark UI, bật tích hợp Volcano làm scheduler mặc định, phân quyền multi-namespace).
*   [spark-operator.default-values.yaml](spark-operator.default-values.yaml): Default values gốc từ Helm chart để đối chiếu.
*   [argocd-application.yaml](argocd-application.yaml): Manifest của ArgoCD Application để đồng bộ cụm qua GitOps.
*   `manifests/spark-sc-dev.yaml`: Manifest của Spark Connect Server (`spark-sc-dev`), cho phép kết nối tương tác và bật co giãn Executor động.
*   `manifests/spark-sc-ingress.yaml`: Manifest expose Ingress cho Spark Connect UI và NodePort Service cho kết nối gRPC từ bên ngoài.
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
ghcr.io/kubeflow/spark-operator/controller:2.4.0
```
*(Nếu sau này chạy Spark Application mẫu, bạn cần chuẩn bị thêm Spark base image, ví dụ: `docker.io/apache/spark:3.5.0`)*

Thực hiện đóng gói trên máy có Internet:
```bash
docker pull ghcr.io/kubeflow/spark-operator/controller:2.4.0
docker pull docker.io/apache/spark:3.5.0

docker save \
  ghcr.io/kubeflow/spark-operator/controller:2.4.0 \
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
    ```
    ```bash
    kubectl get event -n spark-operator --sort-by='.metadata.creationTimestamp'
    ```

### 8.4. Lỗi thiếu ServiceAccount trong Namespace (pods is forbidden / serviceaccount not found)
Khi submit SparkApplication, bạn sẽ gặp lỗi:
`pods "spark-pi-driver" is forbidden: error looking up service account spark-operator/spark-service-account: serviceaccount "spark-service-account" not found.`

*   **Nguyên nhân:** Khi cấu hình `spark.jobNamespaces` hỗ trợ multi-namespace (`- ""`), Helm chart của Spark Operator sẽ bỏ qua việc tự tạo ServiceAccount và các quyền RBAC tương ứng. Do đó, các namespace nơi bạn deploy job sẽ thiếu ServiceAccount `spark-service-account`.
*   **Cách xử lý:**
    1.  **Cách 1 (Khai báo qua GitOps - Khuyên dùng):** Thêm tên các namespace bạn dự kiến chạy Spark Job vào danh sách `jobNamespaces` của [values-production.yaml](values-production.yaml) (ví dụ: `"spark-operator"`, `"default"`). Khi đó Helm chart sẽ tự động tạo đầy đủ SA và RBAC cho các namespace này.
    2.  **Cách 2 (Tạo thủ công cho namespace mới):** Nếu bạn muốn chạy Spark job ở một namespace mới khác (ví dụ: `jupyter`, `airflow`), bạn hãy tạo thủ công ServiceAccount và RBAC bằng lệnh sau trên Bastion:
        ```bash
        # Thay thế <target-namespace> bằng namespace bạn chạy job (ví dụ: jupyter)
        kubectl create serviceaccount spark-service-account -n <target-namespace>
        
        # Gán quyền chạy Pod cho ServiceAccount đó
        kubectl create role spark-role --verb=get,list,watch,create,delete --resource=pods,configmaps,services,persistentvolumeclaims -n <target-namespace>
        kubectl create rolebinding spark-role-binding --role=spark-role --serviceaccount=<target-namespace>:spark-service-account -n <target-namespace>
        ```

---

## 9. Hướng dẫn Vận hành Spark Connect Server (`spark-sc-dev`)

Dịch vụ **Spark Connect** cho phép các môi trường lập trình (như JupyterHub Notebook hoặc máy Local của Developer) kết nối tương tác trực tiếp tới cụm Spark để chạy code mà không cần Jupyter/Local đóng vai trò làm Driver (chỉ cần chạy thin-client).

### 9.1. Khởi chạy Spark Connect Server
File manifest [spark-sc-dev.yaml](manifests/spark-sc-dev.yaml) định nghĩa Spark Connect Server chạy trên cụm. Để deploy:
```bash
# Spark Connect Server được ArgoCD tự động deploy nếu bạn đã bật tự động sync, hoặc bạn có thể apply thủ công:
kubectl apply -f manifests/spark-sc-dev.yaml
```
Khi chạy, Spark Connect Server sẽ hiển thị dưới dạng một pod Driver trong namespace `spark-operator` và lắng nghe cổng gRPC `15002`.

### 9.2. Cách kết nối từ JupyterHub / Môi trường Python nội bộ
Cài đặt thư viện pyspark phiên bản nhẹ (thin-client) trên môi trường phát triển:
```bash
pip install "pyspark[connect]==3.5.0"
```
Khởi tạo kết nối trong code Python/Jupyter Notebook:
```python
from pyspark.sql import SparkSession

# Kết nối trực tiếp tới Service của spark-sc-dev trong cụm Kubernetes
spark = SparkSession.builder \
    .remote("sc://spark-sc-dev-driver-svc.spark-operator.svc.cluster.local:15002") \
    .getOrCreate()

# Thực hiện truy vấn dữ liệu (Các executor sẽ tự động scale-up bởi Server)
df = spark.read.json("s3a://lakehouse-raw-bucket/data.json")
df.show()
```

### 9.3. Cách kết nối từ máy Local (Ngoài cụm RKE2)
Chúng tôi đã expose cổng gRPC `15002` của Spark Connect thông qua một Service NodePort ở cổng `30052`. 
1. Kết nối từ máy local của lập trình viên:
   ```python
   spark = SparkSession.builder \
       .remote("sc://192.168.49.144:30052") \  # IP của Bastion Load Balancer
       .getOrCreate()
   ```
2. Theo dõi giao diện Spark UI thời gian thực của Server Spark Connect tại:
   * Thêm tệp hosts trên Windows: `192.168.49.144 spark-sc-dev-ui.lakehouse.local`
   * Mở trình duyệt Web: `https://spark-sc-dev-ui.lakehouse.local`

---

## 10. Hướng dẫn sử dụng Spark UI Proxy & Tích hợp Airflow

Chúng tôi đã bật tính năng **uiIngress** cho Spark Operator Controller. Khi bất kỳ ứng dụng Spark nào (như Job batch `spark-pi`) được submit:

1.  **Tự động sinh Ingress:** Controller sẽ tự động tạo một Ingress trỏ đến Spark UI của Driver pod đó với tên miền định dạng:
    `https://<appName>-<namespace>.spark-ui.lakehouse.local`
2.  **Xem link trong log Airflow:** Khi Airflow sử dụng `SparkKubernetesOperator` để chạy Job, logs của Airflow sẽ in ra link URL Ingress này. Người dùng chỉ cần click vào link là có thể truy cập thẳng vào Spark UI để xem quá trình xử lý, DAG và logging thời gian thực.
3.  **Trace logs lịch sử (Spark History Server):**
    Sau khi Job hoàn thành, các Pod Driver và Executor sẽ bị xóa đi để giải phóng tài nguyên. Để xem lại log:
    * Mở giao diện Spark History Server (chúng tôi cấu hình đọc logs tập trung từ MinIO `s3a://spark-events-bucket/`).
    * Tại đây, bạn có thể phân tích DAG, cấu hình, và các chỉ số hiệu năng (tunning) của các Job đã kết thúc trong quá khứ.

## 11. Xóa argocd app khi bị stuck
``` kubectl patch application spark-operator -n argocd --type=merge -p '{"operation": null}' ```
``` kubectl patch application spark-operator -n argocd --type=merge -p '{"metadata":{"finalizers":null}}' ```

