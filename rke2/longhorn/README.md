# Hướng dẫn Cài đặt và Vận hành Longhorn bằng ArgoCD

Module này triển khai Longhorn theo mô hình GitOps/offline-friendly: Helm chart được tải sẵn vào Git repo, ArgoCD render chart từ Git, host disk `/dev/sdb` được mount vào `/var/lib/longhorn` trước khi cài.

Phiên bản mục tiêu:

```text
Longhorn chart: 1.12.0
Longhorn appVersion: v1.12.0
Namespace: longhorn-system
StorageClass: longhorn
Default data path: /var/lib/longhorn
UI hostname: longhorn.lakehouse.local
```

---

## 1. Cấu trúc file

```text
rke2/longhorn/
  .clinerules
  README.md
  longhorn_design.md
  values-production.yaml
  argocd-application.yaml
  longhorn.default-values.yaml
  charts/
    longhorn-1.12.0/
  playbooks/
    prepare-longhorn-disks.yml
  examples/
    test-pvc.yaml
```

---

## 2. Chuẩn bị disk `/dev/sdb`

Longhorn không tự format/mount raw disk host bằng Helm. Trước khi sync ArgoCD, chạy playbook chuẩn bị disk trên 3 node RKE2:

```bash
cd rke2/ansible_init
ansible-playbook -i inventory.ini ../longhorn/playbooks/prepare-longhorn-disks.yml \
  -e longhorn_format_disk=true
```

Playbook sẽ:
* Cài `open-iscsi`, `nfs-common`, `e2fsprogs`, `util-linux`.
* Enable/start `iscsid`.
* Format `/dev/sdb` thành ext4 nếu disk chưa có filesystem và bạn truyền `longhorn_format_disk=true`.
* Mount disk vào `/var/lib/longhorn` bằng UUID trong `/etc/fstab`.

Kiểm tra sau khi chạy:

```bash
ansible rke2_servers -i inventory.ini -b -m shell -a 'findmnt /var/lib/longhorn && df -h /var/lib/longhorn && lsblk /dev/sdb'
```

---

## 3. Label node cho default disk

Vì `values-production.yaml` bật `createDefaultDiskLabeledNodes: true`, hãy label 3 node trước khi Longhorn tạo default disk:

```bash
kubectl label node rke2-node1 node.longhorn.io/create-default-disk=true --overwrite
kubectl label node rke2-node2 node.longhorn.io/create-default-disk=true --overwrite
kubectl label node rke2-node3 node.longhorn.io/create-default-disk=true --overwrite
```

Nếu node name thực tế khác inventory alias, lấy danh sách bằng:

```bash
kubectl get nodes -o wide
```

---

## 4. Deploy bằng ArgoCD

```bash
cd rke2/longhorn
kubectl apply -f argocd-application.yaml
```

Theo dõi:

```bash
kubectl get application longhorn -n argocd
kubectl get pods -n longhorn-system -o wide
kubectl get storageclass
kubectl get ingress -n longhorn-system
kubectl get certificate -n longhorn-system
```

Truy cập UI:

```text
https://longhorn.lakehouse.local
```

---

## 5. Kiểm tra PVC RWX

Sau khi Longhorn Healthy, tạo PVC test `ReadWriteMany`. Longhorn sẽ tạo share-manager để export volume qua NFS nội bộ, vì vậy các node phải có `nfs-common` từ playbook chuẩn bị host.

```bash
kubectl apply -f examples/test-pvc.yaml
kubectl get pvc longhorn-test-rwx-pvc
kubectl get pod longhorn-test-rwx-writer-a longhorn-test-rwx-writer-b -o wide
kubectl logs longhorn-test-rwx-writer-a
kubectl logs longhorn-test-rwx-writer-b
kubectl exec longhorn-test-rwx-writer-a -- ls -l /data
kubectl get sharemanagers.longhorn.io -n longhorn-system
```

Xóa test:

```bash
kubectl delete -f examples/test-pvc.yaml
```

Nếu PVC RWX bị Pending hoặc pod mount lỗi, kiểm tra theo thứ tự: `nfs-common` trên node, image `longhornio/longhorn-share-manager:v1.12.0`, pod share-manager trong namespace `longhorn-system`, và event của PVC/pod.

---

## 6. Vận hành hằng ngày

Kiểm tra cluster Longhorn:

```bash
kubectl get pods -n longhorn-system -o wide
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
kubectl get engineimages.longhorn.io -n longhorn-system
```

Kiểm tra disk node:

```bash
kubectl get nodes.longhorn.io -n longhorn-system -o yaml
```

Kiểm tra StorageClass:

```bash
kubectl describe storageclass longhorn
```

---

## 7. Offline images

Chart đã nằm trong Git, nhưng image vẫn phải có sẵn trong node/private registry. Các nhóm image chính:
* `longhornio/longhorn-engine:v1.12.0`
* `longhornio/longhorn-manager:v1.12.0`
* `longhornio/longhorn-ui:v1.12.0`
* `longhornio/longhorn-instance-manager:v1.12.0`
* `longhornio/longhorn-share-manager:v1.12.0`
* `longhornio/backing-image-manager:v1.12.0`
* CSI sidecars trong `longhorn.default-values.yaml`.

Nếu dùng private registry, cấu hình `global.imageRegistry` hoặc registry từng image trong `values-production.yaml`.

---

## 8. Upgrade và rollback

Không chạy `helm upgrade` trực tiếp nếu ArgoCD quản lý Longhorn.

Quy trình upgrade:
1. Đọc Longhorn release notes và upgrade path.
2. Pull chart mới vào `charts/longhorn-<version>`.
3. Sinh default values mới để so sánh.
4. Cập nhật `values-production.yaml` và `argocd-application.yaml`.
5. Commit/push rồi sync ArgoCD.

Rollback cần đọc tài liệu Longhorn cho version cụ thể. Storage system có state trên disk, vì vậy không rollback chart bừa khi đã có volume quan trọng.