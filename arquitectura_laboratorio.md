# Guía de Arquitectura de Referencia - Laboratorio EKS GitOps

Este documento explica de forma detallada cada pieza de infraestructura, red, servicios, seguridad y flujos de datos que componen este laboratorio. Su objetivo es proporcionar una comprensión completa de cómo interactúan todos los elementos del sistema.

---

## 1. Capa de Red e Infraestructura Base (VPC & EKS)

### A. VPC (Virtual Private Cloud)
Definida en `terraform/vpc.tf`, divide la red en subredes aisladas:
*   **Subredes Públicas (`10.0.101.0/24`...):** Alojan únicamente los recursos que deben dar la cara a internet (el balanceador ELB de Kong y el NAT Gateway).
*   **Subredes Privadas (`10.0.1.0/24`...):** Alojan las instancias EC2 del clúster de EKS y el dominio de OpenSearch. Las máquinas no tienen direcciones IP públicas.
*   **Internet Gateway (IGW):** Es el componente de red que comunica la VPC con el internet público. Está asociado a las subredes públicas para permitir el tráfico entrante del ELB y saliente del NAT Gateway.
*   **NAT Gateway (Aprovisionamiento con Single NAT):** Permite que los pods y nodos de las subredes privadas inicien conexiones de salida a internet (ej. descargar imágenes de Docker, conectar con APIs) mientras bloquea el tráfico entrante no solicitado. Se ha configurado en modo **Single NAT Gateway** (`single_nat_gateway = true`) para consolidar todo el tráfico saliente en un único dispositivo físico, minimizando el coste de AWS en este entorno.
*   **S3 Gateway Endpoint:** Un enlace de red gratuito dentro de la VPC. Permite que las peticiones hacia S3 (de la App S3) no salgan por el NAT Gateway (ahorrando costes de ancho de banda), sino que viajen por la red interna de AWS directamente a S3.

### B. Clúster de EKS (Elastic Kubernetes Service)
Definido en `terraform/eks.tf`:
*   **Managed Node Group:** Grupo de servidores autogestionados de AWS corriendo sobre instancias `t3.small` (2 vCPUs y 2GB RAM).
*   **Límite de Pods (Restricción de AWS):** En AWS, cada pod recibe una dirección IP real de la VPC. El tipo `t3.small` solo permite adjuntar un número limitado de interfaces de red virtuales (ENIs), lo que resulta en un **límite físico de 11 pods por máquina**. Por ello, el laboratorio requiere **2 nodos** (capacidad para 22 pods) para que ArgoCD, Kong, OpenSearch Proxy, Fluent Bit y las apps quepan sin quedarse en estado `Pending`.

### C. Security Groups (El Cortafuegos de AWS)
*   **Security Group de Nodos (Cross-Node Pod Routing):** El clúster crea un grupo de seguridad para las máquinas. Para permitir que Kong (Nodo 2) se comunique en el puerto 80 con la App Azul (Nodo 1), añadimos la regla `ingress_self_all` que abre todo el tráfico entre las propias máquinas del clúster. Sin ella, AWS bloquea los paquetes internos por debajo del puerto 1025.
*   **Security Group de OpenSearch:** Bloquea todo el acceso de internet y solo permite tráfico entrante en el puerto `443` si proviene del rango CIDR de la VPC (`10.0.0.0/16`).

---

## 2. Capa de Gestión de Aplicaciones (GitOps con ArgoCD)

### A. Despliegue de ArgoCD desde Terraform
*   Definido en `terraform/addons.tf` mediante el módulo `aws-ia/eks-blueprints-addons/aws`.
*   Aprovecha el proveedor de **Helm** para instalar automáticamente la versión oficial de ArgoCD en el namespace `argocd` durante la fase de creación de la infraestructura. Esto garantiza un arranque limpio "cero operaciones manuales".

### B. Patrón App of Apps (Aplicación de Aplicaciones)
Para evitar la aplicación manual de archivos YAML, usamos una jerarquía ordenada en ArgoCD:
1.  **Bootstrap de Infraestructura (`bootstrap-infra.yaml`):** Es la aplicación raíz que gestiona el ciclo de vida de las herramientas de soporte (el Ingress Controller Kong y el sistema de Logs Fluent Bit).
2.  **Bootstrap de Negocio (`bootstrap-apps.yaml`):** Gestiona el ciclo de vida de los microservicios funcionales (Nginx, App Roja, App Azul, App S3).

Este patrón asegura que si añades una nueva aplicación al directorio `kubernetes/apps-business/` en Git, ArgoCD la detectará y creará de manera 100% automatizada.

---

## 3. Capa de Enrutamiento y Gateway (Kong)

