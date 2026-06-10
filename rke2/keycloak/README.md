# Hướng dẫn Cài đặt và Vận hành Keycloak SSO bằng ArgoCD

Thư mục này chứa tài liệu và manifest GitOps để triển khai **Keycloak** làm giải pháp Single Sign-On (SSO) và Identity Provider (IdP) cho cụm RKE2 HA lakehouse, tích hợp với LDAP để quản trị tài khoản tập trung cho các ứng dụng dữ liệu như Airflow, JupyterHub, v.v.

Phiên bản mục tiêu:
```text
Keycloak: v26.6.2 (Quarkus-based)
Database: PostgreSQL v16 (StatefulSet)
Helm chart: vendored in Git at rke2/keycloak/charts/keycloakx-7.2.0
Namespace: keycloak
GitOps owner: ArgoCD
Domain nội bộ: keycloak.lakehouse.local
```

---

## 1. Nguyên tắc triển khai

Keycloak yêu cầu database hoạt động ổn định và lưu trữ bền vững (Persistence). Do đó, nó phụ thuộc vào **Longhorn** để cấp phát Persistent Volume (PV/PVC). 

Thứ tự triển khai khuyến nghị:
```text
RKE2 HA -> ArgoCD -> cert-manager -> Longhorn -> Keycloak -> Data applications (Airflow, JupyterHub...)
```

Trong cụm RKE2, HTTPS được phân bổ như sau:
```text
Browser HTTPS 443
  -> Bastion HAProxy 443
  -> RKE2 nodes 443
  -> Traefik websecure entrypoint
  -> Terminate TLS bằng Secret "keycloak-tls" (do cert-manager cấp)
  -> Keycloak Pod (HTTP Port 8080)
```

Keycloak được triển khai thông qua **ArgoCD Application** kết hợp multi-source:
1.  Đọc Helm chart `keycloakx` v7.2.0 đã vendor trong Git repo.
2.  Áp dụng cấu hình tùy chỉnh từ file [values-production.yaml](values-production.yaml).
3.  Áp dụng các manifest bổ sung (nhập Secrets và PostgreSQL StatefulSet) nằm trong thư mục `manifests/`.

---

## 2. Cấu trúc thư mục của Module

```text
rke2/keycloak/
  .clinerules
  README.md
  keycloak_design.md
  values-production.yaml
  keycloak.default-values.yaml
  argocd-application.yaml
  charts/
    keycloakx-7.2.0/
  manifests/
    secrets.yaml
    postgres.yaml
    realm-import.yaml
```

Vai trò của các file:
*   [values-production.yaml](values-production.yaml): File cấu hình production Helm values cho Keycloak (cấu hình ingress, proxy, DB connector, JVM resource limits, v.v.).
*   [keycloak.default-values.yaml](keycloak.default-values.yaml): Default values gốc xuất từ chart để đối chiếu khi review.
*   [argocd-application.yaml](argocd-application.yaml): Khai báo ArgoCD Application để đồng bộ Keycloak từ Git repo.
*   `charts/keycloakx-7.2.0/`: Thư mục Helm chart đã được tải về và lưu trực tiếp trong Git.
*   `manifests/secrets.yaml`: Lưu trữ Secrets cho DB password và initial bootstrap admin.
*   `manifests/postgres.yaml`: Khai báo StatefulSet, Service và PVC sử dụng ổ đĩa Longhorn cho PostgreSQL.
*   `manifests/realm-import.yaml`: ConfigMap chứa file JSON cấu hình của Realm `lakehouse`, bao gồm các Role mặc định (`Admin`, `PM`, `DE`, `DA`, `BA`, `DS`) và OIDC Clients (`airflow`, `jupyterhub`) để tự động nạp khi khởi chạy.

---

## 3. Chuẩn bị trên Bastion

SSH vào Bastion node:
```bash
ssh thinh1@192.168.49.144
```

Kiểm tra trạng thái sẵn sàng của cert-manager và Longhorn trong cụm:
```bash
# Kiểm tra ClusterIssuer lakehouse-ca của cert-manager
kubectl get clusterissuer

# Kiểm tra StorageClass longhorn
kubectl get sc
```

