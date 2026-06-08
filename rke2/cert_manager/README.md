# Hướng dẫn Cài đặt và Vận hành cert-manager bằng ArgoCD

Thư mục này chứa tài liệu và manifest GitOps để triển khai **cert-manager** cho cụm RKE2 HA lakehouse. cert-manager sẽ quản lý TLS certificate cho các ứng dụng expose qua Traefik Ingress như Longhorn, Airflow, Kafka UI, MinIO, Trino, Superset và các service nội bộ khác.

Phiên bản mục tiêu:

```text
cert-manager: v1.20.2
Helm chart source: vendored in Git at rke2/cert_manager/charts/cert-manager-v1.20.2
Namespace: cert-manager
GitOps owner: ArgoCD
```

---

## 1. Nguyên tắc triển khai

cert-manager không cần PVC trong hoạt động thông thường, nên có thể cài trước Longhorn.

Thứ tự khuyến nghị:

```text
RKE2 HA -> ArgoCD -> cert-manager -> Longhorn -> Lakehouse applications
```

Trong cụm hiện tại, HTTPS hoạt động như sau:

```text
Browser HTTPS 443
  -> Bastion HAProxy 443
  -> RKE2 nodes 443
  -> Traefik websecure
  -> TLS Secret do cert-manager tạo
  -> Service/Pod nội bộ
```

cert-manager sẽ được cài bằng **ArgoCD Application riêng**, không nhúng vào chart của app khác và không dùng `helm upgrade --install` thủ công trên Bastion. ArgoCD chỉ đọc chart đã lưu trong Git repo, vì vậy cụm không cần truy cập Internet/OCI registry khi sync.

---

## 2. Cấu trúc file trong module

```text
rke2/cert_manager/
  .clinerules
  README.md
  cert_manager_design.md
  values-production.yaml
  argocd-application.yaml
  charts/
    cert-manager-v1.20.2/
  issuers/
    lakehouse-ca-clusterissuer.yaml
```

Vai trò các file:
*   [values-production.yaml](values-production.yaml): values Helm production baseline cho cert-manager.
*   [cert-manager.default-values.yaml](cert-manager.default-values.yaml): default values gốc xuất ra từ chart `v1.20.2`, chỉ dùng để đối chiếu khi review/upgrade.
*   [argocd-application.yaml](argocd-application.yaml): ArgoCD Application cài cert-manager từ chart đã vendor trong repo.
*   `charts/cert-manager-v1.20.2/`: Helm chart cert-manager đã pull sẵn bằng `helm pull --untar`.
*   [issuers/lakehouse-ca-clusterissuer.yaml](issuers/lakehouse-ca-clusterissuer.yaml): `ClusterIssuer` dùng private CA nội bộ sau khi bạn tạo CA Secret.

---

## 3. Chuẩn bị trên Bastion

SSH vào Bastion node:

```bash
ssh thinh1@192.168.49.144
```

Kiểm tra kết nối Kubernetes:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get pods -n argocd
```

Đảm bảo ArgoCD đã chạy ổn định trước khi cài cert-manager:

```bash
kubectl get applications -n argocd
```

Nếu máy Bastion chưa có thư mục repo, đồng bộ repo lên Bastion trước. Chạy từ máy Windows:

```powershell
scp -r d:\workspace_thinh1\lakehouse_infra\lakehouse_infra\rke2 thinh1@192.168.49.144:~/
```

---

## 4. Pull chart về repo trước khi cài

Thực hiện bước này trên máy có Internet, ví dụ máy Windows/WSL hoặc Bastion nếu Bastion còn được phép ra ngoài. Mục tiêu là tải chart một lần, lưu vào Git, sau đó ArgoCD chỉ cần kết nối tới Git repo.

```bash
cd rke2/cert_manager
mkdir -p charts

helm pull oci://quay.io/jetstack/charts/cert-manager \
  --version v1.20.2 \
  --untar \
  --untardir charts

