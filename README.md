# Guía de Práctica: AWS EKS + ArgoCD GitOps + Kong API Gateway

Esta guía detalla los pasos para desplegar un clúster de Amazon EKS, desplegar automáticamente ArgoCD con Terraform, instalar el API Gateway **Kong** usando GitOps, y enrutar el tráfico hacia una aplicación de Nginx interna sin crear balanceadores adicionales.

---

## Arquitectura de la Solución

```text
                     [ Internet ]
                          │
                          ▼
            [ 1x AWS Elastic Load Balancer ] (Creado por Kong)
                          │
                          ▼
             [ Kong Ingress Controller ] (Namespace: kong)
                          │
            (Ruta virtual de Kubernetes - Gratis)
                          │
                          ▼
             [ Nginx Service (ClusterIP) ] (Namespace: demo-app)
                          │
                          ▼
                 [ Nginx Pods (x2) ]
```

---

## Conceptos Clave: Ingress vs Ingress Controller

Es común confundir estos términos, pero representan componentes distintos en Kubernetes:

*   **El Ingress (La Regla):** Es el recurso de configuración (nuestro archivo `ingress.yaml`). Es como una **señal de tráfico** o cartel que dice *"para ir a Nginx, toma la salida de nginx-service"*. Por sí solo no hace nada; es solo una instrucción guardada en la base de datos de Kubernetes.
*   **El Ingress Controller (El Motor - Kong):** Es el software real (el conjunto de Pods de Kong) que se ejecuta en el clúster. Es como el **policía de tráfico** que observa la señal de tráfico (el recurso Ingress), recibe las peticiones reales del exterior y las dirige físicamente hacia los pods del servicio correspondiente.

Para tener enrutamiento de red mediante nombres de dominio o rutas en Kubernetes, necesitas definir un recurso **`Ingress`** y tener un **`Ingress Controller`** (como Kong) activo en el clúster.

---

## Paso 1: Levantar la Infraestructura (Terraform)

1. Ve a la carpeta de Terraform:
   ```bash
   cd terraform
   ```
2. Inicializa Terraform (es obligatorio para descargar el nuevo proveedor de Helm y el módulo de EKS Blueprints):
   ```bash
   terraform init
   ```
3. Aplica los cambios (se conectará a S3 para leer el estado de tu clúster):
   ```bash
   terraform apply -auto-approve
   ```
   *(Tardará unos 15 minutos en completarse).*

> [!TIP]
> **🔍 Comprobación:** Al finalizar con éxito, la terminal debe mostrar los outputs de Terraform en verde:
> * `s3_bucket_name` y `s3_iam_role_arn`
> * `opensearch_endpoint` y `opensearch_iam_role_arn`


---

## Paso 2: Conectarse al Clúster (`kubectl`)

1. Vuelve a la raíz de tu proyecto para que las rutas de los archivos de Kubernetes funcionen:
   ```bash
   cd ..
   ```
2. Configura tus credenciales locales para comunicarte con EKS:
   ```bash
   aws eks update-kubeconfig --region eu-north-1 --name eks-learn-cluster
   ```
3. Verifica la conexión listando el nodo de trabajo:
   ```bash
   kubectl get nodes
   ```

> [!TIP]
> **🔍 Comprobación:** Deberías ver un nodo EC2 en estado `Ready` al ejecutar `kubectl get nodes`. También puedes ejecutar `kubectl get namespaces` para ver los namespaces creados por defecto por AWS.


---

## Paso 3: Acceder a ArgoCD (Instalado Automáticamente)

Gracias a EKS Blueprints, ArgoCD se despliega solo durante el `terraform apply`. Para entrar a su consola gráfica:

