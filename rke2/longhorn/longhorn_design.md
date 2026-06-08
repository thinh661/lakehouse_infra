# Tài liệu Thiết kế Longhorn cho cụm RKE2 Lakehouse

Tài liệu này mô tả cách triển khai Longhorn bằng ArgoCD trong cụm RKE2 lakehouse, theo cùng mô hình GitOps/offline-friendly đang dùng cho cert-manager và Rancher.

---

## 1. Mục tiêu

Longhorn cung cấp distributed block storage cho các PVC trong cụm lakehouse. Mỗi RKE2 server có một disk rời `/dev/sdb` dung lượng 20GB, sẽ được format/mount vào `/var/lib/longhorn` để Longhorn dùng làm vùng lưu replica.

Mục tiêu triển khai:
* Cài Longhorn bằng ArgoCD Application riêng.
* Vendor Helm chart Longhorn vào Git repo để ArgoCD không cần Internet khi sync.
* Dùng `/dev/sdb` trên cả 3 node làm disk storage cho Longhorn.
* Tạo StorageClass `longhorn` mặc định với replica count 3.
* Expose Longhorn UI tại `https://longhorn.lakehouse.local` qua Traefik và cert-manager.

---

## 2. Kiến trúc lưu trữ

Chuẩn bị host:

```text
rke2_server_1  /dev/sdb 20GB -> /var/lib/longhorn
rke2_server_2  /dev/sdb 20GB -> /var/lib/longhorn
rke2_server_3  /dev/sdb 20GB -> /var/lib/longhorn
```

Longhorn V1 data engine dùng filesystem path, không trực tiếp quản lý raw disk bằng Helm. Vì vậy `/dev/sdb` phải được format ext4 và mount ổn định qua `/etc/fstab` trước khi ArgoCD sync Longhorn.

Sau khi Longhorn chạy, mỗi volume mặc định có 3 replica, một replica trên mỗi node nếu cluster đủ healthy disk.

---

## 3. Kiến trúc truy cập UI

Luồng truy cập Longhorn UI:

```text
Browser
  -> https://longhorn.lakehouse.local:443
  -> Bastion HAProxy 192.168.49.144:443
  -> RKE2 node 443
  -> Traefik websecure
  -> Ingress longhorn
  -> TLS Secret longhorn-ui-tls do cert-manager tạo
  -> Service longhorn-frontend
  -> Longhorn UI pods trong namespace longhorn-system
```

TLS được cấp bởi cert-manager `ClusterIssuer` `lakehouse-ca`.

---

## 4. GitOps và offline model

Phiên bản chart được chuẩn bị:

```text
Longhorn chart: 1.12.0
Longhorn appVersion: v1.12.0
Chart kubeVersion: >=1.25.0-0
Vendored path: rke2/longhorn/charts/longhorn-1.12.0
Default values: rke2/longhorn/longhorn.default-values.yaml
```

ArgoCD Application dùng multi-source:
* Source 1: chart đã vendor tại `rke2/longhorn/charts/longhorn-1.12.0`.
* Source 2: cùng Git repo với `ref: values`, dùng `$values/rke2/longhorn/values-production.yaml`.

Với môi trường offline, chart trong Git chưa đủ. Node hoặc private registry nội bộ vẫn phải có tất cả image Longhorn, CSI sidecar và busybox test image nếu dùng manifest test.

---

## 5. Cấu hình production baseline

Các quyết định chính trong `values-production.yaml`:
* `defaultSettings.defaultDataPath: /var/lib/longhorn`.
* `defaultSettings.createDefaultDiskLabeledNodes: true` để chỉ tạo disk mặc định trên node được label rõ ràng.
* `persistence.defaultClassReplicaCount: 3` cho HA replica trên 3 node.
* `persistence.volumeBindingMode: WaitForFirstConsumer` để scheduler có thêm ngữ cảnh workload.
* `preUpgradeChecker.jobEnabled: false` vì Longhorn chart khuyến nghị disable pre-upgrade checker khi cài bằng GitOps/ArgoCD.
* `defaultSettings.upgradeChecker: false` và `allowCollectingLonghornUsageMetrics: false` cho môi trường offline/nội bộ.
* Ingress UI dùng Traefik + cert-manager.

---

## 6. RWX volume

Longhorn hỗ trợ PVC `ReadWriteMany` bằng Longhorn Share Manager. Khi một PVC dùng StorageClass `longhorn` với access mode `ReadWriteMany`, Longhorn tạo một share-manager pod để export volume qua NFS nội bộ cho nhiều workload mount cùng lúc.

Điều kiện để RWX hoạt động trong cụm này:
* Node Kubernetes có `nfs-common` để mount NFS client.
* Image `longhornio/longhorn-share-manager:v1.12.0` có sẵn trong môi trường offline hoặc private registry.
* StorageClass `longhorn` còn dùng data engine `v1`.
* Network nội bộ giữa pod workload và share-manager không bị chặn.

Playbook `playbooks/prepare-longhorn-disks.yml` đã cài `nfs-common`, nên phía host đã được chuẩn bị cho RWX. Manifest `examples/test-pvc.yaml` tạo PVC `ReadWriteMany` và 2 pod mount chung để kiểm tra thực tế.

---

## 7. Rủi ro vận hành

* Format `/dev/sdb` là thao tác phá dữ liệu. Chỉ chạy playbook với `longhorn_format_disk=true` khi đã chắc chắn disk trống.
* Nếu `/var/lib/longhorn` chưa mount đúng vào `/dev/sdb`, Longhorn có thể ghi replica lên root filesystem.
* Không gỡ Longhorn bằng cách xóa namespace khi còn volume/PVC quan trọng.
* Với disk 20GB/node và replica 3, dung lượng usable thực tế xấp xỉ dung lượng một node sau khi trừ reserved/minimal available.
* RWX volume cần `nfs-common`; RWO block volume cần `open-iscsi`/`iscsid` hoạt động trên node.