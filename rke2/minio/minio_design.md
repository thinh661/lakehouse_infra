# Tài liệu Thiết kế MinIO cho cụm RKE2 Lakehouse

Tài liệu này mô tả kiến trúc, mục tiêu triển khai, chiến lược multi-bucket và cách tích hợp **MinIO** với **Spark Operator**, **Spark Connect Server** và **Spark History Server** trên cụm **RKE2 HA** hiện tại, bao gồm thiết kế cho mở rộng đa dự án trong tương lai.

---

## 1. Mục tiêu thiết kế

Trong lakehouse, event logs của Spark cần được lưu trữ lâu dài vì:
*   **Batch jobs (SparkApplication):** Pod Driver/Executor bị xóa ngay khi job kết thúc → không còn cách xem lại Spark UI theo cách thông thường.
*   **Spark Connect Server:** Chạy vĩnh viễn, các query từ JupyterHub/local developer cần được trace sau khi thực hiện xong để debug và tối ưu.

**MinIO** đảm nhận vai trò object storage S3-compatible cho toàn bộ event logs, với thiết kế tách biệt theo loại workload.

---

## 2. Phân tích: Event Log của Spark Connect Server hoạt động như thế nào?

Đây là câu hỏi quan trọng về mặt thiết kế. Spark Connect Server là một SparkApplication **chạy vĩnh viễn** (long-running), không kết thúc như batch job.

### 2.1. Spark Connect Server và Event Log

```text
Trạng thái của log file theo vòng đời ứng dụng Spark:

[Batch Job]          [Connect Server]
  START                  START
    |                      |
  job runs             queries run liên tục (vô thời hạn)
    |                      |
   END                  (không kết thúc)
    |
  log = FINALIZED      log = IN-PROGRESS (*.inprogress)
    |                      |
  History Server       History Server VẪN ĐỌC ĐƯỢC log in-progress!
  đọc bình thường      Hiển thị là "(running)" trong UI
```

**Kết luận quan trọng:**
*   Spark History Server **hoàn toàn có thể đọc** event log của Connect Server khi nó đang chạy.
*   Log file được đặt tên `app-<timestamp>-<appId>.inprogress` trong S3 khi ứng dụng chưa kết thúc.
*   History Server tự động poll S3 định kỳ (mặc định 10s), phát hiện file `.inprogress` và hiển thị ứng dụng với trạng thái **(running)** trong UI.
*   Người dùng có thể click vào để xem **real-time DAG, stage, task metrics** của các query đang chạy trên Connect Server.
*   Sau khi Connect Server **restart** (hoặc bị Spark Operator recreate): log session cũ được **finalize** (đổi tên thành `app-<...>` không có `.inprogress`) → vẫn xem lại được bình thường trong History UI.

### 2.2. Sự khác biệt so với Live UI (port 4040)

| | Live UI (4040) | Spark History Server |
|---|---|---|
| **Phạm vi** | Real-time, chỉ xem được khi pod đang chạy | Lịch sử + real-time (in-progress) |
| **Sau khi pod xóa** | Không còn truy cập | Vẫn xem được đầy đủ |
| **Batch jobs** | Không thể xem (pod đã xóa) | ✅ Xem được toàn bộ |
| **Connect Server** | ✅ Real-time qua Ingress | ✅ Cả real-time lẫn lịch sử |
| **Truy cập** | `spark-sc-dev-ui.lakehouse.local` (Traefik Ingress) | `spark-history.lakehouse.local` (sẽ cài sau) |

---

## 3. Thiết kế 2-Bucket cho Event Logs

### 3.1. Tại sao 2 bucket thay vì 1?

**Ưu điểm tách biệt batch và connect:**
*   Spark History Server chỉ đọc được **1 path** mỗi instance.
*   Batch logs và connect server logs có vòng đời khác nhau (finalized vs. in-progress).
*   Dễ quản lý retention policy riêng (batch logs cần giữ lâu hơn; connect server logs có thể xóa sau mỗi session).
*   Khi mở rộng đa dự án, mỗi "loại" có History Server riêng đọc từ bucket tương ứng.

