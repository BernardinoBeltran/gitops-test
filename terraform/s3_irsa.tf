# 1. Bucket de S3 para alojar el contenido HTML
resource "aws_s3_bucket" "html_bucket" {
  bucket_prefix = "eks-html-content-"
  force_destroy = true # Permite destruir el bucket aunque tenga archivos dentro

  tags = {
    Environment = "learning"
    ManagedBy   = "terraform"
  }
}

# 2. Bloquear acceso público directo al bucket (para asegurar que solo el Pod con permisos de IAM pueda entrar)
resource "aws_s3_bucket_public_access_block" "html_bucket_block" {
  bucket = aws_s3_bucket.html_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. Subir el archivo index.html por defecto a S3
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.html_bucket.id
  key          = "index.html"
  content      = <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>App S3 con IRSA</title>
  <style>
    body { 
      background-color: #e6ffec; 
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
      text-align: center; 
      padding-top: 100px;
      margin: 0;
    }
    .container {
      background: white;
      display: inline-block;
      padding: 40px;
      border-radius: 12px;
      box-shadow: 0 4px 15px rgba(0,0,0,0.1);
    }
    h1 { 
      color: #00802b; 
      font-size: 36px; 
      margin-bottom: 10px;
    }
    p {
      color: #555;
      font-size: 18px;
    }
    .highlight {
      background: #e6ffec;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: monospace;
      font-weight: bold;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>¡Hola desde la Aplicación cargada desde S3! 🪣🟢</h1>
    <p>Este archivo HTML fue descargado dinámicamente desde un bucket de S3 privado.</p>
    <p>La autenticación se realizó usando <span class="highlight">IRSA (IAM Roles for Service Accounts)</span>.</p>
  </div>
</body>
</html>
EOF
  content_type = "text/html"
}

# 4. Política de IAM que otorga permisos de lectura sobre el bucket de S3
resource "aws_iam_policy" "s3_read_policy" {
  name        = "${var.cluster_name}-s3-read-policy"
  description = "Permisos para que los Pods de EKS lean desde el bucket de S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.html_bucket.arn,
          "${aws_s3_bucket.html_bucket.arn}/*"
        ]
      }
    ]
  })
}

# 5. Relación de confianza (Trust Policy) para que el proveedor OIDC del clúster EKS pueda asumir este rol
data "aws_iam_policy_document" "s3_irsa_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      # Solo permitimos asumir este rol a la ServiceAccount 'app-s3-service-account' en el namespace 'app-s3'
      values   = ["system:serviceaccount:app-s3:app-s3-service-account"]
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

# 6. Crear el Rol de IAM para IRSA
resource "aws_iam_role" "s3_irsa_role" {
  name               = "${var.cluster_name}-s3-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.s3_irsa_assume_role_policy.json
}

# 7. Adjuntar la política al rol
resource "aws_iam_role_policy_attachment" "s3_irsa_attach" {
  role       = aws_iam_role.s3_irsa_role.name
  policy_arn = aws_iam_policy.s3_read_policy.arn
}

# 8. Outputs para copiar y pegar en los manifiestos de Kubernetes
output "s3_bucket_name" {
  description = "Nombre del bucket S3 creado (para poner en el Deployment)"
  value       = aws_s3_bucket.html_bucket.id
}

output "s3_iam_role_arn" {
  description = "ARN del rol de IAM para IRSA (para poner en la ServiceAccount)"
  value       = aws_iam_role.s3_irsa_role.arn
}
