variable "aws_region" {
  description = "Región de AWS para desplegar los recursos"
  type        = string
  default     = "eu-north-1"
}

variable "cluster_name" {
  description = "Nombre del clúster de EKS"
  type        = string
  default     = "eks-learn-cluster"
}

variable "vpc_cidr" {
  description = "Rango de red CIDR para la VPC"
  type        = string
  default     = "10.0.0.0/16"
}