### 3.2. Cấu trúc bucket

```text
MinIO Storage
├── spark-events-batch/               ← SparkApplication batch jobs
│   │
│   │  (Cách tổ chức paths - do Spark tự tạo khi ghi log)
│   │
│   ├── project-a-etl-daily-app-xxx   ← log batch job project A
│   ├── project-b-ml-train-app-xxx    ← log batch job project B
│   └── airflow-spark-job-app-xxx     ← log job từ Airflow
│
└── spark-events-connect/             ← Spark Connect servers
    ├── sc-dev/                       ← Dev connect server (hiện tại)
    │   ├── app-xxx.inprogress        ← session đang chạy (in-progress)
    │   └── app-yyy                   ← session đã kết thúc (finalized)
    ├── sc-project-a/                 ← (tương lai) Connect server dự án A
    └── sc-project-b/                 ← (tương lai) Connect server dự án B
```

### 3.3. Quy ước đặt tên ứng dụng (App Naming Convention)

Để phân biệt project trong History UI, dùng convention đặt tên app:

```yaml
# Trong SparkApplication hoặc Airflow SparkKubernetesOperator:
metadata:
  name: project-a-etl-daily   # → History UI hiển thị tên này
  # hoặc
  name: project-b-ml-train
```

Trong History UI, bạn có thể filter theo `App Name` để xem riêng từng project mà không cần nhiều History Server.

---

## 4. Kiến trúc tổng thể và Spark History Server Strategy

### 4.1. Thiết kế History Server theo loại workload

```text
                           MinIO (namespace: minio)
                    ┌─────────────────────────────────┐
                    │  Bucket: spark-events-batch      │
                    │  ┌─────────────────────────────┐ │
                    │  │ project-a-etl-xxx (done)    │ │ ◄── Spark History Server [BATCH]
                    │  │ project-b-ml-xxx  (done)    │ │     s3a://spark-events-batch/
                    │  └─────────────────────────────┘ │     (đọc tất cả project)
                    │                                   │
                    │  Bucket: spark-events-connect     │
                    │  ┌─────────────────────────────┐ │
                    │  │ sc-dev/app-xxx.inprogress   │ │ ◄── Spark History Server [CONNECT]
                    │  │ sc-dev/app-yyy (finalized)  │ │     s3a://spark-events-connect/
                    │  │ sc-prj-a/... (tương lai)    │ │     (đọc TẤT CẢ connect servers)
                    │  └─────────────────────────────┘ │
                    └─────────────────────────────────┘
```

### 4.2. Cần bao nhiêu Spark History Server?

**Câu trả lời ngắn gọn: 2 History Server là đủ cho toàn bộ hệ thống, dù có bao nhiêu dự án.**

| History Server | Đọc từ path | Hiển thị |
|---|---|---|
| `spark-history-batch` | `s3a://spark-events-batch/` | TẤT CẢ batch jobs của mọi project |
| `spark-history-connect` | `s3a://spark-events-connect/` | TẤT CẢ connect servers (dev + project A, B...) |

**Lý do KHÔNG cần per-project History Server:**
*   History Server đọc từ ROOT của path → tự động thấy log của mọi app ghi vào đó.
*   Phân biệt project bằng `App Name` trong UI (filter theo tên).
*   Thêm project = thêm SparkApplication với tên khác → tự động xuất hiện trong History UI.
*   Không cần deploy thêm infrastructure.

**Trường hợp CÓ nên dùng per-project History Server:**
*   Yêu cầu **bảo mật nghiêm ngặt**: project A không được thấy log của project B.
*   Tổ chức có **compliance requirements** về data isolation.
*   Số lượng jobs quá lớn → cần phân tán tải lên nhiều History Server.

### 4.3. Spark Connect Server mở rộng đa dự án

