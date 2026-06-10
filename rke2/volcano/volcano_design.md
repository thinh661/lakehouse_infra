# Tài liệu Thiết kế Volcano Scheduler cho cụm RKE2 Lakehouse

Tài liệu này mô tả vai trò, kiến trúc điều phối, các thuật toán lên lịch nâng cao và cơ chế tích hợp **Volcano Dashboard (UI)** trên cụm **RKE2 HA** hiện tại nhằm phục vụ các tác vụ dữ liệu lớn (Big Data) và AI/ML.

---

## 1. Mục tiêu thiết kế

Trong cụm Lakehouse, các tác vụ tính toán phân tán (như Apache Spark, Ray, Flink, TensorFlow, PyTorch) chạy dưới dạng một tập hợp gồm nhiều Pod (ví dụ: Driver và các Executors). Bộ điều phối mặc định của Kubernetes (default-scheduler) hoạt động theo nguyên lý "từng Pod một", dẫn đến nguy cơ lãng phí tài nguyên và deadlock.

**Volcano** được CNCF tài trợ, thiết kế riêng để giải quyết các bài toán này:
*   **Batch Scheduling:** Lên lịch cho cả "bầy" Pod (Gang/Coscheduling), đảm bảo job chỉ chạy khi có đủ tài nguyên tối thiểu, tránh giữ tài nguyên vô ích.
*   **Queue Management:** Quản lý hàng đợi (Queues) tài nguyên, giới hạn băng thông CPU/RAM cho từng phòng ban (ví dụ: Queue cho đội Data Engineer, Queue cho đội Data Science), đảm bảo chia sẻ tài nguyên công bằng.
*   **Volcano Dashboard (UI):** Cung cấp giao diện trực quan hóa trạng thái các hàng đợi, các job tính toán phân tán, và mức độ tiêu thụ tài nguyên của cụm.
*   **GitOps & Offline-ready:** Triển khai 100% qua ArgoCD, tải và vendor sẵn chart `v1.15.0` nhằm đáp ứng điều kiện vận hành trong mạng nội bộ cô lập.

---

## 2. Kiến trúc các thành phần của Volcano

Hệ thống Volcano bao gồm 4 thành phần chính chạy trong namespace `volcano-system`:

```text
                             Kubernetes API Server
                               /        |       \
                              /         |        \
                             v          v         v
             [Webhook Manager]    [Scheduler]   [Controller Manager]
                     |                  |
              (Validate/Mutate)   (Lên lịch Pod)
                     |                  |
                     v                  v
             [Volcano CRDs] <===========+ (Lắng nghe Job, Queue, PodGroup)
                     ^
                     | (Đọc dữ liệu hiển thị)
             [Volcano Dashboard] <--- (Giao diện quản trị web)
```

1.  **Volcano Scheduler (vc-scheduler):**
    Thành phần cốt lõi thay thế hoặc chạy song song với default-scheduler để điều phối Pod. Nó quét các tài nguyên `PodGroup` và áp dụng các thuật toán lên lịch nâng cao để gán Node cho các Pod.
2.  **Volcano Controller Manager (vc-controller-manager):**
    Quản lý vòng đời của các đối tượng Custom Resource Definition (CRD) của Volcano như `Volcano Job` (vcjob), `Queue`, `PodGroup`.
3.  **Volcano Admission (vc-webhook-manager):**
    Webhook can thiệp vào quá trình tạo/sửa đổi tài nguyên để validate dữ liệu và tự động gán cấu hình mặc định (mutate) cho Job/Queue.
4.  **Volcano Dashboard (volcano-dashboard):**
    Giao diện UI chạy dạng Pod gồm 2 container (Frontend Nginx & Backend Node.js proxy), kết nối tới Kubernetes API Server để lấy thông tin trực quan hóa toàn bộ hệ thống điều phối của Volcano.

---

## 3. Các thuật toán điều phối nâng cao trong Volcano

Volcano cấu hình các hành động (Actions) và các chính sách (Plugins) linh hoạt:

*   **Gang Scheduling (Coscheduling):**
    Đảm bảo một nhóm Pod thuộc cùng một Job phải được khởi chạy cùng nhau. Nếu hệ thống không đủ tài nguyên cho số lượng tối thiểu các Pod (minMember), không Pod nào được lên lịch chạy (tránh deadlock).
*   **Dominant Resource Fairness (DRF):**
    Thuật toán chia sẻ tài nguyên công bằng đa chiều (CPU, Memory, GPU). Nó đảm bảo các User/Queue có mức tiêu thụ tài nguyên thấp hơn sẽ được ưu tiên cấp phát trước, tránh tình trạng một Job lớn độc chiếm toàn bộ cụm.
*   **Binpack (Tối ưu hóa mật độ Node):**
    Ngược lại với chính sách Spread (phân tán Pod ra nhiều Node để an toàn), Binpack sẽ cố gắng gom các Pod của Job vào ít Node nhất có thể. Điều này giúp dồn các tài nguyên trống còn lại của cụm sang các Node khác, tạo ra các "khoảng trống lớn" đủ để lên lịch cho các Pod yêu cầu cấu hình cực cao (ví dụ Pod GPU hoặc Pod Master).
