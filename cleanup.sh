#!/bin/bash

# Configuración del Laboratorio
CLUSTER_NAME="eks-learn-cluster"
REGION="eu-north-1"

echo "=== Iniciando Limpieza de Recursos Huérfanos de EKS ==="
echo "Clúster Objetivo: $CLUSTER_NAME | Región: $REGION"
echo "--------------------------------------------------------"

# 1. CloudWatch Log Group
echo "[1/5] Buscando grupo de logs de CloudWatch..."
LOG_GROUP="/aws/eks/$CLUSTER_NAME/cluster"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" --query "logGroups[?logGroupName=='$LOG_GROUP']" --output text | grep -q "$LOG_GROUP"; then
    echo "-> Encontrado: $LOG_GROUP. Eliminando..."
    aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
    echo "-> Grupo de logs eliminado."
else
    echo "-> No se encontraron grupos de logs huérfanos."
fi

# 2. Balanceadores de Carga de AWS (ELBs / ALBs / NLBs)
echo "[2/5] Buscando balanceadores de carga huérfanos..."

# Classic ELBs
CLASSIC_ELBS=$(aws elb describe-load-balancers --region "$REGION" --query "LoadBalancerDescriptions[*].LoadBalancerName" --output text 2>/dev/null)
for elb in $CLASSIC_ELBS; do
    TAGS=$(aws elb describe-tags --load-balancer-names "$elb" --region "$REGION" --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME']" --output text 2>/dev/null)
    if [ ! -z "$TAGS" ]; then
        echo "-> Encontrado Classic ELB huérfano: $elb. Eliminando..."
        aws elb delete-load-balancer --load-balancer-name "$elb" --region "$REGION"
    fi
done

# ELB v2 (Application / Network Load Balancers)
V2_ELB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[*].LoadBalancerArn" --output text 2>/dev/null)
for arn in $V2_ELB_ARNS; do
    TAGS=$(aws elbv2 describe-tags --resource-arns "$arn" --region "$REGION" --query "TagDescriptions[0].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME']" --output text 2>/dev/null)
    if [ ! -z "$TAGS" ]; then
        NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$arn" --region "$REGION" --query "LoadBalancers[0].LoadBalancerName" --output text 2>/dev/null)
        echo "-> Encontrado ELB v2 huérfano: $NAME. Eliminando..."
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION"
    fi
done

# 3. Discos duros EBS huérfanos (Persistent Volumes en estado disponible)
echo "[3/5] Buscando discos EBS huérfanos..."
ORPHANED_VOLUMES=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" "Name=status,Values=available" \
    --query "Volumes[*].VolumeId" --output text 2>/dev/null)

if [ ! -z "$ORPHANED_VOLUMES" ] && [ "$ORPHANED_VOLUMES" != "None" ]; then
    for vol in $ORPHANED_VOLUMES; do
        echo "-> Encontrado volumen EBS disponible: $vol. Eliminando..."
        aws ec2 delete-volume --volume-id "$vol" --region "$REGION"
    done
else
    echo "-> No se encontraron discos EBS huérfanos."
fi

# 4. Interfaces de red (ENIs) huérfanas en estado disponible
echo "[4/5] Buscando interfaces de red (ENIs) huérfanas..."
ORPHANED_ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=status,Values=available" "Name=description,Values=*$CLUSTER_NAME*" \
    --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>/dev/null)

if [ ! -z "$ORPHANED_ENIS" ] && [ "$ORPHANED_ENIS" != "None" ]; then
    for eni in $ORPHANED_ENIS; do
        echo "-> Encontrada ENI huérfana: $eni. Eliminando..."
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION"
    done
else
    echo "-> No se encontraron interfaces de red huérfanas."
fi

# 5. Grupos de Seguridad (Security Groups) huérfanos creados por el ELB de Kubernetes
echo "[5/5] Buscando grupos de seguridad (Security Groups) de ELB huérfanos..."
# Obtener el ID de la VPC asociada al clúster
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null)

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    # Buscar grupos de seguridad de ELB (k8s-elb-*) en esta VPC
    ORPHANED_SGS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-elb-*" \
        --query "SecurityGroups[*].GroupId" --output text 2>/dev/null)

    if [ ! -z "$ORPHANED_SGS" ] && [ "$ORPHANED_SGS" != "None" ]; then
        for sg in $ORPHANED_SGS; do
            echo "-> Encontrado Security Group de ELB huérfano: $sg. Eliminando..."
            aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || echo "-> No se pudo eliminar $sg (aún en uso)."
        done
    else
        echo "-> No se encontraron grupos de seguridad de ELB huérfanos."
    fi
else
    echo "-> No se pudo determinar el ID de la VPC (el clúster o la VPC ya no existen)."
fi

echo "--------------------------------------------------------"
echo "=== Limpieza Finalizada con Éxito ==="
