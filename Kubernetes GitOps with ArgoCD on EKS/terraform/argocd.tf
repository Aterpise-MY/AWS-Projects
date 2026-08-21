# ---------------------------------------------------------------------------
# ArgoCD control plane, installed via the community argo-cd Helm chart.
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # Wait for all ArgoCD components (and their CRDs) to be Ready before the
  # argocd-apps release below tries to create an Application resource.
  wait    = true
  timeout = 600

  values = [
    yamlencode({
      # ClusterIP keeps the API server private; reach the UI with
      # `kubectl port-forward`. Switch to LoadBalancer for a public endpoint.
      server = {
        service = {
          type = "ClusterIP"
        }
      }
      # Trim the demo footprint — no HA, single replica per component.
      redis-ha       = { enabled = false }
      controller     = { replicas = 1 }
      applicationSet = { replicas = 1 }
      repoServer     = { replicas = 1 }
    })
  ]

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# GitOps sample Application, delivered declaratively through the argocd-apps
# chart. Using this chart (rather than a kubernetes_manifest) avoids the
# chicken-and-egg problem where the Application CRD does not yet exist at plan
# time on a brand-new cluster.
# ---------------------------------------------------------------------------
resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  namespace = var.argocd_namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2"

  values = [
    yamlencode({
      applications = {
        sample-app = {
          namespace = var.argocd_namespace
          project   = "default"
          source = {
            repoURL        = var.gitops_repo_url
            targetRevision = var.gitops_target_revision
            path           = var.gitops_path
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = var.gitops_dest_namespace
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      }
    })
  ]

  depends_on = [helm_release.argocd]
}
