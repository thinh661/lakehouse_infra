# Tài liệu Thiết kế Spark Operator cho cụm RKE2 Lakehouse

Tài liệu này mô tả kiến trúc, mô hình phân bổ tài nguyên và cách tích hợp **Spark Operator** với **Volcano Batch Scheduler** và **cert-manager** trên cụm **RKE2 HA** hiện tại nhằm chuẩn bị nền tảng chạy các tác vụ Spark tính toán phân tán.

---

## 1. Mục tiêu thiết kế

Trong cụm Lakehouse, các công việc xử lý dữ liệu (ETL, Machine Learning) yêu cầu khả năng tính toán mạnh mẽ và co giãn linh hoạt. Thay vì chạy cụm Spark tĩnh (chạy liên tục tốn tài nguyên), hệ thống sử dụng **Spark Operator** để triển khai mô hình tính toán động (on-demand compute resources):
*   **Kubernetes-native Spark:** Sử dụng Custom Resource Definition (CRD) `SparkApplication` để khai báo Job Spark. Kubernetes sẽ chịu trách nhiệm phân bổ Driver và các Executor động cho từng Job.
*   **Volcano Batch Scheduling:** Tích hợp sâu với Volcano Scheduler để giải quyết các vấn đề lên lịch (scheduling) cho tính toán lô (batch workload) mà bộ điều phối mặc định của Kubernetes (default-scheduler) chưa giải quyết tốt.
*   **Bảo mật Webhook bằng cert-manager:** Admission Webhook của Spark Operator đóng vai trò cấu hình Pod Spark (Driver/Executor). Chứng chỉ TLS cho Webhook này được quản lý tự động bởi cert-manager thông qua ClusterIssuer `lakehouse-ca`.
*   **Quản lý GitOps hoàn chỉnh:** Toàn bộ thành phần và tài nguyên được triển khai đồng bộ qua ArgoCD, đảm bảo tính nhất quán của cụm.

---

## 2. Kiến trúc tổng thể và luồng xử lý

```text
       Kubernetes API Server (Apply SparkApplication CRD)
                  |
                  v
       [Spark Operator Pod]  <--- Quản lý vòng đời Spark Application
         |               |
         | (Tạo Driver)  | (Tạo PodGroup)
         v               v
    [Driver Pod]  [Volcano PodGroup]
         |               |
         | (Yêu cầu)     | (Lên lịch dạng Gang Scheduling)
         v               v
  [Executors Pods] <-----+ (Chỉ chạy khi có đủ tài nguyên cho cả cụm)
```

Khi một tài nguyên `SparkApplication` được áp dụng (apply) vào K8s API Server:
1.  **Spark Operator** phát hiện và tiến hành gửi yêu cầu tạo Pod cho **Spark Driver**. Đồng thời, do tích hợp Volcano, Operator sẽ tạo thêm một tài nguyên **Volcano PodGroup**.
2.  **Volcano Scheduler** kiểm tra xem tổng tài nguyên cụm có đủ đáp ứng tối thiểu (minMember) số lượng Executor + Driver hay không (Gang Scheduling).
3.  Nếu đủ, Volcano sẽ lên lịch chạy đồng thời Driver và toàn bộ Executor.
4.  Nếu không đủ, toàn bộ cụm Pod Spark đó sẽ ở trạng thái chờ (Pending) thay vì chạy trước Driver rồi bị treo do thiếu Executor (tránh lãng phí tài nguyên và deadlock).

---

## 3. Vai trò của Volcano Scheduler và Lý do phải cài trước

### 3.1. Tại sao default-scheduler của Kubernetes không phù hợp cho Spark?
Bộ điều phối mặc định của Kubernetes (default-scheduler) hoạt động theo cơ chế **từng Pod một (pod-by-pod)**. Điều này dẫn đến lỗi **Deadlock tài nguyên (Resource Deadlock)**:
*   Giả sử cụm còn trống 4GB RAM. Có 2 Job Spark cùng submit cùng lúc, mỗi Job yêu cầu 1 Driver (1GB) và 3 Executor (mỗi cái 1GB, tổng 4GB/Job).
*   Default-scheduler có thể lên lịch cho cả 2 Driver chạy trước (mất 2GB). Cụm chỉ còn dư 2GB RAM.
*   Cả 2 Job đều không thể tạo đủ 3 Executor của mình vì thiếu RAM (mỗi bên chỉ tạo được thêm tối đa 1 Executor).
*   Cả 2 Job bị treo vĩnh viễn (Pending) chờ tài nguyên, trong khi các Pod Driver vẫn đang chiếm giữ tài nguyên mà không làm được gì.