mv charts/cert-manager charts/cert-manager-v1.20.2
helm show values charts/cert-manager-v1.20.2 > cert-manager.default-values.yaml
```

Sau đó commit các artifact cần thiết:

```text
rke2/cert_manager/charts/cert-manager-v1.20.2/
rke2/cert_manager/cert-manager.default-values.yaml
rke2/cert_manager/values-production.yaml
rke2/cert_manager/argocd-application.yaml
```

Khi cluster bị cắt Internet, ArgoCD vẫn sync được nếu nó còn truy cập được Git repo chứa các file trên.

Không sửa trực tiếp [cert-manager.default-values.yaml](cert-manager.default-values.yaml) để deploy. File deploy thật là [values-production.yaml](values-production.yaml). Khi upgrade chart, dùng default values để so sánh xem chart mới có đổi key nào không.

### 4.1. Chuẩn bị image cho môi trường offline

Chart đã vendor trong Git chỉ giúp ArgoCD render manifest offline. Khi Pod chạy, RKE2 nodes vẫn cần container image. Nếu cluster bị cắt Internet hoàn toàn, cần preload image lên từng node hoặc mirror vào private registry nội bộ trước khi sync Application.

Các image cần cho cert-manager `v1.20.2`:

```text
quay.io/jetstack/cert-manager-controller:v1.20.2
quay.io/jetstack/cert-manager-webhook:v1.20.2
quay.io/jetstack/cert-manager-cainjector:v1.20.2
quay.io/jetstack/cert-manager-startupapicheck:v1.20.2
quay.io/jetstack/cert-manager-acmesolver:v1.20.2
```

Nếu muốn preload bằng tar cho RKE2, trên máy có Internet:

```bash
docker pull quay.io/jetstack/cert-manager-controller:v1.20.2
docker pull quay.io/jetstack/cert-manager-webhook:v1.20.2
docker pull quay.io/jetstack/cert-manager-cainjector:v1.20.2
docker pull quay.io/jetstack/cert-manager-startupapicheck:v1.20.2
docker pull quay.io/jetstack/cert-manager-acmesolver:v1.20.2

docker save \
  quay.io/jetstack/cert-manager-controller:v1.20.2 \
  quay.io/jetstack/cert-manager-webhook:v1.20.2 \
  quay.io/jetstack/cert-manager-cainjector:v1.20.2 \
  quay.io/jetstack/cert-manager-startupapicheck:v1.20.2 \
  quay.io/jetstack/cert-manager-acmesolver:v1.20.2 \
  -o cert-manager-images-v1.20.2.tar
```

Copy file tar lên từng RKE2 node và đặt vào thư mục import image của RKE2:

```bash
sudo mkdir -p /var/lib/rancher/rke2/agent/images
sudo cp cert-manager-images-v1.20.2.tar /var/lib/rancher/rke2/agent/images/
sudo systemctl restart rke2-server
```

Với node agent thì restart `rke2-agent`. Cụm hiện tại đang có 3 node server nên thực hiện lần lượt từng node, kiểm tra node Ready rồi mới chuyển node tiếp theo.

---

## 5. Cấu hình repoURL trong ArgoCD Application

Mở [argocd-application.yaml](argocd-application.yaml) và sửa `repoURL` về Git repo thật của bạn:

```yaml
sources:
  - repoURL: https://github.com/thinh661/lakehouse_infra.git
    targetRevision: main
    path: rke2/cert_manager/charts/cert-manager-v1.20.2
    helm:
      releaseName: cert-manager
      valueFiles:
        - $values/rke2/cert_manager/values-production.yaml
  - repoURL: https://github.com/thinh661/lakehouse_infra.git
    targetRevision: main
    ref: values
