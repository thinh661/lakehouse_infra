output "argocd_url" {
  value       = "https://${var.argocd_domain}"
  description = "Duong dan truy cap giao dien ArgoCD UI"
}

output "argocd_get_password_command" {
  value       = "kubectl -n ${kubernetes_namespace.argocd.metadata[0].name} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
  description = "Cau lenh chay tren Bastion de lay mat khau admin khoi tao cua ArgoCD"
}
