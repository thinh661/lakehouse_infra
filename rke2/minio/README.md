# MinIO cho RKE2 Lakehouse

Hướng dẫn cài đặt và vận hành MinIO (standalone) trên cụm RKE2 lakehouse thông qua GitOps ArgoCD.

MinIO đóng vai trò object storage S3-compatible, làm nơi lưu **Spark Event Logs** cho Spark History Server và là nền tảng lưu trữ dữ liệu cho toàn bộ lakehouse stack.

---

## Mục lục

1. [Yêu cầu tiên quyết](#1-yêu-cầu-tiên-quyết)
2. [Cấu trúc thư mục](#2-cấu-trúc-thư-mục)
3. [Vendor Helm Chart](#3-vendor-helm-chart)
4. [Tạo Kubernetes Secret cho Credentials](#4-tạo-kubernetes-secret-cho-credentials)
5. [Triển khai bằng ArgoCD](#5-triển-khai-bằng-argocd)
6. [Xác minh triển khai](#6-xác-minh-triển-khai)
7. [Truy cập MinIO Console](#7-truy-cập-minio-console)
8. [Tích hợp Spark Event Logs](#8-tích-hợp-spark-event-logs)
9. [Vận hành và bảo trì](#9-vận-hành-và-bảo-trì)
10. [Xử lý sự cố](#10-xử-lý-sự-cố)

---

## 1. Yêu cầu tiên quyết

Đảm bảo các thành phần sau đã được cài đặt và hoạt động trong cụm:

| Thành phần | Trạng thái yêu cầu |
|---|---|
| RKE2 Cluster (`v1.36.1+rke2r2`) | ✅ Phải đang chạy |
| ArgoCD | ✅ Phải đang chạy |
| cert-manager + ClusterIssuer `lakehouse-ca` | ✅ Phải đang chạy |
| Longhorn StorageClass `longhorn` | ✅ Phải đang chạy |
| Traefik Ingress Controller | ✅ Mặc định của RKE2 |

**DNS/hosts:** Thêm entry sau vào file `/etc/hosts` trên máy client (hoặc cấu hình DNS nội bộ):

```
192.168.49.144  minio.lakehouse.local
```

---

## 2. Cấu trúc thư mục

```
rke2/minio/
├── .clinerules                   # Skill rules cho AI context
├── README.md                     # File này
├── minio_design.md               # Tài liệu thiết kế kiến trúc
├── argocd-application.yaml       # ArgoCD Application manifest
├── values-production.yaml        # Helm values cho production
├── minio.default-values.yaml     # Default values gốc (đối chiếu, không deploy)
├── charts/
│   └── minio-5.4.0/              # Helm chart đã vendor
└── manifests/
    └── minio-s3-api-ingress.yaml # (tùy chọn) Ingress cho S3 API nếu cần expose
```

---

## 3. Vendor Helm Chart

> **Lưu ý:** Bước này phải thực hiện trên máy có kết nối Internet, **trước** khi apply ArgoCD Application vào cluster.

### 3.1. Pull chart từ repo chính thống MinIO

```bash
# Trên máy có Internet (không phải trong cluster)

# Thêm repo chính thống MinIO (không phải Bitnami)
helm repo add minio https://charts.min.io/
helm repo update

# Kiểm tra phiên bản
helm search repo minio/minio --versions | head -5

# Pull và giải nén chart version 5.4.0 vào thư mục charts/
helm pull minio/minio --version 5.4.0 --untar --untardir rke2/minio/charts/

# Lưu default values để đối chiếu (không dùng để deploy)
helm show values minio/minio --version 5.4.0 > rke2/minio/minio.default-values.yaml

# Kiểm tra cấu trúc chart
ls -la rke2/minio/charts/minio-5.4.0/
```

### 3.2. Commit chart vào Git

```bash
git add rke2/minio/charts/minio-5.4.0/
git add rke2/minio/minio.default-values.yaml
git commit -m "feat(minio): vendor minio helm chart v5.4.0 (official minio/minio, not bitnami)"
git push origin main
```

### 3.3. Preload container images (môi trường offline)

Nếu cluster không có Internet, preload images lên các node RKE2 trước khi sync:

```bash
# Images cần chuẩn bị
# quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
# quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z

# Trên máy có Internet:
docker pull quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
docker save quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z | gzip > minio.tar.gz

docker pull quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z
docker save quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z | gzip > minio-mc.tar.gz

# Copy lên từng RKE2 node và load:
# scp minio.tar.gz rke2_server_1:/tmp/
# ssh rke2_server_1 "sudo ctr images import /tmp/minio.tar.gz"
# (lặp lại cho minio-mc.tar.gz và các node khác)
```

---

## 4. Tạo Kubernetes Secret cho Credentials

> **QUAN TRỌNG:** Phải tạo Secret này trên cluster **trước** khi apply ArgoCD Application. MinIO sẽ không start nếu thiếu Secret.

```bash
# Kết nối vào Bastion hoặc dùng kubeconfig

# Tạo namespace minio trước (ArgoCD sẽ tạo lại nếu chưa có, nhưng Secret cần namespace tồn tại)
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

# Tạo Secret chứa credentials MinIO
# Thay <your-admin-password> bằng password mạnh (ít nhất 8 ký tự)
kubectl create secret generic minio-credentials \
  --namespace minio \
  --from-literal=rootUser=minioadmin \
  --from-literal=rootPassword=123123123

# Xác minh Secret đã tạo
kubectl get secret minio-credentials -n minio
kubectl describe secret minio-credentials -n minio
```

> **Lưu ý bảo mật:** Không commit password vào Git. Secret chỉ tồn tại trên cluster. Nếu cluster bị rebuild, phải tạo lại Secret thủ công.

---

## 5. Triển khai bằng ArgoCD

### 5.1. Apply ArgoCD Application

Sau khi đã vendor chart và commit vào Git, và đã tạo Secret:

```bash
# Apply ArgoCD Application manifest
kubectl apply -f rke2/minio/argocd-application.yaml

# Hoặc apply trực tiếp từ Git (nếu đã dùng App of Apps pattern)
```

### 5.2. Theo dõi quá trình sync

```bash
# Xem trạng thái sync trong ArgoCD
argocd app get minio
argocd app sync minio  # nếu cần trigger sync thủ công

# Xem logs của ArgoCD
kubectl logs -n argocd deployment/argocd-application-controller -f

# Xem pods trong namespace minio
kubectl get pods -n minio -w

# Xem tất cả resources
kubectl get all -n minio
```

### 5.3. Kiểm tra tiến trình tạo bucket

Chart MinIO tạo bucket `spark-events` qua một Kubernetes Job sau khi pod chính sẵn sàng:

```bash
# Xem Job tạo bucket
kubectl get jobs -n minio
kubectl logs -n minio job/minio-make-bucket-job

# Nếu job lỗi, xem chi tiết
kubectl describe job minio-make-bucket-job -n minio
```

---

## 6. Xác minh triển khai

```bash
# 1. Kiểm tra pod MinIO chạy thành công
kubectl get pod -n minio
# Mong đợi: minio-0 (hoặc minio-<hash>) ở trạng thái Running 1/1

# 2. Kiểm tra PVC đã bound
kubectl get pvc -n minio
# Mong đợi: minio (hoặc export-minio-0) Bound với 20Gi

# 3. Kiểm tra Service
kubectl get svc -n minio
# Mong đợi: minio (port 9000) và minio-console (port 9001) type ClusterIP

# 4. Kiểm tra Ingress
kubectl get ingress -n minio
# Mong đợi: minio (host: minio.lakehouse.local)

# 5. Kiểm tra TLS Certificate
kubectl get certificate -n minio
# Mong đợi: minio-console-tls READY=True

# 6. Kiểm tra bucket đã được tạo bằng mc client
kubectl run minio-test --rm -it --image=quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z \
  --restart=Never -n minio -- \
  sh -c "mc alias set local http://minio.minio.svc.cluster.local:9000 minioadmin <password> && mc ls local/"
```

---

## 7. Truy cập MinIO Console

1. Mở browser và truy cập: `https://minio.lakehouse.local`
2. Đăng nhập với credentials đã tạo trong Secret:
   - **Username:** `minioadmin` (giá trị `rootUser` trong Secret)
   - **Password:** `<your-admin-password>` (giá trị `rootPassword` trong Secret)
3. Xác minh bucket `spark-events` đã tồn tại trong giao diện.

> **Nếu gặp lỗi SSL:** Import CA certificate của `lakehouse-ca` vào browser. Lấy CA cert bằng:
> ```bash
> kubectl get secret -n cert-manager lakehouse-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > lakehouse-ca.crt
> ```
> Sau đó import `lakehouse-ca.crt` vào Trusted Root CAs của OS/browser.

---

## 8. Tích hợp Spark Event Logs

### 8.1. Cấu hình SparkApplication ghi logs vào MinIO

Trong file `SparkApplication` YAML, thêm cấu hình Spark properties:

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: my-spark-job
  namespace: spark-operator
spec:
  # ... các cấu hình khác ...
  sparkConf:
    # Bật event log
    "spark.eventLog.enabled": "true"
    "spark.eventLog.dir": "s3a://spark-events/"
    # Cấu hình S3A connector trỏ về MinIO
    "spark.hadoop.fs.s3a.endpoint": "http://minio.minio.svc.cluster.local:9000"
    "spark.hadoop.fs.s3a.access.key": "minioadmin"
    "spark.hadoop.fs.s3a.secret.key": "<your-admin-password>"
    "spark.hadoop.fs.s3a.path.style.access": "true"
    "spark.hadoop.fs.s3a.impl": "org.apache.hadoop.fs.s3a.S3AFileSystem"
    "spark.hadoop.fs.s3a.aws.credentials.provider": "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider"
    # Tối ưu hiệu năng ghi log
    "spark.hadoop.fs.s3a.committer.name": "directory"
    "spark.hadoop.fs.s3a.fast.upload": "true"
```

> **Bảo mật nâng cao:** Thay vì hardcode credentials trong SparkApplication, nên lưu vào Kubernetes Secret và reference qua `envFrom` trong driver/executor spec. Xem phần Spark Operator documentation.

### 8.2. Cấu hình Spark Connect Server (`spark-sc-dev`)

Cập nhật manifest `spark-sc-dev.yaml` trong `rke2/spark_operator/manifests/` để bổ sung sparkConf event log:

```yaml
sparkConf:
  "spark.eventLog.enabled": "true"
  "spark.eventLog.dir": "s3a://spark-events/"
  "spark.hadoop.fs.s3a.endpoint": "http://minio.minio.svc.cluster.local:9000"
  # ... (các config S3A như trên)
```

### 8.3. Spark History Server (bước tiếp theo)

Sau khi MinIO chạy ổn định và có event logs, cài đặt Spark History Server với cấu hình:

```yaml
# spark-history-server configuration
SPARK_HISTORY_OPTS: >-
  -Dspark.history.fs.logDirectory=s3a://spark-events/
  -Dspark.hadoop.fs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000
  -Dspark.hadoop.fs.s3a.access.key=minioadmin
  -Dspark.hadoop.fs.s3a.secret.key=<password>
  -Dspark.hadoop.fs.s3a.path.style.access=true
```

---

## 9. Vận hành và bảo trì

### 9.1. Tạo bucket mới bằng mc client

```bash
# Port-forward MinIO Service để dùng mc từ local
kubectl port-forward svc/minio -n minio 9000:9000 &

# Cấu hình mc alias
mc alias set lakehouse http://localhost:9000 minioadmin <password>

# Tạo bucket mới
mc mb lakehouse/airflow-logs
mc mb lakehouse/iceberg-warehouse

# Kiểm tra
mc ls lakehouse/
```

### 9.2. Xem disk usage

```bash
# Xem dung lượng bucket
mc du lakehouse/spark-events

# Xem PVC usage trong cluster
kubectl exec -n minio minio-0 -- df -h /export
```

### 9.3. Xóa event logs cũ (retention)

```bash
# Xóa logs cũ hơn 30 ngày trong bucket spark-events
mc rm --recursive --force --older-than 30d lakehouse/spark-events/
```

### 9.4. Upgrade MinIO

```bash
# 1. Pull chart version mới
helm pull minio/minio --version <new-version> --untar --untardir rke2/minio/charts/

# 2. Cập nhật values-production.yaml nếu có thay đổi API
# 3. Kiểm tra default values mới
helm show values minio/minio --version <new-version> > rke2/minio/minio.default-values.yaml

# 4. Cập nhật argocd-application.yaml: path: rke2/minio/charts/minio-<new-version>

# 5. Commit và push -> ArgoCD tự sync
```

### 9.5. Backup bucket

```bash
# Backup toàn bộ bucket spark-events ra file tar
mc mirror lakehouse/spark-events /backup/minio/spark-events/

# Hoặc dùng rclone để backup định kỳ
# rclone copy minio:spark-events /backup/spark-events/
```

---

## 10. Xử lý sự cố

### MinIO pod không start

```bash
kubectl describe pod -n minio minio-0
kubectl logs -n minio minio-0

# Lỗi thường gặp:
# 1. "Error from server: secret minio-credentials not found"
#    -> Tạo Secret như ở bước 4

# 2. "PVC not found or not bound"
#    -> Kiểm tra StorageClass longhorn
#    kubectl get storageclass
#    kubectl describe pvc -n minio

# 3. "rootPassword too short"
#    -> Password phải >= 8 ký tự
```

### Bucket spark-events không được tạo

```bash
# Xem logs của job tạo bucket
kubectl logs -n minio job/minio-make-bucket-job

# Nếu job đã hoàn thành nhưng bucket không tồn tại, tạo thủ công:
kubectl run mc-create-bucket --rm -it \
  --image=quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z \
  --restart=Never -n minio -- \
  sh -c "mc alias set local http://minio.minio.svc.cluster.local:9000 minioadmin <password> && mc mb local/spark-events && mc ls local/"
```

### Spark không ghi được logs vào MinIO

```bash
# 1. Kiểm tra MinIO service DNS resolution từ Spark pod namespace
kubectl run dns-test --rm -it --image=busybox --restart=Never -n spark-operator -- \
  nslookup minio.minio.svc.cluster.local

# 2. Test kết nối HTTP
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -n spark-operator -- \
  curl -v http://minio.minio.svc.cluster.local:9000/minio/health/live

# 3. Kiểm tra credentials Spark đúng với credentials MinIO
# 4. Đảm bảo bucket spark-events tồn tại
# 5. Đảm bảo spark.hadoop.fs.s3a.path.style.access=true (bắt buộc với MinIO)
```

### ArgoCD sync thất bại

```bash
# Xem chi tiết lỗi
argocd app get minio --show-operation

# Nếu lỗi do Secret không tồn tại khi Helm render:
# -> Tạo Secret trước, sau đó retry sync
argocd app sync minio --retry-limit 3
```

### TLS Certificate không được cấp

```bash
# Kiểm tra Certificate và CertificateRequest
kubectl get certificate -n minio
kubectl describe certificate minio-console-tls -n minio
kubectl get certificaterequest -n minio

# Kiểm tra ClusterIssuer lakehouse-ca
kubectl get clusterissuer lakehouse-ca
kubectl describe clusterissuer lakehouse-ca
```