```

Ý nghĩa:
*   Source thứ nhất là Helm chart đã vendor, có file `Chart.yaml`.
*   Source thứ hai đặt `ref: values` để ArgoCD đọc file values từ cùng Git repo.
*   `$values/rke2/cert_manager/values-production.yaml` là values deploy thật, không cần đặt values file bên trong chart folder.

Sửa cả hai dòng `repoURL` về cùng Git repo thật mà ArgoCD truy cập được. Nếu repo của bạn là private, cần đăng ký repository credential trong ArgoCD trước. Sau này khi cắt Internet, chỉ cần đảm bảo ArgoCD còn thông tới Git repo này.

Application đã bật:
*   `CreateNamespace=true` để ArgoCD tạo namespace `cert-manager`.
*   `ServerSideApply=true` để apply CRD và object lớn ổn định hơn.
*   `RespectIgnoreDifferences=true` và ignore `caBundle` động của webhook/APIService để tránh OutOfSync giả.
*   Retry sync 5 lần với backoff ngắn để chịu được lúc webhook/CRD vừa khởi tạo.

---

## 6. Cài cert-manager bằng ArgoCD Application

Trên Bastion, apply Application:

```bash
cd ~/rke2/cert_manager
kubectl apply -f argocd-application.yaml
```

ArgoCD sẽ:
1.  Đọc Application `cert-manager` trong namespace `argocd`.
2.  Clone Git repo nội bộ của bạn.
3.  Đọc Helm chart tại `rke2/cert_manager/charts/cert-manager-v1.20.2`.
4.  Render chart với [values-production.yaml](values-production.yaml) qua `$values` source.
5.  Tạo namespace `cert-manager`.
6.  Cài CRDs và các component cert-manager.
7.  Tự động sync/prune/self-heal theo cấu hình Application.

Theo dõi trạng thái bằng CLI:

```bash
kubectl get application cert-manager -n argocd
kubectl describe application cert-manager -n argocd
kubectl get pods -n cert-manager -o wide
kubectl get crd | grep cert-manager
```

Nếu dùng ArgoCD UI, truy cập:

```text
https://argocd.lakehouse.local
```

Tìm Application `cert-manager`, kiểm tra trạng thái `Synced` và `Healthy`.

Checklist trước khi deploy thật:
1.  [argocd-application.yaml](argocd-application.yaml) đã sửa `repoURL` về repo thật.
2.  Chart folder `charts/cert-manager-v1.20.2/` đã commit/push lên Git.
3.  [values-production.yaml](values-production.yaml) đã commit/push lên Git.
4.  ArgoCD truy cập được Git repo sau khi cluster bị cắt Internet.
5.  Các image cert-manager đã có sẵn trên nodes hoặc trong private registry nội bộ.

Thứ tự deploy khuyến nghị:
1.  Commit/push toàn bộ module [rke2/cert_manager](.) lên Git.
2.  Đăng ký Git repo credential trong ArgoCD nếu repo private.
3.  Apply [argocd-application.yaml](argocd-application.yaml) một lần từ Bastion.
4.  Đợi Application `cert-manager` Healthy/Synced.
5.  Tạo CA Secret `lakehouse-root-ca`.
6.  Apply [issuers/lakehouse-ca-clusterissuer.yaml](issuers/lakehouse-ca-clusterissuer.yaml).
7.  Tạo certificate test cho `argocd.lakehouse.local` hoặc app thử nghiệm.

---

## 7. Đăng ký Git repo trong ArgoCD nếu cần

Nếu Git repo là public hoặc ArgoCD đã được cấu hình sẵn repository, bạn có thể bỏ qua bước này. Nếu repo private, tạo repository secret trong namespace `argocd`.

Ví dụ HTTPS với username/token:

```bash
cat > argocd-lakehouse-repo.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: lakehouse-infra-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/thinh661/lakehouse_infra.git
  username: thinh661
  password: password
EOF

kubectl apply -f argocd-lakehouse-repo.yaml
```

Không commit file chứa token vào Git. Nếu repo Git nội bộ không cần authentication, không cần tạo secret này.

---

## 8. Ghi chú về OCI chart

OCI chart vẫn là nguồn upstream chính thức, nhưng chỉ dùng ở thời điểm bạn chủ động cập nhật/vendoring chart. Flow production mong muốn là:

```text
Internet-enabled workstation
  -> helm pull --untar cert-manager chart
  -> commit chart vào Git repo
  -> ArgoCD trong cluster chỉ đọc Git repo
