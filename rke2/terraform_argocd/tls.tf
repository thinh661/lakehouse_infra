# ============================================================
# tls.tf — Tao chung chi TLS tu ky (Self-Signed Certificate)
# Su dung: Traefik dung de terminate HTTPS cho ArgoCD UI
# Thoi han: 10 nam (3650 ngay) — khong can lo het han som
# ============================================================

resource "tls_private_key" "argocd" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Tao chung chi self-signed, hieu luc 10 nam
resource "tls_self_signed_cert" "argocd" {
  private_key_pem = tls_private_key.argocd.private_key_pem

  subject {
    common_name  = var.argocd_domain
    organization = "Lakehouse Internal"
  }

  # 3650 ngay = 10 nam
  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [var.argocd_domain]
}

# Luu cert va private key vao Kubernetes Secret de Traefik su dung
resource "kubernetes_secret" "argocd_tls" {
  metadata {
    name      = "argocd-server-tls"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.argocd.cert_pem
    "tls.key" = tls_private_key.argocd.private_key_pem
  }

  depends_on = [kubernetes_namespace.argocd]
}
