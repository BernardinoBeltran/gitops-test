data "aws_availability_zones" "available" {}

# Documentación del módulo VPC: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8.0"

  name = "eks-learn-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    Environment = "learning"
    Terraform   = "true"
  }
}

# Crear un Gateway Endpoint de S3 gratuito de forma nativa para no pagar costes de NAT Gateway al descargar el HTML
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)

  tags = {
    Name        = "${var.cluster_name}-s3-endpoint"
    Environment = "learning"
  }
}