*   **Kong Ingress Controller:** Funciona como el punto de entrada único de tráfico web al clúster (Reverse Proxy).
*   **Service Type LoadBalancer:** Kubernetes le pide a AWS que cree un balanceador físico (ELB) apuntando a Kong.
*   **Ingress Path Routing:** El archivo `ingress.yaml` de cada app define qué prefijo de URL le corresponde.
*   **Anote `konghq.com/strip-path: "true"`:** Es vital. Cuando un usuario entra a `/red`, Kong elimina el prefijo `/red` antes de mandar la petición al pod. De esta forma, el servidor web Nginx interno del pod recibe una petición limpia sobre `/` y sirve correctamente su archivo `index.html`.

---

## 4. Capa de Seguridad y Permisos (IAM / IRSA & SSM)

### A. Gestión de Secretos con AWS SSM
*   **SSM Parameter Store:** La contraseña maestra del dominio de OpenSearch se genera mediante el recurso `random_password` de Terraform y se inyecta directamente en el almacén de parámetros cifrado de AWS (`/eks/learning/opensearch/admin_password`) como tipo `SecureString`. Esto evita que las contraseñas se expongan en los logs del pipeline de CI/CD.

### B. El Mecanismo IRSA (IAM Roles for Service Accounts)
Es la forma segura en que Kubernetes da permisos de AWS a los Pods sin usar credenciales fijas o roles de máquina inseguros.
1.  El clúster EKS tiene un **Proveedor OIDC (OpenID Connect)**.
2.  Terraform crea un Rol de IAM en AWS cuya relación de confianza especifica que *"solo el ServiceAccount X en el namespace Y del clúster Z puede asumir este rol"*.
3.  En Kubernetes, creamos un `ServiceAccount` con la anotación `eks.amazonaws.com/role-arn`.
4.  Cuando el Pod se inicia usando ese ServiceAccount, AWS inyecta automáticamente un token JWT temporal en el Pod. El cliente de AWS en el Pod usa este token para autenticarse con AWS.

### C. Patrón de Compartición de Volumen `emptyDir` (App S3)
*   La aplicación `app-s3` requiere descargar un archivo `index.html` de un bucket S3 privado y servirlo usando Nginx.
*   Nginx no tiene integrado el cliente de AWS para comunicarse con S3. Para resolver esto:
    1.  Se define un volumen temporal en memoria o disco local del pod (`emptyDir`).
    2.  Se añade un **`initContainer`** ejecutando la imagen oficial de AWS CLI. Este contenedor hereda el ServiceAccount y los permisos IRSA, descarga el archivo desde el bucket de S3 privado y lo guarda en el volumen compartido.
    3.  Una vez finaliza con éxito, el contenedor principal de **Nginx** se inicia, monta el mismo volumen compartido en su ruta `/usr/share/nginx/html/` y sirve el archivo de forma instantánea.

---

## 5. Capa de Logging y Observabilidad (OpenSearch + Fluent Bit)

### A. Fluent Bit (DaemonSet Collector)
*   Se despliega como un **DaemonSet**, lo que significa que Kubernetes garantiza que corre exactamente **una instancia en cada nodo** del clúster.
*   **Volúmenes HostPath:** Monta la ruta `/var/log/containers/` de la máquina física host dentro del contenedor para leer las salidas estándar de todos los Pods.
*   **Mecanismo de Parseo (`parsers.conf`):** Los contenedores Docker empaquetan las salidas en formato JSON bruto. Fluent Bit usa el parseador `docker` para extraer el JSON, separar el campo del log del timestamp original, y después aplicar el filtro `kubernetes` para enriquecer cada línea con metadatos reales del clúster (como nombres de pod, namespaces y labels).
*   Envía los logs formateados a OpenSearch firmando las peticiones con **AWS SigV4** (usando los permisos IRSA).

### B. Amazon OpenSearch Service
*   Instancia gestionada de base de datos de logs desplegada en una subred privada.
*   **Mapeo de Roles Interno (Fine-Grained Access Control):** Aunque el rol de IAM de Fluent Bit esté autorizado por AWS, debemos mapear su ARN en el rol interno `all_access` de OpenSearch. Esto se hace en la base de datos interna para que OpenSearch le permita realizar operaciones de escritura en bloque (`_bulk`).
*   **Logstash Format:** Fluent Bit guarda los logs con el formato de prefijo `k8s-logs-YYYY.MM.DD`, permitiendo crear el patrón de índice `k8s-logs-*` para consultar en Discover.

### C. OpenSearch Proxy (Nginx)
Como OpenSearch está aislado en la red privada de la VPC, no se puede acceder desde el navegador de tu ordenador.
*   Creamos un **Deployment de Nginx** (`opensearch-proxy`) dentro de la red del clúster.
*   Este proxy tiene activado **SNI** (`proxy_ssl_server_name on`) para poder reenviar el tráfico a través del balanceador HTTPS interno de AWS OpenSearch.
*   El administrador crea un túnel local (`kubectl port-forward svc/opensearch-proxy 5601:80`), lo que permite que el tráfico al puerto `5601` de tu MacBook viaje cifrado por Kubernetes, pase por el proxy de Nginx, y llegue finalmente a OpenSearch Dashboards de forma segura.
