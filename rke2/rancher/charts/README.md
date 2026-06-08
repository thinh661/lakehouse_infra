# Vendored Rancher Helm Chart

Thư mục này chứa Helm chart Rancher đã tải sẵn để ArgoCD có thể render chart từ Git repo, không cần truy cập Internet khi sync.

Phiên bản mục tiêu hiện tại:

```text
Rancher chart: 2.14.2
Rancher appVersion: v2.14.2
Upstream chart repo: https://releases.rancher.com/server-charts/latest
Vendored path hiện tại: rke2/rancher/charts/charts/rancher-2.14.2
```

Lưu ý tương thích quan trọng: chart `2.14.2` khai báo `kubeVersion: < 1.36.0-0`. Cụm hiện tại đang là RKE2/Kubernetes `v1.36.1`, nên chưa nên deploy Rancher thật cho tới khi Rancher phát hành chart hỗ trợ Kubernetes 1.36.

Tải chart trên máy có Internet/WSL:

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

Với cấu trúc hiện tại, chart đang nằm tại `charts/charts/rancher-2.14.2/` và default values đang nằm tại `charts/rancher.default-values.yaml`. ArgoCD Application đã trỏ theo cấu trúc thực tế này.