Đồng bộ mã nguồn từ máy Windows của bạn lên Bastion trước khi apply (chạy lệnh này từ máy Windows):
```powershell
scp -r d:\workspace_thinh1\lakehouse_infra\lakehouse_infra\rke2 thinh1@192.168.49.144:~/
```

---

## 4. Chuẩn bị Image cho Môi trường Offline (Air-gapped)

Đối với cụm RKE2 chạy offline không thể kết nối Internet để kéo Docker images, bạn phải tải trước các container images cần thiết trên máy có mạng, đóng gói và nạp vào các RKE2 node.

Các image cần thiết cho Keycloak v26.6.2:
```text
quay.io/keycloak/keycloak:26.6.2
postgres:16-alpine
docker.io/busybox:1.37
```

Thực hiện đóng gói trên máy có Internet:
```bash
docker pull quay.io/keycloak/keycloak:26.6.2
docker pull postgres:16-alpine
docker pull docker.io/busybox:1.37

docker save \
  quay.io/keycloak/keycloak:26.6.2 \
  postgres:16-alpine \
  docker.io/busybox:1.37 \
  -o keycloak-offline-images.tar
```

Copy file `.tar` lên tất cả các RKE2 node (`192.168.49.141`, `192.168.49.142`, `192.168.49.143`) và đặt vào thư mục tự động import:
```bash
sudo mkdir -p /var/lib/rancher/rke2/agent/images/
sudo cp keycloak-offline-images.tar /var/lib/rancher/rke2/agent/images/
sudo systemctl restart rke2-server   # Chạy trên server nodes lần lượt
```
*Lưu ý: Đối với node agent thì chạy `sudo systemctl restart rke2-agent`.*

---

## 5. Cấu hình repoURL trong ArgoCD Application

Mở file [argocd-application.yaml](argocd-application.yaml) và chỉnh sửa `repoURL` trỏ về Git repo của bạn (thay thế địa chỉ mẫu nếu cần):

```yaml
spec:
  sources:
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Đổi thành Git repo của bạn
      targetRevision: main
      path: rke2/keycloak/charts/keycloakx-7.2.0
      ...
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Đổi thành Git repo của bạn
      targetRevision: main
      ref: values
    - repoURL: https://github.com/thinh661/lakehouse_infra.git  # Đổi thành Git repo của bạn
      targetRevision: main
      path: rke2/keycloak/manifests
```

Hãy commit và push các thay đổi này lên Git repo của bạn trước khi apply.

---

## 6. Cài đặt Keycloak qua ArgoCD

Apply file cấu hình ứng dụng từ Bastion node:
```bash
cd ~/rke2/keycloak
kubectl apply -f argocd-application.yaml
```

ArgoCD sẽ tự động:
1.  Tạo namespace `keycloak`.
2.  Deploy các Secrets (`keycloak-db-secret`, `keycloak-admin-secret`) và ConfigMap `keycloak-realm-import`.
3.  Tạo PostgreSQL StatefulSet (`keycloak-db`) và yêu cầu Longhorn cấp PVC.
4.  Cài đặt Keycloak thông qua Helm chart đã render và kết nối tới Postgres.
5.  Tự động nạp cấu hình Realm `lakehouse` chứa các Role mặc định (`Admin`, `PM`, `DE`, `DA`, `BA`, `DS`) và các OIDC Client (`airflow`, `jupyterhub`) nhờ vào tham số `--import-realm` và volume mount.
6.  Khởi tạo Ingress Traefik và yêu cầu cert-manager cấp phát TLS Secret `keycloak-tls` bằng ClusterIssuer `lakehouse-ca`.

Theo dõi tiến trình deploy:
```bash
# Xem trạng thái ArgoCD Application
kubectl get application keycloak -n argocd

# Theo dõi các Pod khởi tạo trong namespace keycloak
kubectl get pods -n keycloak -w
```

Khi trạng thái của các Pod chuyển sang `Running` và ArgoCD báo `Synced`/`Healthy`, bạn có thể truy cập Keycloak Web UI.

---

## 7. Truy cập và Cấu hình Keycloak ban đầu

### 7.1. Cấu hình File hosts (hoặc DNS nội bộ)
Đảm bảo máy client của bạn trỏ tên miền về Bastion HAProxy IP `192.168.49.144` trong file `C:\Windows\System32\drivers\etc\hosts`:
```text
192.168.49.144 keycloak.lakehouse.local
```