```

Không cấu hình ArgoCD kéo trực tiếp từ `quay.io` nếu cụm lakehouse cần chạy được khi cắt Internet.

---

## 9. Kiểm tra cert-manager sau khi ArgoCD sync

Chờ các component sẵn sàng:

```bash
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
```

Kiểm tra Pod và CRD:

```bash
kubectl get pods -n cert-manager -o wide
kubectl get deploy -n cert-manager
kubectl get crd | grep cert-manager
```

Cài `cmctl` trên Bastion nếu muốn kiểm tra API nhanh:

```bash
curl -L -o cmctl.tar.gz https://github.com/cert-manager/cmctl/releases/latest/download/cmctl_linux_amd64.tar.gz
tar xzf cmctl.tar.gz
sudo mv cmctl /usr/local/bin/cmctl
cmctl version
cmctl check api
```

---

## 10. Tạo CA nội bộ cho domain `*.lakehouse.local`

Vì `*.lakehouse.local` là domain nội bộ, bước đầu nên dùng private CA. Tạo root CA keypair trên Bastion:

```bash
mkdir -p ~/rke2/cert_manager/pki
cd ~/rke2/cert_manager/pki

openssl genrsa -out lakehouse-root-ca.key 4096
openssl req -x509 -new -nodes \
  -key lakehouse-root-ca.key \
  -sha256 \
  -days 3650 \
  -out lakehouse-root-ca.crt \
  -subj "/CN=Lakehouse Internal Root CA/O=Lakehouse Infra"
```

Tạo Secret chứa CA trong namespace `cert-manager`:

```bash
kubectl create secret tls lakehouse-root-ca \
  --cert=lakehouse-root-ca.crt \
  --key=lakehouse-root-ca.key \
  -n cert-manager
```

Apply `ClusterIssuer` đã lưu trong repo:

```bash
cd ~/rke2/cert_manager
kubectl apply -f issuers/lakehouse-ca-clusterissuer.yaml
kubectl get clusterissuer lakehouse-ca
```

Lưu ý quan trọng: file `lakehouse-root-ca.key` là private key của CA nội bộ. Không commit private key này lên Git. Chỉ lưu public certificate `lakehouse-root-ca.crt` nếu cần import trust vào client.

---

## 11. Test cấp certificate cho một domain nội bộ

Tạo certificate test:

```bash
cat > test-argocd-certificate.yaml <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-argocd-lakehouse-local
  namespace: cert-manager
spec:
  secretName: test-argocd-lakehouse-local-tls
  duration: 2160h
  renewBefore: 360h
  subject:
    organizations:
      - Lakehouse Infra
  commonName: argocd.lakehouse.local
  dnsNames:
    - argocd.lakehouse.local
  issuerRef:
    name: lakehouse-ca
    kind: ClusterIssuer
EOF

kubectl apply -f test-argocd-certificate.yaml
```

Kiểm tra certificate:

```bash
kubectl get certificate -n cert-manager
kubectl describe certificate test-argocd-lakehouse-local -n cert-manager
kubectl get secret test-argocd-lakehouse-local-tls -n cert-manager
```

Xóa certificate test nếu không dùng nữa:

```bash
kubectl delete -f test-argocd-certificate.yaml
```

---

## 12. Dùng cert-manager với Ingress Traefik

Ví dụ Ingress cho một ứng dụng dùng `ClusterIssuer` nội bộ:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-app
  namespace: example
  annotations:
    cert-manager.io/cluster-issuer: lakehouse-ca
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - example.lakehouse.local
      secretName: example-lakehouse-local-tls
  rules:
    - host: example.lakehouse.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example-service
                port:
                  number: 80
```

Khi apply Ingress, cert-manager sẽ tự tạo `Certificate` và Secret `example-lakehouse-local-tls`. Traefik dùng Secret này để phục vụ HTTPS.

---

## 13. Import root CA vào máy Windows

Để browser tin certificate nội bộ, copy public CA về Windows. Chạy từ PowerShell trên máy Windows:

```powershell
scp thinh1@192.168.49.144:~/rke2/cert_manager/pki/lakehouse-root-ca.crt d:\workspace_thinh1\lakehouse_infra\lakehouse_infra\rke2\cert_manager\
```

Trên Windows:
1.  Mở `Manage user certificates` hoặc `certmgr.msc`.
2.  Vào `Trusted Root Certification Authorities` -> `Certificates`.
3.  Import file `lakehouse-root-ca.crt`.
4.  Khởi động lại browser.

