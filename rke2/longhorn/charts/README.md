# Vendored Longhorn Chart

Chart Longhorn được lưu trong repo để ArgoCD có thể render từ Git, không tự pull chart từ Internet khi sync.

Phiên bản hiện tại:

```text
chart: longhorn
version: 1.12.0
appVersion: v1.12.0
kubeVersion: >=1.25.0-0
path: rke2/longhorn/charts/longhorn-1.12.0
```

Lệnh pull lại chart:

```bash
cd rke2/longhorn
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm pull longhorn/longhorn --version 1.12.0 --untar --untardir charts
mv charts/longhorn charts/longhorn-1.12.0
helm show values charts/longhorn-1.12.0 > longhorn.default-values.yaml
```

Không chỉnh trực tiếp file trong chart vendored trừ khi có lý do rõ ràng. Cấu hình môi trường nằm ở `../values-production.yaml`.