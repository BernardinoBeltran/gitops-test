module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Activar ArgoCD de forma declarativa por código
  enable_argocd = true

  argocd = {
    name          = "argocd"
    chart_version = "7.3.0"
    repository    = "https://argoproj.github.io/argo-helm"
    namespace     = "argocd"
  }
}
