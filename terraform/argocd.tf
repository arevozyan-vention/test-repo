resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
      }
      dex = {
        enabled = false
      }
      server = {
        ingress = {
          enabled          = true
          ingressClassName = "traefik"
          hostname         = "argocd.localhost"
          annotations = {
            "cert-manager.io/cluster-issuer" = "local-ca"
          }
          tls = true
        }
      }
    })
  ]
}

resource "helm_release" "root_app" {
  name       = "root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = helm_release.argocd.namespace

  values = [
    yamlencode({
      applications = {
        root = {
          project = "default"
          source = {
            repoURL        = var.repo_url
            targetRevision = var.revision
            path           = "argocd/apps"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
          }
        }
      }
    })
  ]
}