### 3.2. Giải pháp từ Volcano Scheduler
Volcano giới thiệu khái niệm **Gang Scheduling (hay Coscheduling)** thông qua tài nguyên **PodGroup**:
*   Một Job chỉ được phép chạy khi và chỉ khi hệ thống đáp ứng đủ số lượng tài nguyên tối thiểu cho cả "bầy" (bao gồm Driver + minExecutors).
*   Nếu không đáp ứng đủ, Volcano sẽ giữ toàn bộ Pod ở trạng thái Pending, nhường chỗ cho các Job nhỏ hơn có thể chạy xong trước, giải phóng tài nguyên.

### 3.3. Thứ tự cài đặt khuyến nghị
*   **Cài đặt Volcano trước Spark Operator:**
    Vì Spark Operator đóng vai trò là "Client" tích hợp vào Volcano (nó cần đăng ký PodGroup và gắn `schedulerName: volcano` cho các Pod Spark).
    *   Nếu cài Spark Operator trước, Operator vẫn khởi động bình thường nhưng khi bạn submit `SparkApplication`, các Pod Spark Driver và Executor sẽ ở trạng thái `Pending` vô thời hạn vì chưa có cụm Volcano Scheduler chạy trong hệ thống để xử lý tên scheduler `volcano`.
    *   Do đó, cài đặt Volcano trước là bắt buộc để chuẩn bị sẵn hạ tầng scheduler, sau đó mới deploy Spark Operator.

---

## 4. Tích hợp cert-manager và Admissions Webhook

Spark Operator sử dụng một Admission Webhook để can thiệp vào quá trình tạo Pod của Spark (ví dụ: tự động gắn volume, mount configmap, cấu hình network cho Executor dựa trên khai báo của Driver). 

Kiến trúc Webhook của Spark Operator:
*   Webhook yêu cầu kết nối an toàn qua HTTPS.
*   Trước đây, chart mặc định tự sinh chứng chỉ self-signed (tự ký) hoặc yêu cầu cài đặt thủ công.
*   Trong thiết kế này, hệ thống bật `certManager.enable: true` và trỏ tới `ClusterIssuer: lakehouse-ca`. `cert-manager` sẽ tự động cấp phát chứng chỉ SSL/TLS chuẩn, lưu vào Kubernetes Secret `spark-operator-webhook-cert` và tự động xoay vòng (renew) định kỳ.
*   Điều này giúp cụm hoạt động ổn định, tránh lỗi API Server từ chối kết nối Webhook do chứng chỉ hết hạn.

---

## 5. Cấu hình RBAC và Namespace Scoping

Khi Spark Application chạy:
*   Spark Driver Pod hoạt động như một Kubernetes Controller thu nhỏ: nó trực tiếp gửi yêu cầu tạo các Pod Executor lên API Server.
*   Do đó, Spark Driver yêu cầu một **ServiceAccount** có đủ quyền (RBAC) để tạo, xóa, và theo dõi (create, delete, watch) Pods trong namespace của nó.
*   Cấu hình `spark.serviceAccount.create: true` trong values sẽ tự động tạo một ServiceAccount tên `spark-service-account` có đầy đủ Role/ClusterRole tương ứng để gán cho Driver.
*   Cấu hình `spark.jobNamespaces: [""]` (chứa chuỗi rỗng) cho phép Spark Operator có quyền `Cluster-wide` để giám sát và tạo Spark Application ở bất kỳ namespace nào trong cụm RKE2 (thuận tiện cho việc chạy Spark từ JupyterHub hoặc Airflow ở các namespace khác).
