# 1. Generar contraseña aleatoria segura
resource "random_password" "opensearch_password" {
  length           = 16
  special          = true
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!@#$%" # Caracteres especiales válidos para OpenSearch
}

# 2. Guardar la contraseña en AWS Systems Manager Parameter Store como SecureString
resource "aws_ssm_parameter" "opensearch_admin_password" {
  name        = "/eks/learning/opensearch/admin_password"
  description = "Contraseña maestra para OpenSearch Dashboards (EKS Logs)"
  type        = "SecureString"
  value       = random_password.opensearch_password.result
}

# 3. Grupo de Seguridad para OpenSearch (Permite tráfico de la VPC por el puerto 443)
resource "aws_security_group" "opensearch_sg" {
  name        = "${var.cluster_name}-opensearch-sg"
  vpc_id      = module.vpc.vpc_id
  description = "Grupo de seguridad para el dominio de OpenSearch"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # Permite tráfico de cualquier pod/nodo de EKS dentro de la VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-opensearch-sg"
    Environment = "learning"
  }
}

# 4. Dominio de Amazon OpenSearch Service (Despliegue privado en subred de la VPC)
resource "aws_opensearch_domain" "opensearch" {
  domain_name    = "eks-logs-domain"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = "t3.medium.search"
    instance_count         = 1
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 10
  }

  # Colocamos OpenSearch dentro de nuestra subred privada para máxima seguridad
  vpc_options {
    subnet_ids         = [module.vpc.private_subnets[0]]
    security_group_ids = [aws_security_group.opensearch_sg.id]
  }

  # Cifrado de datos en tránsito y reposo (Buenas prácticas de AWS)
  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # Habilitar el control de acceso de grano fino para usar usuario y contraseña en Dashboards
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = "admin"
      master_user_password = random_password.opensearch_password.result
    }
  }

  tags = {
    Environment = "learning"
    Project     = "gitops-monitoring"
  }
}

# 5. Política de IAM que permite a Fluent Bit escribir logs en OpenSearch
resource "aws_iam_policy" "opensearch_write_policy" {

  name        = "${var.cluster_name}-opensearch-write-policy"
  description = "Permite a Fluent Bit publicar logs en Amazon OpenSearch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "es:ESHttp*"
        ]
        Resource = [
          aws_opensearch_domain.opensearch.arn,
          "${aws_opensearch_domain.opensearch.arn}/*"
        ]
      }
    ]
  })
}

# 4. Relación de confianza (Trust Policy) para la ServiceAccount 'fluent-bit-sa' en el namespace 'logging'
data "aws_iam_policy_document" "opensearch_irsa_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:logging:fluent-bit-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

# 5. Crear el Rol de IAM para Fluent Bit IRSA
resource "aws_iam_role" "opensearch_irsa_role" {
  name               = "${var.cluster_name}-opensearch-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.opensearch_irsa_assume_role_policy.json
}

# 6. Adjuntar la política de escritura al rol
resource "aws_iam_role_policy_attachment" "opensearch_irsa_attach" {
  role       = aws_iam_role.opensearch_irsa_role.name
  policy_arn = aws_iam_policy.opensearch_write_policy.arn
}

# 7. Outputs para configurar la aplicación en Kubernetes
output "opensearch_endpoint" {
  description = "Dirección interna (VPC) de OpenSearch (para configmap de Fluent Bit)"
  value       = aws_opensearch_domain.opensearch.endpoint
}

output "opensearch_iam_role_arn" {
  description = "ARN del rol de IAM para Fluent Bit (para serviceaccount de Fluent Bit)"
  value       = aws_iam_role.opensearch_irsa_role.arn
}