---

## 14. Vận hành hằng ngày

Kiểm tra trạng thái ArgoCD:

```bash
kubectl get application cert-manager -n argocd
kubectl describe application cert-manager -n argocd
```

Kiểm tra component:

```bash
kubectl get pods -n cert-manager -o wide
kubectl get deploy -n cert-manager
cmctl check api
```

Kiểm tra certificate toàn cụm:

```bash
kubectl get certificates -A
kubectl get certificaterequests -A
kubectl get orders -A
kubectl get challenges -A
```

Xem lỗi certificate:

```bash
kubectl describe certificate <certificate-name> -n <namespace>
kubectl describe certificaterequest <request-name> -n <namespace>
kubectl logs -n cert-manager deploy/cert-manager --tail=200
kubectl logs -n cert-manager deploy/cert-manager-webhook --tail=200
```

Xem ngày hết hạn certificate trong Secret:

```bash
kubectl get secret <tls-secret-name> -n <namespace> -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -subject -issuer -dates
```

Gia hạn thủ công một certificate nếu cần:

```bash
cmctl renew <certificate-name> -n <namespace>
```

---

## 15. Backup

Backup cert-manager resources:

```bash
mkdir -p ~/rke2/backups/cert-manager

kubectl get issuer,clusterissuer,certificate,certificaterequest,order,challenge -A -o yaml \
  > ~/rke2/backups/cert-manager/cert-manager-resources.yaml
```

Backup các TLS Secret quan trọng:

```bash
kubectl get secrets -A -o yaml \
  > ~/rke2/backups/cert-manager/all-secrets-backup.yaml
```

Với CA nội bộ, backup riêng private key CA ở nơi an toàn:

```bash
tar czf ~/rke2/backups/cert-manager/lakehouse-root-ca-private-backup.tar.gz \
  -C ~/rke2/cert_manager/pki lakehouse-root-ca.key lakehouse-root-ca.crt
```

Không commit private key hoặc backup Secret chứa private key lên Git.

---

## 16. Upgrade cert-manager bằng GitOps

Không chạy `helm upgrade` thủ công trên Bastion. Quy trình upgrade chuẩn là sửa Git rồi để ArgoCD sync.

1.  Trên máy có Internet, đọc release notes version mới.
2.  `helm pull --untar` chart version mới vào `charts/cert-manager-<version>`.
3.  So sánh [values-production.yaml](values-production.yaml) với default values của chart mới.
4.  Sửa `path` trong [argocd-application.yaml](argocd-application.yaml) sang chart folder mới.
5.  Commit/push chart mới, values và Application lên Git.
6.  Sync Application `cert-manager` trong ArgoCD.

---

## 17. Rollback

Rollback chuẩn GitOps là revert commit đã nâng version/values rồi để ArgoCD sync lại.

Không dùng `helm rollback` trừ trường hợp khẩn cấp, vì release đang được ArgoCD quản lý.

---

## 18. Gỡ cài đặt

Chỉ gỡ cert-manager khi chắc chắn không còn ứng dụng phụ thuộc vào certificate do nó quản lý.

Kiểm tra resources còn tồn tại:

```bash
kubectl get Issuers,ClusterIssuers,Certificates,CertificateRequests,Orders,Challenges --all-namespaces
```

Gỡ theo GitOps:
1.  Xóa hoặc disable Application `cert-manager` trong Git.
2.  Sync ArgoCD để prune tài nguyên do Application quản lý.
3.  Kiểm tra namespace `cert-manager` và các CRD còn lại.

Nếu thực sự muốn xóa toàn bộ CRD và mọi resource liên quan:

```bash
kubectl delete crd \
  issuers.cert-manager.io \
  clusterissuers.cert-manager.io \
  certificates.cert-manager.io \
  certificaterequests.cert-manager.io \
  orders.acme.cert-manager.io \
  challenges.acme.cert-manager.io
```

Lệnh trên có tính phá hủy dữ liệu cert-manager. Chỉ chạy sau khi đã backup.