```text
Tương lai: Thêm Connect Server cho từng dự án

sc-dev       → spark.eventLog.dir = s3a://spark-events-connect/sc-dev/
sc-project-a → spark.eventLog.dir = s3a://spark-events-connect/sc-project-a/
sc-project-b → spark.eventLog.dir = s3a://spark-events-connect/sc-project-b/

History Server [CONNECT] đọc s3a://spark-events-connect/
→ Tự động thấy TẤT CẢ connect servers trong một UI
→ Filter bằng App Name để xem riêng từng server
```

---

## 5. GitOps và Offline Model

### 5.1. Phiên bản chart

```text
Chart name:   minio (repo chính thống minio/minio, KHÔNG phải Bitnami)
Chart repo:   https://charts.min.io/
Chart version: 5.4.0
AppVersion:   RELEASE.2024-12-18T13-15-44Z
Container image: quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
MC image:     quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z
Vendored path: rke2/minio/charts/minio-5.4.0
```

### 5.2. Bucket khởi tạo tự động

Hai bucket được tạo tự động bởi Helm chart (qua `mc` Job) sau khi MinIO sẵn sàng:

| Bucket | Mục đích | Ghi bởi | Đọc bởi |
|---|---|---|---|
| `spark-events-batch` | Batch SparkApplication logs | Spark Driver pod + Airflow | Spark History Server [BATCH] |
| `spark-events-connect` | Spark Connect server logs | Connect Server driver pod | Spark History Server [CONNECT] + Live UI |

---

## 6. Cấu hình Spark tích hợp MinIO

### 6.1. Batch SparkApplication (project-a ví dụ)

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: project-a-etl-daily     # Convention: <project>-<jobname>
  namespace: spark-operator
spec:
  sparkConf:
    # Event logging -> batch bucket
    "spark.eventLog.enabled": "true"
    "spark.eventLog.dir": "s3a://spark-events-batch/"
    "spark.hadoop.fs.s3a.endpoint": "http://minio.minio.svc.cluster.local:9000"
    "spark.hadoop.fs.s3a.access.key": "<rootUser>"
    "spark.hadoop.fs.s3a.secret.key": "<rootPassword>"
    "spark.hadoop.fs.s3a.path.style.access": "true"
    "spark.hadoop.fs.s3a.impl": "org.apache.hadoop.fs.s3a.S3AFileSystem"
    "spark.hadoop.fs.s3a.aws.credentials.provider": "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider"
    "spark.hadoop.fs.s3a.fast.upload": "true"
```

### 6.2. Spark Connect Server (sc-dev - hiện tại)

```yaml
sparkConf:
  "spark.eventLog.enabled": "true"
  "spark.eventLog.dir": "s3a://spark-events-connect/sc-dev/"
  # (các S3A config như trên)
```

### 6.3. Connect Server dự án tương lai (sc-project-a)

```yaml
sparkConf:
  "spark.eventLog.enabled": "true"
  "spark.eventLog.dir": "s3a://spark-events-connect/sc-project-a/"
  # (các S3A config như trên)
```

### 6.4. Spark History Server [BATCH] configuration

```yaml
# spark-history-server-batch deployment
env:
  SPARK_HISTORY_OPTS: >-
    -Dspark.history.fs.logDirectory=s3a://spark-events-batch/
    -Dspark.hadoop.fs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000
    -Dspark.hadoop.fs.s3a.access.key=<rootUser>
    -Dspark.hadoop.fs.s3a.secret.key=<rootPassword>
    -Dspark.hadoop.fs.s3a.path.style.access=true
    -Dspark.history.fs.update.interval=30s
    -Dspark.history.ui.maxApplications=200
```

### 6.5. Spark History Server [CONNECT] configuration

```yaml
# spark-history-server-connect deployment
env:
  SPARK_HISTORY_OPTS: >-
    -Dspark.history.fs.logDirectory=s3a://spark-events-connect/
    -Dspark.hadoop.fs.s3a.endpoint=http://minio.minio.svc.cluster.local:9000
    -Dspark.hadoop.fs.s3a.access.key=<rootUser>
    -Dspark.hadoop.fs.s3a.secret.key=<rootPassword>
    -Dspark.hadoop.fs.s3a.path.style.access=true
    -Dspark.history.fs.update.interval=10s
    -Dspark.history.ui.maxApplications=50
    # in-progress log detection (đọc Connect Server đang chạy)
    -Dspark.history.fs.inProgressOptimization.enabled=true