### 7.2. Đăng nhập Admin Console
1.  Truy cập: `https://keycloak.lakehouse.local/auth/admin/`
2.  Đăng nhập bằng thông tin khởi tạo cấu hình trong `manifests/secrets.yaml`:
    *   **Username:** `admin`
    *   **Password:** `KeycloakAdminPass123!`
3.  *Lưu ý bảo mật:* Đổi mật khẩu hoặc tạo tài khoản admin vĩnh viễn mới ngay lập tức và lưu thông tin đăng nhập an toàn.

---

## 8. Cấu hình User Federation (LDAP) trên UI

Để đồng bộ tài khoản người dùng từ LDAP vào Keycloak:

1.  Tại giao diện Keycloak Admin Console, chọn Realm muốn quản lý (hoặc tạo Realm mới tên `lakehouse`).
2.  Chọn menu **User Federation** -> Nhấn **Add Ldap Provider**.
3.  Điền các thông số kết nối:
    *   **Console Display Name:** `lakehouse-ldap`
    *   **Edit Mode:** `READ_ONLY` (Nếu chỉ muốn Keycloak đọc thông tin, không ghi ngược lại LDAP).
    *   **Vendor:** Chọn `Active Directory` hoặc `Other` (nếu dùng OpenLDAP).
    *   **Connection URL:** `ldap://<ldap-server-ip>:389`
    *   **Users DN:** `ou=users,dc=lakehouse,dc=local` (tùy thuộc cấu trúc LDAP của bạn).
    *   **Bind DN:** `cn=admin,dc=lakehouse,dc=local`
    *   **Bind Credential:** Mật khẩu tài khoản admin LDAP.
4.  Nhấn nút **Test Connection** và **Test Authentication** để đảm bảo thông tới LDAP.
5.  Tại mục **Sync Settings**, bật **Periodic Full Sync** và thiết lập thời gian (ví dụ: `86400` giây cho 24h) và **Periodic Changed Users Sync** (ví dụ: `900` giây cho 15 phút).
6.  Chọn tab **Mappers** để cấu hình ánh xạ thuộc tính người dùng và đồng bộ Group LDAP thành Roles của Keycloak.

---

## 9. Hướng dẫn tích hợp SSO cho Data Applications

Sau khi Keycloak đã liên kết thành công với LDAP, bạn cấu hình tích hợp SSO cho các ứng dụng dữ liệu qua giao thức OpenID Connect (OIDC).

### 9.1. Tích hợp SSO cho Apache Airflow

#### Bước 1: Tạo Client trong Keycloak
1.  Vào Realm `lakehouse` -> Chọn **Clients** -> Chọn **Create client**.
2.  Điền thông tin:
    *   **Client ID:** `airflow`
    *   **Client Protocol:** `openid-connect`
3.  Tại màn hình cấu hình Client:
    *   **Capability config:** Bật `Client authentication` sang `ON` (để dùng Client Secret - Confidential Access Type).
    *   **Valid Redirect URIs:** `https://airflow.lakehouse.local/oauth-authorized/keycloak`
    *   **Web Origins:** `https://airflow.lakehouse.local`
4.  Lưu cấu hình, chuyển sang tab **Credentials** và sao chép **Client Secret**.
5.  Vào tab **Client scopes** -> Click Scope `<client-id>-dedicated` -> Chọn **Add mapper** -> **User Client Role** hoặc **Group Membership** để đưa thông tin nhóm của user vào ID Token (claim tên `roles` hoặc `groups`).

#### Bước 2: Cấu hình `webserver_config.py` của Airflow
Thêm cấu hình xác thực OAuth/OIDC vào file `webserver_config.py` của bạn:

