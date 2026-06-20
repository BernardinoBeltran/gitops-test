module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.15.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Habilitar permisos de administrador para la identidad de IAM creadora del clúster
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2

      labels = {
        Environment = "learning"
      }
    }
  }

  tags = {
    Environment = "learning"
    Terraform   = "true"
  }
}
