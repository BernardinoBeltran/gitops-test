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

## Paso 4: Desplegar Kong usando GitOps (ArgoCD)

En lugar de teclear comandos `helm install` en tu terminal, crearemos un recurso de ArgoCD para que él lo instale:

1. Aplica el archivo de aplicación de ArgoCD para Kong:
   ```bash
   kubectl apply -f kubernetes/argocd-kong.yaml
   ```
2. Si entras a la web de ArgoCD, verás una aplicación llamada `kong-api-gateway` creándose de forma visual.
3. Una vez esté en verde (`Synced`), obtén el DNS público del balanceador creado por Kong:
   ```bash
   kubectl get service kong-kong-proxy -n kong
   ```
   Anota la dirección DNS en la columna **`EXTERNAL-IP`**.

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl get pods -n kong` y verifica que el proxy y el ingress controller estén en `Running`. Si abres en tu terminal `curl -I http://<TU_DNS_DE_KONG>`, la respuesta debe ser `HTTP/1.1 404 Not Found` (esto es correcto, ya que el balanceador responde pero aún no tiene configurada ninguna ruta).


---

## Paso 5: Desplegar la Aplicación de Ejemplo (Nginx)

Para que ArgoCD gestione tu aplicación Nginx, esta debe estar vinculada en un repositorio de Git.

### Opción A (GitOps con Repositorio Público - Recomendado para aprender)
Esta opción es la más rápida porque no requiere configurar contraseñas ni claves en ArgoCD:
1. Ya has creado el repositorio público en: `https://github.com/BernardinoBeltran/gitops-test`.
2. Sube la carpeta `kubernetes/` de tu proyecto local a ese repositorio de GitHub.
3. El archivo `kubernetes/argocd-nginx.yaml` ya está configurado con tu repositorio.
4. Aplica el manifiesto en tu clúster:
   ```bash
   kubectl apply -f kubernetes/argocd-nginx.yaml
   ```
5. En la interfaz web de ArgoCD verás aparecer la aplicación `nginx-app` y cómo se sincroniza automáticamente de forma visual.

### Opción B (GitOps con Repositorio Privado - Entorno Real)
Si tu repositorio de GitHub es **privado**, debes autorizar a ArgoCD para poder descargarlo:
* **Mediante la Interfaz Web (Fácil):** Entra en la web de ArgoCD, ve a **Settings** -> **Repositories** -> **Connect Repo**. Elige conexión vía `HTTPS` o `SSH`, introduce la URL del repositorio privado y pega tu clave privada SSH o un GitHub Personal Access Token (PAT).
* **Mediante Código (Declarativo):** Puedes guardar tu clave SSH o Token en un Secret de Kubernetes en el namespace `argocd` con la etiqueta `argocd.argoproj.io/secret-type: repository`. ArgoCD la usará automáticamente para autenticarse.

### Opción C (Local Rápido - Sin usar GitOps para Nginx)
Si no quieres subir nada a GitHub todavía y prefieres probar Nginx directamente ejecutando el comando desde tu ordenador:
```bash
kubectl apply -f kubernetes/nginx/
```

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl get ingress -n demo-app` para comprobar que la regla de Ingress está activa. Abre tu navegador y entra en la dirección DNS larga del balanceador de Kong (Paso 4.3). **¡Verás la página de bienvenida de Nginx!**


---

## Paso 5.1: Probar Multi-Aplicación (App Roja y App Azul)

Para llevar la práctica al siguiente nivel y probar cómo Kong gestiona múltiples aplicaciones en namespaces separados compartiendo un único balanceador físico:

1. Asegúrate de haber subido todo tu directorio `kubernetes/` a tu repositorio de GitHub (incluyendo las nuevas carpetas `app-red/` y `app-blue/`).
2. Registra las nuevas aplicaciones en ArgoCD ejecutando:
   ```bash
   kubectl apply -f kubernetes/argocd-app-red.yaml
   ```
   ```bash
   kubectl apply -f kubernetes/argocd-app-blue.yaml
   ```
3. Ve a la consola web de ArgoCD. Verás aparecer dos nuevas aplicaciones: `app-red` y `app-blue` organizándose solas en sus namespaces dedicados.
4. Una vez sincronizadas en verde, prueba el enrutamiento inteligente abriendo tu navegador:
   * **Acceso App Roja:** `http://<TU_DNS_DE_KONG>/red` (Se abrirá una página web personalizada con fondo rojo).
   * **Acceso App Azul:** `http://<TU_DNS_DE_KONG>/blue` (Se abrirá una página web personalizada con fondo azul).

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl get ingress -A` para validar que tienes activos los ingress de `app-red` y `app-blue`. Si realizas peticiones a `/red` o `/blue` y Nginx te devuelve el index correcto de color, el Ingress Path-Stripping de Kong está funcionando.


*¿Cómo funciona la magia de Kong aquí?* 
Kong intercepta la llamada, lee la ruta (`/red` o `/blue`), y gracias a la anotación `konghq.com/strip-path: "true"` en el recurso Ingress, elimina ese prefijo antes de enviar la llamada al Nginx interno. De esta forma, cada microservicio puede programarse ignorando la ruta base externa.

---

## Paso 5.2: Probar Permisos IAM (Cargar HTML desde S3 privado con IRSA)

Este paso demuestra cómo tus Pods de Kubernetes pueden interactuar de forma segura con recursos de AWS (como S3) sin guardar claves estáticas:

1. **Aplica Terraform:** Ejecuta `terraform apply` (esto creará el bucket S3 privado, subirá un archivo `index.html` y creará el Rol IAM). Al finalizar, anota los outputs:
   * `s3_bucket_name`
   * `s3_iam_role_arn`
2. **Configura el ServiceAccount:** Abre `kubernetes/app-s3/serviceaccount.yaml` en tu editor y sustituye el valor de `eks.amazonaws.com/role-arn` por tu `s3_iam_role_arn` real.
3. **Configura el Deployment:** Abre `kubernetes/app-s3/deployment.yaml` y en la sección del `initContainers` sustituye `BUCKET_NAME_REEMPLAZAME` por tu `s3_bucket_name` real.
4. **Sube los cambios a Git:**
   ```bash
   git add kubernetes/app-s3/
   git commit -m "feat: configure S3 app with real IAM Role and Bucket Name"
   git push origin main
   ```
5. **Registra la aplicación en ArgoCD:**
   ```bash
   kubectl apply -f kubernetes/argocd-app-s3.yaml
   ```

> [!TIP]
> **🔍 Comprobación:** Ejecuta `kubectl logs -n app-s3 deployment/app-s3 -c download-html` para leer los logs del contenedor de inicialización. Deberías ver la descarga del archivo completada con éxito. Abre tu navegador en `http://<TU_DNS_DE_KONG>/s3` y verás la página web verde recuperada desde S3.