```python
from flask_appbuilder.security.manager import AUTH_OID, AUTH_OAUTH
import os

AUTH_TYPE = AUTH_OAUTH
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = "Viewer" # Vai trò mặc định cho user mới sync

# Keycloak OIDC Configuration
OAUTH_PROVIDERS = [
    {
        'name': 'keycloak',
        'icon': 'fa-key',
        'token_key': 'access_token',
        'remote_app': {
            'client_id': 'airflow',
            'client_secret': 'SAO_CHEP_SECRET_TU_KEYCLOAK_UI',
            'api_base_url': 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/',
            'client_kwargs': {
                'scope': 'openid email profile'
            },
            'access_token_url': 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/token',
            'authorize_url': 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/auth',
            'jwks_uri': 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/certs'
        }
    }
]

# Ánh xạ Roles từ Keycloak Claim sang Airflow Roles
# Keycloak gửi group/role qua token, Custom Security Manager sẽ map sang FAB roles
# (Có thể viết một Custom Security Manager trong Airflow để parse Token)
```

---

### 9.2. Tích hợp SSO cho JupyterHub

#### Bước 1: Tạo Client trong Keycloak
1.  Realm `lakehouse` -> **Clients** -> **Create client**.
2.  Cấu hình:
    *   **Client ID:** `jupyterhub`
    *   **Client authentication:** `ON`
    *   **Valid Redirect URIs:** `https://jupyterhub.lakehouse.local/hub/oauth_callback`
3.  Lưu lại và lấy **Client Secret** tại tab **Credentials**.

#### Bước 2: Cấu hình `jupyterhub_config.py`
Sử dụng gói `oauthenticator.generic` để cấu hình JupyterHub xác thực OIDC:

```python
c.JupyterHub.authenticator_class = 'oauthenticator.generic.GenericOAuthenticator'

# Cấu hình OIDC Endpoint của Keycloak
c.GenericOAuthenticator.oauth_callback_url = 'https://jupyterhub.lakehouse.local/hub/oauth_callback'
c.GenericOAuthenticator.client_id = 'jupyterhub'
c.GenericOAuthenticator.client_secret = 'SAO_CHEP_SECRET_TU_KEYCLOAK_UI'

c.GenericOAuthenticator.authorize_url = 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/auth'
c.GenericOAuthenticator.token_url = 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/token'
c.GenericOAuthenticator.userdata_url = 'https://keycloak.lakehouse.local/auth/realms/lakehouse/protocol/openid-connect/userinfo'

c.GenericOAuthenticator.username_key = 'preferred_username'
c.GenericOAuthenticator.userdata_params = {'state': 'state'}
c.GenericOAuthenticator.scope = ['openid', 'profile', 'email']

# Phân quyền Admin trong JupyterHub dựa trên Group của Keycloak
c.GenericOAuthenticator.admin_groups = {'/data_admin'} # Group path trong Keycloak
c.GenericOAuthenticator.allowed_groups = {'/data_admin', '/data_engineer', '/data_analyst'}
```

---

## 10. Vận hành Hàng ngày

### 10.1. Kiểm tra trạng thái Keycloak và Postgres
```bash
# Xem Pods và Nodes đang chạy trên đó
kubectl get pods -n keycloak -o wide

# Xem logs của Keycloak để debug lỗi xác thực
kubectl logs -n keycloak statefulset/keycloak -c keycloak --tail=200

# Xem logs của PostgreSQL
kubectl logs -n keycloak statefulset/keycloak-db --tail=200
```

### 10.2. Truy cập vào cơ sở dữ liệu PostgreSQL để kiểm tra
```bash
# Chạy terminal psql trực tiếp trong pod database
kubectl exec -it keycloak-db-0 -n keycloak -- psql -U keycloak -d keycloak
```

---

## 11. Sao lưu và Khôi phục (Backup & Restore)

### 11.1. Backup Database PostgreSQL
Chạy lệnh backup cơ sở dữ liệu Postgres định kỳ lên Bastion node:
```bash
mkdir -p ~/rke2/backups/keycloak
kubectl exec -t keycloak-db-0 -n keycloak -- pg_dump -U keycloak -d keycloak > ~/rke2/backups/keycloak/keycloak_db_backup_$(date +%F).sql
```

### 11.2. Restore Database
Trường hợp cần khôi phục lại dữ liệu Postgres:
```bash
# Copy file backup vào pod database
kubectl cp ~/rke2/backups/keycloak/keycloak_db_backup_<date>.sql keycloak/keycloak-db-0:/tmp/backup.sql

# Restore dữ liệu qua psql
kubectl exec -it keycloak-db-0 -n keycloak -- psql -U keycloak -d keycloak -f /tmp/backup.sql
```

