# Tài liệu Thiết kế cert-manager cho cụm RKE2 Lakehouse

Tài liệu này mô tả vai trò, kiến trúc, thứ tự triển khai và mô hình cấp phát TLS bằng **cert-manager** trên cụm **RKE2 HA** hiện tại.

---

## 1. Mục tiêu triển khai

Trong cụm lakehouse, các ứng dụng như Longhorn UI, Airflow, Kafka UI, MinIO Console, Trino, Superset, Rancher hoặc các service nội bộ khác đều cần HTTPS ổn định. `cert-manager` đảm nhận việc tự động tạo, gia hạn và xoay vòng certificate dưới dạng Kubernetes Secret.

Mục tiêu chính:
*   Cài đặt cert-manager theo hướng production, có version pin rõ ràng.
*   Dùng Helm chart chính thức từ Jetstack/cert-manager nhưng vendor chart vào Git để ArgoCD không cần Internet khi sync.
*   Tạo nền tảng TLS chung cho toàn bộ ứng dụng expose qua Traefik Ingress.
*   Cho phép triển khai trước Longhorn vì cert-manager không cần PVC trong hoạt động thông thường.
*   Quản lý lifecycle bằng GitOps/ArgoCD, không dùng Helm CLI để cài hoặc upgrade release thật.

---

## 2. Vị trí của cert-manager trong kiến trúc hiện tại

Cụm hiện tại gồm:
*   **Bastion / HAProxy:** `192.168.49.144`.
*   **RKE2 server nodes:** `192.168.49.141`, `192.168.49.142`, `192.168.49.143`.
*   **Ingress Controller:** Traefik mặc định của RKE2.
*   **Domain nội bộ:** `*.lakehouse.local`, trỏ về Bastion IP `192.168.49.144`.

Luồng HTTPS chuẩn sau khi có cert-manager:

```text
User / Browser
     |
     | HTTPS 443: app.lakehouse.local
     v
Bastion HAProxy 192.168.49.144
     |
     | TCP passthrough 443
     v
RKE2 Node 141 / 142 / 143
     |
     | Traefik websecure entrypoint
     | Dùng TLS Secret do cert-manager tạo
     v
Kubernetes Service
     |
     v
Application Pod
```

`cert-manager` không trực tiếp nhận traffic người dùng. Nó chỉ quản lý certificate và Secret. Traefik mới là thành phần terminate TLS ở rìa cụm.

---

## 3. cert-manager có cần Longhorn hoặc PVC không?

Trong cấu hình thông thường, **cert-manager không cần PVC**.

Các component chính gồm:
*   `cert-manager`: controller xử lý Certificate, Issuer, ClusterIssuer, Order, Challenge.
*   `cert-manager-webhook`: webhook validate/mutate custom resources.
*   `cert-manager-cainjector`: inject CA bundle vào webhook/APIService cần thiết.
*   `startupapicheck`: job kiểm tra API sẵn sàng sau khi cài.

Trạng thái của cert-manager được lưu trong Kubernetes API server/etcd thông qua CRD resources và Secret, không lưu trên volume riêng. Vì vậy có thể cài cert-manager trước Longhorn.

Thứ tự bootstrap khuyến nghị:

```text
RKE2 HA
  -> ArgoCD
  -> cert-manager
  -> ClusterIssuer / Issuer
  -> Longhorn
  -> Lakehouse applications
```

---

## 4. Phiên bản và nguồn chart

Phiên bản mục tiêu hiện tại:

```text
cert-manager: v1.20.2
Helm chart: oci://quay.io/jetstack/charts/cert-manager:v1.20.2
```

Theo tài liệu chính thức, OCI chart là nguồn upstream khuyến nghị cho các version mới vì được publish ngay khi release. Tuy nhiên, để cụm lakehouse có thể chạy khi cắt Internet, ta không để ArgoCD kéo trực tiếp từ OCI registry. Thay vào đó, chart được pull trước bằng `helm pull --untar`, lưu vào Git tại `rke2/cert_manager/charts/cert-manager-v1.20.2`, rồi ArgoCD render chart từ repo nội bộ.

Khi cài đặt qua ArgoCD Application phải bật CRD trong Helm values:

```yaml
crds:
     enabled: true
     keep: true
```

Vẫn nên quản lý cert-manager bằng ArgoCD theo chuẩn GitOps, nhưng không nên nhúng cert-manager làm subchart/dependency của Helm chart ứng dụng khác. cert-manager là thành phần cluster-level, tạo CRD và controller dùng chung toàn cụm, nên cần được cài một lần duy nhất dưới dạng ArgoCD Application riêng với lifecycle riêng.

---

## 5. Mô hình TLS cho môi trường lakehouse

### 5.1. Với domain nội bộ `*.lakehouse.local`

`*.lakehouse.local` là domain nội bộ, thường chỉ được resolve qua file hosts hoặc DNS local. Let's Encrypt public không thể cấp certificate cho domain kiểu này nếu domain không tồn tại công khai và bạn không sở hữu DNS public tương ứng.

Với lab nội bộ, mô hình phù hợp là:
1.  Tạo một private root CA hoặc self-signed CA.
2.  Lưu CA keypair vào Secret trong namespace `cert-manager`.
3.  Tạo `ClusterIssuer` loại `ca`.
4.  Các Ingress của ứng dụng annotate để cert-manager tự tạo TLS Secret.
5.  Import root CA vào Windows/browser để trình duyệt tin certificate nội bộ.

### 5.2. Với production public domain

Nếu sau này có domain thật, ví dụ `lakehouse.example.com`, production nên dùng ACME DNS-01:
1.  Quản lý DNS ở Cloudflare, Route53, Azure DNS, Google Cloud DNS hoặc provider tương tự.
2.  Tạo API token DNS provider và lưu vào Kubernetes Secret.
3.  Tạo `ClusterIssuer` loại ACME DNS-01.
4.  Dùng wildcard certificate như `*.lakehouse.example.com` nếu cần.