```

> **Lưu ý quan trọng về in-progress log:** Với Spark 3.5, khi History Server scan sub-directory (ví dụ `sc-dev/`), nó sẽ tìm thấy file `.inprogress`. Đảm bảo cấu hình `spark.history.fs.logDirectory=s3a://spark-events-connect/` (root của connect bucket) để History Server scan tất cả sub-prefix.

---

## 7. Access Pattern và Expose Services

### 7.1. MinIO Console (Admin UI)

```text
Browser -> https://minio.lakehouse.local:443
        -> HAProxy -> Traefik websecure
        -> Ingress (cert-manager TLS: minio-console-tls)
        -> Service minio-console (ClusterIP:9001)
        -> MinIO Pod
```

### 7.2. MinIO S3 API (nội bộ cluster)

```text
Spark Driver/Executor Pods
  -> http://minio.minio.svc.cluster.local:9000
  -> Service minio (ClusterIP:9000)
  -> MinIO Pod
```

### 7.3. Spark Connect Server (live UI)

```text
Browser -> https://spark-sc-dev-ui.lakehouse.local:443
        -> Traefik -> Ingress (Spark Operator auto-created)
        -> Spark UI port 4040 (LIVE real-time)
```

### 7.4. Spark History Server (sẽ cài trong bước tiếp theo)

```text
Browser -> https://spark-history-batch.lakehouse.local:443
        -> Traefik -> Ingress
        -> Spark History Server pod
        -> Đọc log từ s3a://spark-events-batch/

Browser -> https://spark-history-connect.lakehouse.local:443
        -> Traefik -> Ingress
        -> Spark History Server pod
        -> Đọc log từ s3a://spark-events-connect/ (bao gồm in-progress)
```

---

## 8. Lộ trình mở rộng đa dự án

### Phase 1 (Hiện tại): Dev Environment

```text
Batch jobs    → spark-events-batch/ → History Server [BATCH]
sc-dev        → spark-events-connect/sc-dev/ → History Server [CONNECT] + Live UI
```

### Phase 2: Thêm dự án A

```text
project-a batch → spark-events-batch/ (cùng bucket, khác app name)
sc-project-a   → spark-events-connect/sc-project-a/ (sub-prefix mới)

History Server [BATCH]   tự động thấy job mới của project A
History Server [CONNECT] tự động thấy sc-project-a khi nó chạy
```

**KHÔNG cần deploy thêm MinIO, KHÔNG cần thêm History Server.**

### Phase 3: Isolation nghiêm ngặt (nếu cần)

```text
Nếu project yêu cầu data isolation hoàn toàn:
- Tạo bucket riêng: spark-events-project-a-batch, spark-events-project-a-connect
- Deploy History Server riêng cho project A
- Không project nào thấy log của project khác
```

---

## 9. Rủi ro vận hành

*   **Log size growth:** Connect server chạy vĩnh viễn → file log trong S3 tăng trưởng liên tục. Cần monitor dung lượng PVC Longhorn và bucket `spark-events-connect`. Cân nhắc tắt/restart Connect Server định kỳ để finalize log và kiểm soát kích thước.
*   **In-progress log scanning:** History Server [CONNECT] scan thêm sub-directory → tốn nhiều S3 API calls hơn. Đặt `spark.history.fs.update.interval=30s` (không quá ngắn).
*   **Credentials plaintext trong SparkApplication:** File `spark-sc-dev.yaml` hiện chứa plaintext credentials (`changeme`). Cần thay bằng Kubernetes Secret reference thông qua `envFrom` trong driver spec trước khi lên production.
*   **Standalone MinIO không có HA:** Nếu Longhorn PVC mất dữ liệu, toàn bộ event logs trong cả 2 bucket bị mất. Backup bucket định kỳ là cách giảm rủi ro.
