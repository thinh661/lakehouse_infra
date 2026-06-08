# Hướng dẫn Cài đặt và Vận hành Rancher bằng ArgoCD

Module này triển khai Rancher theo mô hình GitOps/offline-friendly tương tự cert-manager: Helm chart được tải sẵn vào Git repo, ArgoCD render chart từ Git, TLS do cert-manager cấp.

Phiên bản mục tiêu:

```text
Rancher chart: 2.14.2
Rancher appVersion: v2.14.2
Namespace: cattle-system
Hostname: rancher.lakehouse.local
GitOps owner: ArgoCD
TLS issuer: cert-manager ClusterIssuer lakehouse-ca
```

> Cảnh báo tương thích: Rancher chart `2.14.2` khai báo `kubeVersion: < 1.36.0-0`, trong khi cụm hiện tại là RKE2/Kubernetes `v1.36.1`. Không nên deploy thật lên cụm hiện tại cho tới khi Rancher hỗ trợ Kubernetes 1.36, hoặc dùng cụm test Kubernetes 1.35.x trở xuống.

---

## 1. Cấu trúc file

```text
rke2/rancher/
  .clinerules
  README.md
  rancher_design.md
  values-production.yaml
  argocd-application.yaml
  charts/
    rancher.default-values.yaml
    charts/
      rancher-2.14.2/
```

Vai trò:
* [values-production.yaml](values-production.yaml): values deploy thật cho Rancher.
* `charts/rancher.default-values.yaml`: default values gốc từ chart, dùng để đối chiếu khi review/upgrade.
* [argocd-application.yaml](argocd-application.yaml): ArgoCD Application cài Rancher từ chart đã vendor.
* `charts/charts/rancher-2.14.2/`: Helm chart Rancher đã pull sẵn theo cấu trúc hiện tại.
* [rancher_design.md](rancher_design.md): tài liệu kiến trúc và vận hành.

---

## 2. Pull chart về repo

Chạy trong WSL trên máy có Internet:

```bash
cd /mnt/d/workspace_thinh1/lakehouse_infra/lakehouse_infra/rke2/rancher
mkdir -p charts

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm pull rancher-latest/rancher \
  --version 2.14.2 \
  --untar \
  --untardir charts

mv charts/rancher charts/rancher-2.14.2
helm show values charts/rancher-2.14.2 > rancher.default-values.yaml
```

Sau đó commit:

```text
rke2/rancher/charts/charts/rancher-2.14.2/
rke2/rancher/charts/rancher.default-values.yaml
rke2/rancher/values-production.yaml
rke2/rancher/argocd-application.yaml
```

---

## 3. Chuẩn bị trước khi deploy

Checklist:
1. cert-manager đã Synced/Healthy.
2. `ClusterIssuer` `lakehouse-ca` đã tồn tại.
3. DNS hoặc hosts trỏ `rancher.lakehouse.local` về `192.168.49.144`.
4. ArgoCD truy cập được Git repo `https://github.com/thinh661/lakehouse_infra.git`.
5. Chart folder `charts/charts/rancher-2.14.2/` đã có trong Git.
6. Rancher version đã hỗ trợ Kubernetes version của cluster.
7. Image Rancher đã có sẵn trên node hoặc private registry nếu cluster offline.
8. Secret `tls-ca` đã tồn tại trong namespace `cattle-system` nếu dùng CA nội bộ.

Kiểm tra issuer:

```bash
kubectl get clusterissuer lakehouse-ca
kubectl describe clusterissuer lakehouse-ca
```

Tạo Secret `tls-ca` cho Rancher trust CA nội bộ. File `ca.crt` phải là root CA đã ký certificate do `lakehouse-ca` cấp:

```bash
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic tls-ca \
  --namespace cattle-system \
  --from-file=cacerts.pem=ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 4. Deploy bằng ArgoCD

Chỉ deploy khi đã xử lý vấn đề compatibility Kubernetes.

```bash
cd ~/rke2/rancher
kubectl apply -f argocd-application.yaml
```

Theo dõi:

```bash
kubectl get application rancher -n argocd
kubectl describe application rancher -n argocd
kubectl get pods -n cattle-system -o wide
kubectl get ingress -n cattle-system
kubectl get certificate -n cattle-system
kubectl get secret tls-rancher-ingress -n cattle-system
kubectl get secret tls-ca -n cattle-system
```

Truy cập UI:

```text
https://rancher.lakehouse.local
```

Lấy bootstrap password nếu không set trong values:

```bash
kubectl get secret bootstrap-secret -n cattle-system -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

Không commit bootstrap password vào Git.

---

## 5. Kiểm tra TLS cert-manager

Rancher Ingress dùng annotation:

```yaml
cert-manager.io/cluster-issuer: lakehouse-ca
```

Kiểm tra certificate:

```bash
kubectl get certificate -n cattle-system
kubectl describe certificate -n cattle-system
kubectl get secret tls-rancher-ingress -n cattle-system -o yaml
```

Kiểm tra ngày hết hạn certificate:

```bash
kubectl get secret tls-rancher-ingress -n cattle-system -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -subject -issuer -dates
```

---

## 6. Vận hành hằng ngày

Kiểm tra ArgoCD:

```bash
kubectl get application rancher -n argocd
kubectl describe application rancher -n argocd
```

Kiểm tra Rancher:

```bash
kubectl get pods -n cattle-system -o wide
kubectl get deploy -n cattle-system
kubectl logs -n cattle-system deploy/rancher --tail=200
```

Kiểm tra ingress/TLS:

```bash
kubectl get ingress -n cattle-system
kubectl describe ingress rancher -n cattle-system
kubectl get certificate,certificaterequest -n cattle-system
```

---

## 7. Upgrade bằng GitOps

Không chạy `helm upgrade` trực tiếp cho release Rancher nếu ArgoCD đã quản lý.

Quy trình:
1. Đọc release notes Rancher version mới.
2. Kiểm tra version mới support Kubernetes của cụm.
3. Pull chart mới vào `charts/rancher-<version>`.
4. Sinh `rancher.default-values.yaml` mới để so sánh.
5. Cập nhật [values-production.yaml](values-production.yaml) nếu cần.
6. Cập nhật `path` trong [argocd-application.yaml](argocd-application.yaml).
7. Commit/push và sync ArgoCD.

---

## 8. Rollback và gỡ cài đặt

Rollback chuẩn là revert commit đã đổi chart/values rồi để ArgoCD sync lại.

Không xóa namespace `cattle-system` khi chưa hiểu rõ các tài nguyên Rancher tạo ra. Nếu gỡ Rancher thật, đọc tài liệu uninstall chính thức của Rancher trước, vì Rancher có finalizer và tài nguyên quản trị cluster.