DNS-01 phù hợp hơn HTTP-01 cho cụm nội bộ vì không yêu cầu public inbound HTTP trực tiếp vào từng challenge path.

---

## 6. Production baseline đề xuất

Với cụm 3 node RKE2 hiện tại, baseline nên gồm:
*   Pin version chart rõ ràng: `v1.20.2`.
*   Cài CRD bằng Helm chart với `crds.enabled=true` và giữ CRD bằng `crds.keep=true`.
*   Cài vào namespace riêng: `cert-manager`.
*   Chạy controller, webhook và cainjector với `replicaCount=2` để chịu được drain/restart một node.
*   Bật PodDisruptionBudget cho controller, webhook và cainjector với `maxUnavailable=1`.
*   Bật Prometheus metrics mặc định; chỉ bật `ServiceMonitor` sau khi có Prometheus Operator.
*   Đặt resource requests/limits cho controller, webhook, cainjector.
*   Đặt topology spread theo hostname để các replica có xu hướng phân bổ qua nhiều node.
*   Kiểm tra readiness bằng `kubectl wait` và `cmctl check api`.
*   Backup định kỳ các resource: `Issuer`, `ClusterIssuer`, `Certificate`, `CertificateRequest`, `Order`, `Challenge`, `Secret` liên quan.

Baseline hiện được khai báo trong `values-production.yaml`. File `cert-manager.default-values.yaml` chỉ dùng để đối chiếu với default values gốc của chart, không dùng làm values deploy.

Với môi trường offline, lưu ý chart trong Git chỉ giải quyết phần manifest. Các node vẫn cần container image của cert-manager. Trước khi cắt Internet phải preload image lên các node RKE2 hoặc mirror image vào private registry nội bộ.

Các image cần chuẩn bị cho version `v1.20.2`:

```text
quay.io/jetstack/cert-manager-controller:v1.20.2
quay.io/jetstack/cert-manager-webhook:v1.20.2
quay.io/jetstack/cert-manager-cainjector:v1.20.2
quay.io/jetstack/cert-manager-startupapicheck:v1.20.2
quay.io/jetstack/cert-manager-acmesolver:v1.20.2
```

Lưu ý: một số giá trị nâng cao như replica, PodDisruptionBudget, topology spread có thể thay đổi theo chart version. Trước khi áp dụng values production, luôn kiểm tra file values thực tế từ chart đã pull:

```bash
helm show values ./cert-manager-v1.20.2 > cert-manager.default-values.yaml
```

---

## 7. Quan hệ với ArgoCD và GitOps

cert-manager sẽ được cài trực tiếp bằng ArgoCD Application, không cần `helm upgrade --install` trên Bastion. Bastion chỉ dùng để apply Application ban đầu, kiểm tra cluster và thực hiện các thao tác vận hành khi cần. ArgoCD sẽ đọc chart đã vendor trong Git repo, không kéo chart trực tiếp từ Internet.

Application dùng ArgoCD multi-source: source thứ nhất là chart path `rke2/cert_manager/charts/cert-manager-v1.20.2`, source thứ hai là cùng Git repo với `ref: values`. File values production được tham chiếu bằng `$values/rke2/cert_manager/values-production.yaml`, tránh phải đặt values file vào trong thư mục chart vendor hoặc dùng path `../../`.

Các thành phần nên đưa vào Git:
*   ArgoCD Application `argocd-application.yaml` trỏ tới chart path trong Git.
*   File values production `values-production.yaml` để dễ review.
*   Chart đã pull và giải nén tại `charts/cert-manager-v1.20.2`; đây là artifact cài đặt mặc định để ArgoCD không cần Internet.
*   Manifest `ClusterIssuer` hoặc `Issuer`.
*   Manifest test certificate.
*   ArgoCD Application riêng để quản lý issuer/app certificate nếu muốn tách lifecycle.

Với cluster-level component như cert-manager, cần tránh để vừa Helm CLI vừa ArgoCD cùng quản lý một release theo hai nguồn khác nhau. Khi ArgoCD đã quản lý release `cert-manager`, mọi thay đổi version/values nên đi qua Git và ArgoCD sync.

Application nên ignore drift ở `caBundle` của `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration` và `APIService`, vì các field này được cert-manager/cainjector cập nhật động. Nếu không ignore, ArgoCD dễ hiển thị OutOfSync dù trạng thái runtime vẫn đúng.

Có hai cách GitOps hợp lệ, nhưng với yêu cầu cụm có thể cắt Internet, hướng mặc định là:
1.  ArgoCD quản lý chart đã vendor trong repo tại `rke2/cert_manager/charts/cert-manager-v1.20.2`.
2.  Chỉ khi môi trường luôn có Internet mới cân nhắc để ArgoCD kéo trực tiếp từ OCI registry `quay.io/jetstack/charts`.

---

## 8. Rủi ro và lưu ý vận hành

*   Xóa CRD cert-manager sẽ xóa toàn bộ custom resources liên quan. Không làm việc này khi chưa backup.
*   Certificate nội bộ từ private CA cần được trust trên máy client, nếu không browser vẫn cảnh báo.
*   Nếu webhook lỗi, việc tạo/sửa Certificate hoặc Issuer có thể bị treo. Cần kiểm tra Pod `cert-manager-webhook` và APIService.
*   Upgrade cert-manager nên theo từng minor version, đọc release notes và chạy `helm diff` nếu có plugin.
*   Với app production, nên tạo certificate theo namespace/app riêng, không dùng chung một Secret wildcard cho mọi thứ nếu không thật sự cần.