1. **Obtén la contraseña del usuario `admin`** (se guarda de forma segura en un Secret de Kubernetes):
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
   ```
   *Copia el código que te devuelva la terminal.*

2. **Crea un túnel de acceso local (Port-Forward):**
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
   *(Deja esta terminal abierta para mantener el túnel activo).*

3. **Inicia sesión en tu navegador:**
   * Abre `https://localhost:8080` (acepta la advertencia de certificado auto-firmado).
   * Usuario: `admin`
   * Contraseña: La que copiaste en el punto 1.

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl get pods -n argocd`. Todos los pods de ArgoCD (como `argocd-server`, `argocd-repo-server`, `argocd-application-controller`) deben estar en estado `Running`.


---

## Paso 4: Configurar los Manifiestos con los Outputs de Terraform

Antes de desplegar las aplicaciones mediante GitOps, debemos configurar las variables reales de infraestructura generadas por Terraform en los archivos de configuración locales.

### 1. Variables de S3 (IRSA)
Abre tu editor y configura las variables del microservicio que consume S3 usando los outputs de Terraform (`s3_bucket_name` y `s3_iam_role_arn`):
*   **ServiceAccount:** Abre `kubernetes/app-s3/serviceaccount.yaml` y sustituye el valor de `eks.amazonaws.com/role-arn` por tu `s3_iam_role_arn` real.
*   **Deployment:** Abre `kubernetes/app-s3/deployment.yaml` y en el bloque del `initContainers` sustituye `BUCKET_NAME_REEMPLAZAME` por tu `s3_bucket_name` real.

### 2. Variables de OpenSearch (Logs)
Configura el colector de logs Fluent Bit y su proxy inverso usando los outputs de Terraform (`opensearch_endpoint` y `opensearch_iam_role_arn`):
*   **ServiceAccount:** Abre `kubernetes/fluent-bit/serviceaccount.yaml` y sustituye el valor de `eks.amazonaws.com/role-arn` por tu `opensearch_iam_role_arn` real.
*   **ConfigMap:** Abre `kubernetes/fluent-bit/configmap.yaml` y en la sección `Host` del bloque `[OUTPUT]` sustituye `ENDPOINT_OPENSEARCH_REEMPLAZAME` por tu `opensearch_endpoint` real (**sin `https://` ni barras**).
*   **Reverse Proxy Nginx:** Abre `kubernetes/fluent-bit/proxy-nginx.yaml` y en las dos líneas que contienen `ENDPOINT_OPENSEARCH_REEMPLAZAME` sustitúyelo por tu `opensearch_endpoint` real.

---

## Paso 5: Sincronizar el Repositorio de GitHub

En GitOps, Git es la única fuente de verdad. Para que ArgoCD pueda leer tus configuraciones, debes subir los cambios locales a tu repositorio de GitHub (`https://github.com/BernardinoBeltran/gitops-test`):

1. Sube todos los cambios locales (incluyendo la nueva estructura de carpetas) a la rama principal:
   ```bash
   git add kubernetes/
   git commit -m "feat: configure app values and app-of-apps structure"
   git push origin main
   ```

---

## Paso 6: Desplegar todo el Stack usando el Patrón "App of Apps"

En lugar de teclear comandos `kubectl apply` para cada aplicación individual, utilizaremos el patrón **App of Apps** declarando una aplicación raíz que desplegará de forma automática todo el catálogo de microservicios:

1. **Aplica la aplicación raíz de ArgoCD (Bootstrap):**
   ```bash
   kubectl apply -f kubernetes/bootstrap.yaml
   ```
2. **Monitorea el despliegue:**
   Abre la consola web de ArgoCD (`https://localhost:8080`). Verás aparecer la aplicación raíz `root-bootstrap` y cómo, de forma instantánea, se auto-crean y organizan las 6 aplicaciones del clúster:
   *   `kong-api-gateway` (Ingress Controller)
   *   `nginx-app` (Aplicación de bienvenida de Nginx)
   *   `app-red` (Aplicación web roja de demostración)
   *   `app-blue` (Aplicación web azul de demostración)
   *   `app-s3` (Descarga dinámica desde S3 usando IAM IRSA)
   *   `logging-fluent-bit` (Colector centralizado de logs)

