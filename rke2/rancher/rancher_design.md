# Tài liệu Thiết kế Rancher cho cụm RKE2 Lakehouse

Tài liệu này mô tả cách triển khai Rancher bằng ArgoCD trong cụm RKE2 lakehouse, theo cùng mô hình GitOps/offline-friendly đang dùng cho cert-manager.

---

## 1. Mục tiêu

Rancher được dùng làm giao diện quản trị Kubernetes để kiểm tra cụm RKE2, quản lý workload, quan sát trạng thái cluster và test luồng TLS do cert-manager cấp phát.

Mục tiêu triển khai:
* Cài Rancher bằng ArgoCD Application riêng.
* Vendor Helm chart Rancher vào Git repo để ArgoCD không cần Internet khi sync.
* Expose Rancher tại `https://rancher.lakehouse.local` qua HAProxy -> Traefik.
* Dùng cert-manager `ClusterIssuer` `lakehouse-ca` để cấp TLS Secret cho Ingress Rancher.
* Không lưu bootstrap password hoặc secret nhạy cảm trong Git.

---

## 2. Kiến trúc truy cập

Luồng truy cập Rancher:

```text
Browser
  -> https://rancher.lakehouse.local:443
  -> Bastion HAProxy 192.168.49.144:443
  -> RKE2 node 443
  -> Traefik websecure
  -> Ingress rancher
  -> TLS Secret tls-rancher-ingress do cert-manager tạo
  -> Service rancher
  -> Pod rancher trong namespace cattle-system
```

Rancher không tự terminate TLS ở rìa cụm. Traefik terminate TLS bằng Secret do cert-manager quản lý.

---

## 3. Quan hệ với cert-manager

Rancher phụ thuộc vào cert-manager nếu ta muốn dùng certificate nội bộ tự động.

Thứ tự triển khai:

```text
RKE2 HA
  -> ArgoCD
  -> cert-manager
  -> lakehouse-ca ClusterIssuer
  -> Rancher
```

Trong values Rancher, TLS được cấu hình theo kiểu `secret`:

```yaml
ingress:
  tls:
    source: secret
    secretName: tls-rancher-ingress
  extraAnnotations:
    cert-manager.io/cluster-issuer: lakehouse-ca
```

Khi ArgoCD sync Rancher, cert-manager sẽ quan sát Ingress và cấp Secret `tls-rancher-ingress` trong namespace `cattle-system`.

---

## 4. Phiên bản và tương thích Kubernetes

Phiên bản chart được chuẩn bị:

```text
Rancher chart: 2.14.2
Rancher appVersion: v2.14.2
Chart repo upstream: https://releases.rancher.com/server-charts/latest
Vendored path hiện tại: rke2/rancher/charts/charts/rancher-2.14.2
```

Lưu ý quan trọng: chart Rancher `2.14.2` khai báo:

```text
kubeVersion: < 1.36.0-0
```

Cụm hiện tại đang là RKE2/Kubernetes `v1.36.1`, vì vậy Rancher `2.14.2` chưa hỗ trợ chính thức cụm này. Không nên deploy Rancher thật cho tới khi Rancher phát hành chart hỗ trợ Kubernetes 1.36, hoặc bạn dựng một cụm test RKE2/Kubernetes 1.35.x trở xuống để kiểm chứng cert-manager.

---

## 5. GitOps và offline model

ArgoCD Application dùng multi-source giống module cert-manager:
* Source 1: chart đã vendor tại `rke2/rancher/charts/charts/rancher-2.14.2`.
* Source 2: cùng Git repo với `ref: values`, dùng `$values/rke2/rancher/values-production.yaml`.

Chart trong Git chỉ giải quyết phần manifest. Vì certificate Rancher dùng CA nội bộ, `privateCA: true` được bật và cần Secret `tls-ca` trong namespace `cattle-system` chứa root CA để Rancher agents trust endpoint `https://rancher.lakehouse.local`.

Với môi trường offline, node hoặc private registry nội bộ vẫn phải có image Rancher. Image tối thiểu khi render chart thường là:

```text
rancher/rancher:v2.14.2
```

Khi dùng Rancher air-gap đầy đủ, cần mirror thêm các image hệ thống mà Rancher dùng để quản lý/import cluster. Danh sách đó nên lấy theo tài liệu air-gap chính thức của Rancher cho đúng version.

---

## 6. HA và tài nguyên

File `values-production.yaml` hiện đặt `replicas: 1` vì mục tiêu trước mắt là test cert-manager và UI Rancher trong lab. Khi Rancher trở thành thành phần quản trị chính thức, nên nâng lên `replicas: 3`, đảm bảo đủ tài nguyên, và kiểm tra lại chart values mới nhất.

Baseline lab:
* Namespace: `cattle-system`.
* Hostname: `rancher.lakehouse.local`.
* Ingress class: `traefik`.
* TLS Secret: `tls-rancher-ingress` do cert-manager tạo.
* CA Secret: `tls-ca` do người vận hành tạo từ root CA nội bộ.
* Audit log bật mức cơ bản qua sidecar.

---

## 7. Rủi ro vận hành

* Không deploy Rancher `2.14.2` lên Kubernetes `1.36.1` nếu cần trạng thái supported.
* Không commit bootstrap password hoặc token vào Git.
* Rancher tự tạo nhiều tài nguyên quản trị trong cluster; rollback cần đi qua Git/ArgoCD và đọc release notes.
* Nếu certificate chưa Ready, kiểm tra `Certificate`, `CertificateRequest`, Secret `tls-rancher-ingress`, và log cert-manager.
* Nếu Ingress không truy cập được, kiểm tra DNS/hosts `rancher.lakehouse.local`, HAProxy 443, Traefik, và Ingress class.