*   **Proportion (Tỷ lệ hàng đợi):**
    Cấp phát tài nguyên cho các Queue theo tỷ lệ trọng số (Weight) được cấu hình trước. Ví dụ: `Queue DE` có trọng số 70, `Queue DS` có trọng số 30; khi cụm quá tải, tài nguyên sẽ được phân bổ theo tỷ lệ 7:3.

---

## 4. Thiết kế tích hợp Dashboard UI và HTTPS Ingress

Để người dùng và quản trị viên phòng dữ liệu dễ dàng theo dõi hệ thống:
*   **Expose Service:** Pod `volcano-dashboard` được expose qua một service ClusterIP nội bộ trên Port 80 (chuyển tiếp tới Port 8080 của container).
*   **Ingress Routing:** Sử dụng Traefik Ingress để ánh xạ tên miền `volcano.lakehouse.local` vào Service của Dashboard.
*   **TLS Encryption:** Ingress được gán annotation `cert-manager.io/cluster-issuer: lakehouse-ca` để cert-manager tự tạo Secret SSL/TLS `volcano-dashboard-tls` bảo mật HTTPS.
*   **RBAC Permissions:** Pod Dashboard sử dụng ServiceAccount `volcano-dashboard` gắn với `ClusterRole` chuyên dụng. Chúng tôi đã bổ sung quyền Read-Only (get, list, watch) đối với `nodes` bên cạnh `pods`, `namespaces`, `podgroups`, `queues` và `events`. Việc này giúp Dashboard hiển thị trực quan thông tin về tài nguyên CPU/Memory/GPU của từng Node trong cụm Kubernetes.

---

## 5. Thiết kế Quản lý Hàng đợi (Queue) và Tích hợp Giám sát

### 5.1. Cấu hình Queue mặc định và Queue "dev" tự động (GitOps)
Để quản lý tài nguyên linh hoạt và tránh việc quản trị viên phải cấu hình thủ công sau mỗi lần tái lập cụm, chúng tôi khai báo các Queue dưới dạng manifest Kubernetes (GitOps) nằm trong thư mục `manifests/`:
*   **Queue `default` (Mặc định):** Được cài đặt sẵn cùng với Volcano Chart, chiếm trọng số mặc định để nhận các tác vụ thông thường.
*   **Queue `dev` (Phát triển):** Được tạo tự động thông qua file `manifests/queues.yaml`.
    *   **Trọng số (`weight: 1`):** Cấp độ ưu tiên ngang hàng với các queue cơ bản.
    *   **Giới hạn trần tài nguyên (`capability`):**
        *   `cpu: "1"` (Tối đa 1 CPU Core)
        *   `memory: "1Gi"` (Tối đa 1 GiB RAM)
    *   *Ý nghĩa thiết kế:* Khi Spark job hay pod được gán vào queue `dev`, tổng lượng tài nguyên mà các pod này đồng thời tiêu thụ từ cluster sẽ bị giới hạn cứng ở mức tối đa 1 CPU và 1GiB RAM. Nếu vượt quá, các pod tiếp theo sẽ bị giữ ở trạng thái `Pending` trong hàng đợi cho đến khi các pod trước đó giải phóng tài nguyên.

### 5.2. Khả năng giám sát Spark Jobs trên Dashboard
Volcano Dashboard không trực tiếp hiển thị CRD `SparkApplication` của Spark Operator. Thay vào đó, nó giám sát ở tầng tài nguyên scheduler:
*   Khi Spark Operator submit job với cấu hình schedulerName là `volcano`, nó sẽ sinh ra một đối tượng `PodGroup` (CRD của Volcano) tương ứng.
*   Volcano Dashboard đọc và giám sát `PodGroup` này dưới dạng các **Application Groups**.
*   Trên UI, quản trị viên có thể theo dõi:
    *   Trạng thái của các Spark Pod (Driver, Executors) đang chạy hay pending.
    *   Số lượng Pod tối thiểu (`minMember`) để job bắt đầu chạy.
    *   Queue mà Spark Job đó đang sử dụng (`default`, `dev`, v.v.).

### 5.3. Khả năng giám sát tài nguyên của toàn cụm Kubernetes
Thông qua quyền truy cập `nodes` trong `ClusterRole` của Dashboard, giao diện UI cung cấp một dashboard theo dõi tài nguyên của các Node vật lý trong cụm:
*   Hiển thị danh sách các Node trong cluster.
*   Hiển thị **Capacity** (Tổng tài nguyên CPU, Memory, GPU phần cứng).
*   Hiển thị **Allocated** (Tài nguyên đã được cấp phát cho các Pod đang chạy).
*   Hiển thị tỷ lệ sử dụng hiện tại và dung lượng tài nguyên trống còn lại của toàn bộ cụm k8s, giúp quản trị viên dễ dàng đưa ra quyết định tăng/giảm dung lượng queue hoặc thêm node mới vào cụm.