---

## Paso 7: Comprobaciones y Acceso a los Servicios

Una vez que todas las aplicaciones en la consola de ArgoCD estén en verde (`Synced`), podemos realizar las verificaciones correspondientes:

### 1. Obtener la IP Pública del Ingress (Kong)
Ejecuta el siguiente comando para obtener la dirección DNS del balanceador de AWS:
```bash
kubectl get service kong-kong-proxy -n kong
```
Anota la dirección DNS en la columna **`EXTERNAL-IP`**.

### 2. Probar Enrutamiento Web y Multi-Namespace
Abre tu navegador y accede a los diferentes servicios a través de la IP de Kong:
*   **Nginx Welcome:** `http://<TU_DNS_DE_KONG>/`
*   **App Roja (Namespace red-app):** `http://<TU_DNS_DE_KONG>/red`
*   **App Azul (Namespace blue-app):** `http://<TU_DNS_DE_KONG>/blue`
*   **App S3 (Namespace app-s3):** `http://<TU_DNS_DE_KONG>/s3` (Debe cargar un HTML verde indicando que fue descargado con éxito usando permisos IAM IRSA).

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl get pods -A` para validar que todos los namespaces (`kong`, `demo-app`, `red-app`, `blue-app`, `app-s3` y `logging`) tienen sus pods en estado `Running`.

---

## Paso 8: Visualizar los Logs en OpenSearch Dashboards

Dado que OpenSearch es privado para máxima seguridad, usaremos un proxy inverso local para acceder a OpenSearch Dashboards (Kibana):

1. **Obtén la contraseña de administrador autogenerada desde AWS SSM:**
   Ejecuta el siguiente comando en tu Mac para extraer de forma segura el secreto que generó Terraform:
   ```bash
   aws ssm get-parameter --name "/eks/learning/opensearch/admin_password" --with-decryption --query "Parameter.Value" --output text
   ```
2. **Establece un túnel seguro hacia el clúster:**
   ```bash
   kubectl port-forward svc/opensearch-proxy -n logging 8080:80
   ```
   *(Mantén esta terminal abierta para no cerrar el túnel).*
3. **Accede a OpenSearch Dashboards:**
   * Abre en tu navegador de tu Mac: `http://localhost:8080/_dashboards`
   * Inicia sesión con las credenciales:
     * **Usuario:** `admin`
     * **Contraseña:** *La contraseña segura que obtuviste de SSM en el paso 1.*
4. **Configura el visualizador:**
   * Ve a **Stack Management** -> **Index Patterns** -> **Create Index Pattern** y escribe `k8s-logs-*`.
   * Selecciona `@timestamp` como campo de tiempo y crea el patrón.
   * Ve a la sección **Discover** en el menú izquierdo para explorar en tiempo real los logs generados por `app-red`, `app-blue`, `nginx` y el tráfico de `kong`.

---

## Paso 9: Limpieza Total (Seguridad Financiera)

Para destruir de forma controlada el laboratorio completo y garantizar que **no te quede ningún coste remanente en AWS**, ejecuta los siguientes pasos:

1. **Destruye la infraestructura de Terraform:**
   ```bash
   cd terraform
   terraform destroy -auto-approve
   ```
2. **Limpia los recursos dinámicos e independientes (Huérfanos):**
   Regresa a la raíz de tu workspace y ejecuta el script de limpieza automatizado para barrer cualquier residuo de discos EBS, balanceadores o logs huérfanos:
   ```bash
   cd ..
   ./cleanup.sh
   ```

> [!IMPORTANT]
> **🔍 Verificación Final:** Ejecuta `aws ec2 describe-load-balancers --query "LoadBalancerDescriptions[*].LoadBalancerName"` para cerciorarte de que no quede ningún balanceador activo en AWS.


