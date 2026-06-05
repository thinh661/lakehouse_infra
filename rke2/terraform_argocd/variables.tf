variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Duong dan den file kubeconfig cua cum RKE2"
}

variable "argocd_chart_version" {
  type        = string
  default     = "9.5.17"
  description = "Phien ban Helm chart cua ArgoCD"
}

variable "argocd_domain" {
  type        = string
  default     = "argocd.lakehouse.local"
  description = "Ten mien truy cap ArgoCD UI"
}

variable "argocd_ha_enabled" {
  type        = bool
  default     = false
  description = "Kich hoat che do High Availability (HA) cho Redis va cac component"
}

variable "argocd_server_replicas" {
  type        = number
  default     = 1
  description = "So luong replica cho ArgoCD Server (Mac dinh 1 neu khong chay HA)"
}

variable "argocd_repo_server_replicas" {
  type        = number
  default     = 1
  description = "So luong replica cho ArgoCD Repo Server (Mac dinh 1 neu khong chay HA)"
}
