# Resumen de Cambios y Comandos - Optimización EKS & GitOps

Este documento explica de forma cronológica y detallada todos los comandos ejecutados, los archivos modificados y el razonamiento técnico detrás de cada decisión tomada para estabilizar y optimizar el clúster de EKS administrado mediante GitOps.

---

## 1. Modificaciones de Archivos (HCL y YAML)

### A. Escalado de Nodos del Clúster
*   **Archivo modificado:** `terraform/eks.tf`
*   **Cambio:** Se incrementó el tamaño máximo de nodos (`max_size = 3`) y el tamaño deseado (`desired_size = 2`) en el bloque `eks_managed_node_groups.default`.
*   **¿Por qué?:** Las instancias de tipo `t3.small` tienen un límite físico impuesto por AWS de **11 pods máximo por nodo** (debido al número máximo de interfaces de red y direcciones IP secundarias permitidas). El clúster original de 1 solo nodo estaba saturado (11/11 pods ocupados por ArgoCD y servicios del sistema), dejando a Kong y las aplicaciones de negocio atascadas indefinidamente en estado `Pending`.

---

### B. Corrección de la Sintaxis de ArgoCD para Namespaces
*   **Archivos modificados:**
    *   `kubernetes/apps-infra/argocd-kong.yaml`
    *   `kubernetes/apps-business/argocd-nginx.yaml`
    *   `kubernetes/apps-business/argocd-app-red.yaml`
    *   `kubernetes/apps-business/argocd-app-blue.yaml`
    *   `kubernetes/apps-business/argocd-app-s3.yaml`
*   **Cambio:** Se reemplazó la sintaxis antigua `createNamespace: true` por la opción estándar de sincronización:
    ```yaml
    syncPolicy:
      syncOptions:
        - CreateNamespace=true
    ```
*   **¿Por qué?:** La directiva directa `createNamespace: true` no es válida o está en desuso en las versiones modernas del esquema de recursos `Application` de ArgoCD, lo que causaba errores de validación de sintaxis en el controlador y bloqueaba la sincronización automática de los namespaces de las aplicaciones.

---

### C. Optimización de Réplicas en Entorno de Desarrollo
*   **Archivos modificados:**
    *   `kubernetes/app-red/deployment.yaml`
    *   `kubernetes/app-blue/deployment.yaml`
    *   `kubernetes/nginx/deployment.yaml`
*   **Cambio:** Se redujo el parámetro `replicas` de `2` a `1`.
*   **¿Por qué?:** Al tener dos nodos, el límite total del clúster era de 22 pods. Al desplegar múltiples aplicaciones (Red, Blue, Nginx, S3) con 2 réplicas cada una, volvimos a rozar el límite de IP asignables. Reducir la redundancia a 1 réplica por servicio es una práctica recomendada en entornos de laboratorio/dev para ahorrar costes de cómputo y evitar bloqueos de capacidad de IPs.

---

### D. Regla de Red Inter-Nodos (Security Groups)
*   **Archivo modificado:** `terraform/eks.tf`
*   **Cambio:** Se añadió el bloque `node_security_group_additional_rules` con la regla `ingress_self_all`:
    ```hcl
    node_security_group_additional_rules = {
      ingress_self_all = {
        description = "Node to node all ports/protocols"
        protocol    = "-1"
        from_port   = 0
        to_port     = 0
        type        = "ingress"
        self        = true
      }
    }
    ```
*   **¿Por qué?:** Por defecto, el módulo de EKS de Terraform bloquea la comunicación interna entre nodos en puertos inferiores al 1025 (como el puerto 80/HTTP). Dado que Kong corría en el Nodo 2 y la App Azul en el Nodo 1, las peticiones HTTP del gateway al pod se quedaban colgadas. Esta regla permite la libre comunicación (de cualquier puerto y protocolo) entre los propios nodos del clúster de forma segura.

---

### E. Mapeo Automatizado de Permisos de OpenSearch
*   **Archivo modificado:** `terraform/opensearch.tf`
*   **Cambio:** Se introdujo la directiva `access_policies` al dominio de OpenSearch y se declaró el origen de datos dinámico `aws_caller_identity`.
*   **¿Por qué?:** OpenSearch bloquea por defecto cualquier petición a nivel de API de AWS si no tiene una política de recursos que le permita aceptar tráfico HTTP externo. Al estar en subredes privadas, lo abrimos (`es:*` para `Principal: "*"`) y delegamos la seguridad en los grupos de red y en la autenticación por usuario/contraseña o roles de IAM.

---

## 2. Comandos Clave Utilizados (Diagnóstico y Operación)

### A. Diagnóstico de Capacidad de Nodos
```bash
kubectl get nodes
kubectl describe nodes
```
*   **Objetivo:** Ver el consumo real de recursos (CPU, Memoria e IPs asignadas por ENI) de las máquinas EC2 del clúster. Nos permitió detectar que el Nodo 1 estaba saturado de Pods (11/11).

### B. Maniobra de Reubicación de Pods (DNS Rollout)
```bash
kubectl rollout restart deployment/coredns -n kube-system
```
*   **Objetivo:** Reiniciar los pods de resolución DNS del sistema. Al hacerlo, el clúster los destruyó en el Nodo 1 (saturado) y los forzó a iniciarse en el Nodo 2. Esto liberó espacio en el Nodo 1 para que el DaemonSet de **Fluent Bit** encontrara un slot libre y se pusiera en verde.

### C. Acceso Seguro a Consolas Privadas (Port-Forward)
```bash
# Para acceder a ArgoCD en http://localhost:8080 (HTTPS)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Para acceder a OpenSearch Dashboards en http://localhost:5601 (HTTP)
kubectl port-forward svc/opensearch-proxy -n logging 5601:80
```
*   **Objetivo:** Crear túneles seguros desde tu MacBook local hacia servicios que no están expuestos a internet (ArgoCD y OpenSearch).

### D. Consulta de Secretos en AWS SSM y Kubernetes
```bash
# Obtener contraseña cifrada del SSM Parameter Store
aws ssm get-parameter --name "/eks/learning/opensearch/admin_password" --with-decryption --query "Parameter.Value" --output text

# Obtener contraseña inicial de ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
*   **Objetivo:** Extraer de forma segura las credenciales auto-generadas sin exponerlas en texto claro en el código fuente.

### E. Pruebas de Conectividad Interna en Pods
```bash
kubectl exec -it -n app-red deployment/app-red-deployment -- wget -T 5 -qO- http://app-blue-service.app-blue.svc.cluster.local
```
*   **Objetivo:** Ejecutar un comando web dentro de un contenedor en producción para diagnosticar si la red interna funciona. Nos permitió demostrar el bloqueo del firewall de AWS entre los nodos.