6. **Verifica el acceso:** Abre tu navegador y accede a `http://<TU_DNS_DE_KONG>/s3`.
   * **¿Qué está ocurriendo?** Al arrancar el pod, un *initContainer* con el AWS CLI descarga el HTML desde S3. Gracias a la ServiceAccount de Kubernetes vinculada con el Rol de IAM (IRSA), AWS autentica la petición de forma segura e instantánea.
   * **¿Quieres probar la seguridad?** Si entras en el pod y ejecutas comandos contra otro bucket de S3 privado, AWS te denegará el acceso ya que el rol asignado al pod solo permite leer este bucket concreto.

---

## Paso 5.3: Centralización de Logs (OpenSearch + Fluent Bit)

Este paso implementa la monitorización y agregación centralizada de logs a nivel de producción:

1. **Obtén las variables de OpenSearch:** Ejecuta `terraform apply` en la carpeta `terraform/` y anota los nuevos outputs:
   * `opensearch_endpoint` (URL interna privada del dominio)
   * `opensearch_iam_role_arn` (ARN del rol IAM para el pod colector)
2. **Configura el ServiceAccount de Fluent Bit:** Abre `kubernetes/fluent-bit/serviceaccount.yaml` y sustituye el valor de `eks.amazonaws.com/role-arn` por tu `opensearch_iam_role_arn` real.
3. **Configura la conexión de logs:** Abre `kubernetes/fluent-bit/configmap.yaml` y en la sección del `Host` del bloque `[OUTPUT]` sustituye `ENDPOINT_OPENSEARCH_REEMPLAZAME` por tu `opensearch_endpoint` real (ej: `vpc-eks-logs-domain-xxxxx.eu-north-1.es.amazonaws.com`, **sin http/https ni barras**).
4. **Configura el Reverse Proxy:** Abre `kubernetes/fluent-bit/proxy-nginx.yaml` y en las dos líneas que contienen `ENDPOINT_OPENSEARCH_REEMPLAZAME` sustitúyelo por tu `opensearch_endpoint` real.
5. **Sube los cambios a tu GitHub:**
   ```bash
   git add kubernetes/fluent-bit/
   git commit -m "feat: configure Fluent Bit and proxy with OpenSearch endpoint"
   git push origin main
   ```
6. **Registra la aplicación de Logging en ArgoCD:**
   ```bash
   kubectl apply -f kubernetes/argocd-fluent-bit.yaml
   ```
7. **Establece un túnel seguro hacia OpenSearch Dashboards (Kibana):**
   * Dado que el clúster de OpenSearch está aislado de forma 100% privada dentro de la VPC, ejecutaremos un túnel local hacia el Proxy Nginx que creamos en EKS:
     ```bash
     kubectl port-forward svc/opensearch-proxy -n logging 8080:80
     ```
   * Deja la terminal abierta para mantener el túnel activo.
8. **Explora tus logs en tiempo real:**
   * Abre en tu navegador local de tu Mac: `http://localhost:8080/_dashboards`
   * Inicia sesión con las credenciales maestras:
     * **Usuario:** `admin`
     * **Contraseña:** `OpenSearchPassword123!`
   * Ve a **Stack Management** -> **Index Patterns** -> **Create Index Pattern** y escribe `k8s-logs-*`.
   * Ve a la pestaña **Discover** y verás fluir todos los logs de tus aplicaciones (`nginx-app`, `app-red`, `app-blue` y `app-s3`) estructurados con su metadata de Kubernetes.

---

## Paso 6: Limpieza Total (Evitar Costes)

Es extremadamente importante limpiar todo al terminar para evitar costes. Con este enfoque declarativo, la limpieza es facilísima:

1. Entra a la carpeta de Terraform:
   ```bash
   cd terraform
   ```
2. Ejecuta la destrucción completa (Terraform se encargará de borrar ArgoCD, el clúster EKS, la VPC y el dominio de OpenSearch de forma ordenada):
   ```bash
   terraform destroy -auto-approve
   ```

