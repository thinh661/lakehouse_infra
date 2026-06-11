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
*   Cấu hình `spark.jobNamespaces` chứa chuỗi rỗng `""` cho phép Spark Operator có quyền `Cluster-wide` để giám sát và tạo Spark Application ở bất kỳ namespace nào trong cụm RKE2. Tuy nhiên, khi dùng `""`, Helm chart sẽ không tự động tạo ServiceAccount cho các namespace. Do đó, chúng tôi khai báo tường minh thêm các namespace chính (như `spark-operator`, `default`, `jupyter`, `airflow`) vào danh sách `jobNamespaces` để Helm tự động tạo sẵn ServiceAccount và RBAC Role/RoleBinding tương ứng.

---

## 6. Thiết kế Spark Connect Server (`spark-sc-dev`)

Để tối ưu hóa trải nghiệm phát triển (Interactive Dev/Test) cho Data Scientists trên JupyterHub và các nhà phát triển nội bộ (Local Developers), chúng tôi thiết lập một dịch vụ **Spark Connect Server** chạy liên tục tên là `spark-sc-dev` dưới dạng một SparkApplication Java:
*   **Cơ chế Thin Client (Decoupling):** Thay vì để Jupyter Notebook Pod chạy tiến trình Spark Driver nặng nề, Notebook Pod chỉ chạy một thư viện mỏng (thin-client) và gửi các lệnh tính toán qua cổng gRPC `15002` tới Spark Connect Server.
*   **Dynamic Resource Allocation (DRA):** Spark Connect Server được cấu hình tính năng co giãn tài nguyên động dựa trên tải công việc thực tế (`spark.dynamicAllocation.enabled: true` và `spark.dynamicAllocation.shuffleTracking.enabled: true`). 
    *   Khi không có lệnh tính toán nào từ Jupyter/Local, số lượng Executor Pods tự động scale-down về `0` để tiết kiệm RAM/CPU cho cụm.
    *   Khi có truy vấn gửi đến, Server tự động gửi yêu cầu lên API Server để tạo nhanh các Executor Pods (tối đa là 5 Executors).
    *   Các Executor Pods sau 60 giây ở trạng thái rỗi (idle) sẽ tự động bị xóa bỏ.
*   **Tích hợp Volcano:** Toàn bộ các Executor được co giãn bởi Spark Connect Server đều được cấu hình schedulerName là `volcano`, đảm bảo việc xếp hàng tài nguyên công bằng và tối ưu.
*   **Expose gRPC & UI:** Service NodePort `spark-sc-dev-connect-nodeport` mở cổng `30052` trên các RKE2 nodes để người dùng local kết nối gRPC, và Ingress `spark-sc-dev-ui.lakehouse.local` mở cổng `4040` bảo mật HTTPS để quản trị viên theo dõi Spark UI thời gian thực.

---

## 7. Thiết kế Spark UI Reverse Proxy cho các Batch Jobs

Khi chạy các Spark Job dạng lô (batch) thông qua Airflow (sử dụng `SparkKubernetesOperator`), các Pod Spark Driver và Executor sẽ bị xóa ngay lập tức khi Job kết thúc để giải phóng tài nguyên. Để người dùng có thể trace log và kiểm tra Spark UI trong quá trình Job đang chạy:
*   **Bật UI Ingress tự động:** Chúng tôi cấu hình tham số `controller.uiIngress.enable: true` trong Spark Operator Controller.
*   **Cú pháp URL động:** Khi có một SparkApplication được submit, Controller sẽ tự động tạo ra một Ingress tương ứng với host-name động có định dạng: `{{$appName}}-{{$appNamespace}}.spark-ui.lakehouse.local`.
*   **Tích hợp Airflow Reverse Proxy:** Airflow có thể đọc được Ingress URL này từ API của SparkApplication và in ra link trong Logs. Người dùng chỉ cần click vào link là có thể truy cập thẳng vào Spark UI thời gian thực của Job mà không cần cấu hình thủ công.
*   **Lưu trữ Event Logs lâu dài:** Toàn bộ log sự kiện của Job sẽ được stream trực tiếp về **MinIO** (`s3a://spark-events-bucket/`). Sau khi Job kết thúc và các Pod bị xóa, người dùng truy cập vào **Spark History Server** để xem lại toàn bộ DAG và thực hiện tunning cấu hình cho các lần chạy sau.

