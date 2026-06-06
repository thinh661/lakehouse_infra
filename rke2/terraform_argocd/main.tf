terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  wait            = true
  timeout         = 600
  cleanup_on_fail = true

  values = [
    <<-EOT
    global:
      domain: ${var.argocd_domain}

    configs:
      params:
        server.insecure: "true"

    # Cau hinh Redis HA (yeu cau toi thieu 3 nodes vi co luat anti-affinity)
    redis-ha:
      enabled: ${var.argocd_ha_enabled}

    # Cấu hình tài nguyên và replicas cho từng component
    controller:
      replicas: 1
      resources:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 250m
          memory: 256Mi

    dex:
      resources:
        limits:
          cpu: 200m
          memory: 256Mi
        requests:
          cpu: 100m
          memory: 128Mi

    server:
      replicas: ${var.argocd_server_replicas}
      resources:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 125m
          memory: 128Mi
      ingress:
        enabled: true
        ingressClassName: traefik
        hosts:
          - ${var.argocd_domain}
        paths:
          - /
        pathType: Prefix
        annotations:
          traefik.ingress.kubernetes.io/router.entrypoints: websecure
          traefik.ingress.kubernetes.io/router.tls: "true"
        tls:
          - secretName: ${kubernetes_secret.argocd_tls.metadata[0].name}
            hosts:
              - ${var.argocd_domain}


    repoServer:
      replicas: ${var.argocd_repo_server_replicas}
      resources:
        limits:
          cpu: 1000m
          memory: 1024Mi
        requests:
          cpu: 250m
          memory: 256Mi

    applicationSet:
      replicas: ${var.argocd_ha_enabled ? 2 : 1}
      resources:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 250m
          memory: 256Mi

    notifications:
      resources:
        limits:
          cpu: 200m
          memory: 256Mi
        requests:
          cpu: 100m
          memory: 128Mi
    EOT
  ]
}