---

## 12. Hướng dẫn Migration sang cụm PostgreSQL HA

Khi bạn đã xây dựng xong một cụm PostgreSQL HA độc lập (ví dụ sử dụng CloudNativePG Operator hoặc một cụm PostgreSQL VM bên ngoài), hãy thực hiện theo các bước sau để di chuyển dữ liệu và chuyển cấu hình Keycloak:

### Bước 1: Trích xuất (Dump) dữ liệu từ Postgres local hiện tại
Chạy lệnh dump dữ liệu tại Bastion node:
```bash
kubectl exec -t keycloak-db-0 -n keycloak -- pg_dump -U keycloak -d keycloak > ~/rke2/backups/keycloak/keycloak_migration.sql
```

### Bước 2: Chuẩn bị cụm PostgreSQL HA mới
1. Đảm bảo cụm PostgreSQL HA đã được cài đặt và đang chạy.
2. Tạo database tên là `keycloak`.
3. Tạo user và password trùng khớp (hoặc tạo mới và cập nhật trong secret sau).
4. Cấp quyền sở hữu database `keycloak` cho user vừa tạo.

### Bước 3: Khôi phục (Restore) dữ liệu vào cụm HA mới
Sử dụng client `psql` trên Bastion hoặc trực tiếp từ database node để import tệp SQL:
```bash
# Đối với PostgreSQL HA chạy trong K8s (ví dụ qua CloudNativePG)
# Copy file SQL vào pod primary của cụm mới rồi chạy import:
kubectl cp ~/rke2/backups/keycloak/keycloak_migration.sql <new-pg-ha-namespace>/<new-pg-ha-pod-0>:/tmp/migration.sql
kubectl exec -it <new-pg-ha-pod-0> -n <new-pg-ha-namespace> -- psql -U keycloak -d keycloak -f /tmp/migration.sql
```

### Bước 4: Cập nhật cấu hình GitOps
Chỉnh sửa cấu hình trong Git repo của bạn:
1.  **Cập nhật Values file (`values-production.yaml`):**
    Thay đổi hostname trỏ về Service của cụm PostgreSQL HA mới:
    ```yaml
    database:
      hostname: postgres-ha-rw.database.svc.cluster.local # Địa chỉ Service của cụm HA mới
      port: 5432
      database: keycloak
      username: keycloak
      existingSecret: keycloak-db-secret # Secret chứa mật khẩu DB mới
    ```
2.  **Cập nhật Secret (`manifests/secrets.yaml`):**
    Cập nhật mật khẩu database mới (nếu có thay đổi).
3.  **Loại bỏ Database local:**
    Xóa file `manifests/postgres.yaml` khỏi repo Git của bạn. ArgoCD khi sync có bật `prune: true` sẽ tự động xóa StatefulSet và Service PostgreSQL local cũ để giải phóng tài nguyên.

### Bước 5: Commit và Sync
Đẩy các thay đổi lên Git. ArgoCD sẽ tự động:
1. Xóa bỏ cụm PostgreSQL cũ (`keycloak-db`).
2. Thực hiện Rolling Update các Pod Keycloak. Các Pod Keycloak mới khởi chạy sẽ kết nối thẳng tới cụm PostgreSQL HA mới thông qua cấu hình Service/DNS vừa cập nhật.

---

## 13. Gỡ bỏ cài đặt (Uninstall)

Để xóa toàn bộ Keycloak, Postgres và các cấu hình liên quan:
1.  Xóa Application `keycloak` khỏi ArgoCD bằng giao diện UI hoặc chạy lệnh:
    ```bash
    kubectl delete -f argocd-application.yaml
    ```
2.  Kiểm tra và xóa thủ công namespace nếu còn tồn tại:
    ```bash
    kubectl delete namespace keycloak
    ```
3.  *Lưu ý dữ liệu:* Mặc định, volumeClaimTemplates của StatefulSet DB sẽ giữ lại PVC trên Longhorn để bảo vệ dữ liệu. Nếu bạn thực sự muốn xóa sạch dữ liệu, hãy chạy lệnh xóa PVC:
    ```bash
    kubectl get pvc -n keycloak
    kubectl delete pvc <db-data-pvc-name> -n keycloak
    ```
