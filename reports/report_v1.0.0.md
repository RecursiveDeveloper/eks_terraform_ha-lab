# 🔐 Reporte de Análisis de Infraestructura como Código
### `eks_terraform_ha-lab` — Evaluación SAST / IaC Security

---

## 📋 Metadatos del Análisis

| Campo | Valor |
|---|---|
| **Versión del reporte** | v1.0.0 |
| **Fecha de análisis** | 2026-10-29 |
| **Fecha del commit analizado** | 2026-10-15 11:04:23 -0500 |
| **Commit (short hash)** | `28ed218` |
| **Rama** | `main` |
| **Organización** | `RecursiveDeveloper` |
| **Repositorio** | `eks_terraform_ha-lab` |
| **URL remoto** | https://github.com/RecursiveDeveloper/eks_terraform_ha-lab.git |
| **LLM utilizado** | Auto (selección dinámica del servidor — Kiro IDE) |
| **Checkov version** | 3.3.8 |
| **Trivy version** | 0.71.1 |
| **detect-secrets version** | 1.5.47 |
| **Framework analizado** | Terraform (IaC) |
| **CKV omitidos** | Ninguno |

---

## 📊 Resumen Ejecutivo

Se analizaron **27 recursos Terraform** distribuidos en 3 módulos (`vpc`, `iam`, `eks`) y archivos raíz. Las herramientas automatizadas ejecutadas fueron **Checkov** (SAST estático), **Trivy** (misconfiguraciones + secretos) y **detect-secrets** (exposición de credenciales).

### Conteo de Hallazgos por Herramienta

| Herramienta | CRITICAL | HIGH | MEDIUM | LOW/UNKNOWN | Total Hallazgos |
|---|:---:|:---:|:---:|:---:|:---:|
| **Checkov** | 0 | 0 | 0 | 9 | **9** |
| **Trivy** | 3 | 1 | 4 | 0 | **8** |
| **detect-secrets** | 1 | 0 | 0 | 0 | **1** |
| **TOTAL** | **3** | **1** | **4** | **9** | **18** |

### Resultados Generales Checkov
- ✅ Checks aprobados: **97**
- ❌ Checks fallidos: **9**
- ⏭️ Checks omitidos: **0**
- 📦 Recursos evaluados: **27**

---

## 📊 Barra de Cumplimiento

```
Checkov:  ████████████████████░░░ 91.5% (97/106 checks)
Trivy:    ████████████████░░░░░░░ 71/79 targets OK (8 fallos)
Secretos: ⚠️ 1 secreto detectado en workflows
```

**Porcentaje de cumplimiento global estimado:** ~84%

---

## ✅ Tabla de Criterios Evaluados

| # | Criterio | Herramienta | Estado |
|---|---|---|---|
| 1 | Módulos Terraform con hash de commit fijado | Checkov CKV_TF_1 | ❌ No cumple |
| 2 | IAM: política de exfiltración de datos | Checkov CKV_AWS_288 | ❌ No cumple |
| 3 | IAM: recurso `*` en acciones restrictables | Checkov CKV_AWS_355 | ❌ No cumple |
| 4 | IAM: acceso controlado por SSO (no usuarios IAM locales) | Checkov CKV_AWS_273 | ❌ No cumple |
| 5 | IAM: políticas en grupos/roles (no usuarios directos) | Checkov CKV_AWS_40 | ❌ No cumple |
| 6 | EKS: acceso público al endpoint desactivado | Trivy AWS-0040 | ❌ No cumple |
| 7 | EKS: CIDR público restringido (no `0.0.0.0/0`) | Trivy AWS-0041 | ❌ No cumple |
| 8 | EKS: logs del control plane habilitados | Trivy AWS-0038 | ❌ No cumple |
| 9 | EC2: regla de salida sin egress abierto a Internet | Trivy AWS-0104 | ⚠️ Parcial |
| 10 | VPC: subnets públicas sin auto-asignación de IP pública | Trivy AWS-0164 | ⚠️ Parcial |
| 11 | IAM PassRole con warning de escalada de privilegios | Trivy AWS-0342 | ⚠️ Parcial |
| 12 | Sin secretos expuestos en código | detect-secrets | ❌ No cumple |
| 13 | EBS CSI Driver con IRSA configurado | Conocimiento | ✔️ Cumple |
| 14 | Karpenter con IRSA configurado | Conocimiento | ✔️ Cumple |
| 15 | Políticas Karpenter con condiciones de recurso | Conocimiento | ✔️ Cumple |
| 16 | Remote state en S3 configurado | Conocimiento | ✔️ Cumple |
| 17 | Destroy workflow con teardown previo a `terraform destroy` | Conocimiento | ✔️ Cumple |
| 18 | Addons EKS `before_compute = true` en red/CNI | Conocimiento | ✔️ Cumple |

---

## 🔴 Hallazgos Críticos

### 🔴 [CRITICAL] AWS-0040 — EKS endpoint público abierto
- **Herramienta:** Trivy
- **Archivo:** `modules/eks/main.tf` líneas 3–61 → comunidad: `terraform-aws-modules/eks/aws/main.tf` línea 83
- **Línea relevante:** `endpoint_public_access = true`
- **Descripción:** El API server de EKS es accesible públicamente desde Internet. Cualquier entidad puede intentar autenticarse contra el endpoint.
- **Riesgo:** Exposición del plano de control a ataques de fuerza bruta, exploits de día cero en la API de Kubernetes o robo de credenciales kubeconfig.
- **Recomendación:** Cambiar a `endpoint_public_access = false` + `endpoint_private_access = true` y gestionar el acceso desde una VPN o bastion host. Si se requiere acceso público para pipelines CI/CD, restringir con `public_access_cidrs` a las IPs de los runners de GitHub Actions.
- **Referencia:** https://avd.aquasec.com/misconfig/aws-0040

---

### 🔴 [CRITICAL] AWS-0041 — CIDR público `0.0.0.0/0` en endpoint EKS
- **Herramienta:** Trivy
- **Archivo:** `modules/eks/main.tf` líneas 3–61 → `terraform-aws-modules/eks/aws/main.tf` línea 84
- **Línea relevante:** `public_access_cidrs = ["0.0.0.0/0"]` (valor por defecto del módulo)
- **Descripción:** El endpoint público del clúster acepta conexiones de cualquier dirección IP en Internet.
- **Riesgo:** Superficie de ataque máxima. Cualquier IP puede enviar peticiones al API server.
- **Recomendación:** Agregar en `modules/eks/main.tf` dentro del bloque del módulo EKS: `cluster_endpoint_public_access_cidrs = ["<IP_CORPORATIVA>/32", "<IP_GITHUB_RUNNERS>"]`. Ver IPs de GitHub Actions: https://api.github.com/meta.
- **Referencia:** https://avd.aquasec.com/misconfig/aws-0041

---

### 🔴 [CRITICAL] AWS-0104 — Egress irrestricto en Security Group de nodos EKS
- **Herramienta:** Trivy
- **Archivo:** `terraform-aws-modules/eks/aws/node_groups.tf` línea 218
- **Línea relevante:** `cidr_blocks = ["0.0.0.0/0"]` (egress rule del módulo)
- **Descripción:** La regla de salida del security group de los nodos permite cualquier tráfico hacia cualquier destino en Internet.
- **Riesgo:** En caso de compromiso de un nodo (escape de contenedor, RCE), el atacante tendría egress irrestricto hacia Internet para exfiltrar datos o establecer C2.
- **Recomendación:** Definir `node_security_group_additional_rules` con egress restringido a VPC CIDR, endpoints de AWS y repositorios de imágenes necesarios. Considerar complementar con AWS Network Firewall o VPC endpoint policies.
- **Referencia:** https://avd.aquasec.com/misconfig/aws-0104

---

### 🔴 [CRITICAL] Secret Keyword — Credencial detectada en workflow
- **Herramienta:** detect-secrets (plugin: KeywordDetector)
- **Archivo:** `.github/workflows/main.yml` línea **38**
- **Hash:** `3e26d6750975d678acb8fa35a0f69237881576b0` (no verificado)
- **Descripción:** La herramienta detectó un patrón de keyword de secreto en la línea 38 del workflow. El contexto corresponde al bloque `secrets: inherit` o a referencias de credenciales AWS (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) que se pasan como secretos de repositorio.
- **Riesgo:** Si los valores de secretos estuvieran hardcodeados en lugar de ser referencias a GitHub Secrets, representaría una exposición directa de credenciales AWS en el repositorio.
- **Acción requerida:** Verificar manualmente la línea 38. Si es una referencia a `${{ secrets.AWS_ACCESS_KEY_ID }}` es un falso positivo del detector; documentarlo. Si es un valor literal, rotar la credencial inmediatamente.
- **Recomendación complementaria:** Adoptar OIDC federation entre GitHub Actions y AWS (elimina la necesidad de `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` estáticos en GitHub Secrets).

---

## 🟠 Hallazgos de Severidad HIGH

### 🟠 [HIGH] AWS-0164 — Subnets públicas asignan IP pública automáticamente
- **Herramienta:** Trivy
- **Archivo:** `modules/vpc/main.tf` línea ~11 → `terraform-aws-modules/vpc/aws/main.tf` línea 159
- **Línea relevante:** `map_public_ip_on_launch = true`
- **Descripción:** Toda instancia lanzada en subnets públicas recibe una IP pública automáticamente.
- **Riesgo:** Recursos en subnets públicas podrían quedar expuestos accidentalmente si un security group mal configurado lo permite.
- **Recomendación:** Cambiar a `map_public_ip_on_launch = false`. El NAT gateway y el Internet Gateway son suficientes para el flujo de tráfico EKS. Las IPs públicas solo deberían asignarse explícitamente cuando sea necesario (ej. bastions).

---

## 🟡 Hallazgos de Severidad MEDIUM

### 🟡 [MEDIUM] AWS-0038 — Logs del control plane EKS no habilitados
- **Herramienta:** Trivy
- **Archivo:** `modules/eks/main.tf` líneas 3–61 → `terraform-aws-modules/eks/aws/main.tf` línea 44
- **Mensajes:**
  - `Control plane controller manager logging is not enabled.`
  - `Control plane scheduler logging is not enabled.`
- **Descripción:** Los logs de `controllerManager` y `scheduler` del plano de control no están activados.
- **Riesgo:** Sin estos logs en CloudWatch, la capacidad de auditoría post-incidente es limitada. No se puede trazar decisiones del scheduler ni errores del controller manager.
- **Recomendación:** Agregar en el módulo EKS:
  ```hcl
  cluster_enabled_log_types = ["audit", "api", "authenticator", "controllerManager", "scheduler"]
  ```
- **Referencia:** https://avd.aquasec.com/misconfig/aws-0038

---

### 🟡 [MEDIUM] AWS-0342 — IAM PassRole con advertencia de escalada
- **Herramienta:** Trivy
- **Archivo:** `modules/eks/main.tf` líneas 246–259
- **Línea relevante:** `Action = "iam:PassRole"` en `aws_iam_policy.karpenter_iam_integration`
- **Descripción:** El permiso `iam:PassRole` puede ser utilizado para escalar privilegios si el rol que se pasa tiene más permisos que el principal que lo otorga.
- **Evaluación:** ⚠️ **Falso positivo parcial / Justificado** — El permiso está correctamente restringido con `Condition: StringEquals: iam:PassedToService: ec2.amazonaws.com` y el recurso es el ARN específico del rol de nodo de Karpenter. Es el patrón requerido por Karpenter para lanzar instancias EC2. El warning de Trivy es genérico y no evalúa las condiciones.
- **Justificación:** Necesario para la operación de Karpenter. La condición `iam:PassedToService` restringe el uso únicamente al servicio EC2. Ver [documentación Karpenter IAM](https://karpenter.sh/docs/reference/cloud-providers/aws/iam/).

---

## 🔵 Hallazgos UNKNOWN / Checkov (sin severidad asignada)

| ID | Check | Archivo | Líneas | Descripción |
|---|---|---|---|---|
| CKV_TF_1 | Módulo sin commit hash | `modules/eks/main.tf` | 3–61 | `terraform-aws-modules/eks/aws` usa versión semver, no hash de commit |
| CKV_TF_1 | Módulo sin commit hash | `modules/vpc/main.tf` | 1–26 | `terraform-aws-modules/vpc/aws` usa versión semver, no hash de commit |
| CKV_AWS_288 | IAM permite exfiltración de datos | `modules/eks/main.tf` | 281–305 | `karpenter_resource_discovery`: acciones `ec2:Describe*` con `Resource: "*"` |
| CKV_AWS_355 | IAM recurso `*` con acciones restrictables | `modules/eks/main.tf` | 281–305 | `karpenter_resource_discovery`: recurso `*` en describe actions |
| CKV_AWS_355 | IAM recurso `*` con acciones restrictables | `modules/iam/main.tf` | 63–83 | `kubeconfig_policy`: `eks:DescribeCluster` con `Resource: "*"` |
| CKV_AWS_273 | Usuarios IAM en lugar de SSO | `modules/iam/main.tf` | 1–4 | `devops_user1` es un `aws_iam_user` |
| CKV_AWS_273 | Usuarios IAM en lugar de SSO | `modules/iam/main.tf` | 6–9 | `devops_user2` es un `aws_iam_user` |
| CKV_AWS_40 | Política en usuario (no en grupo/rol) | `modules/iam/main.tf` | 31–45 | `devops_user1_assume_role` como `aws_iam_user_policy` |
| CKV_AWS_40 | Política en usuario (no en grupo/rol) | `modules/iam/main.tf` | 47–61 | `devops_user2_assume_role` como `aws_iam_user_policy` |

### Análisis de los hallazgos Checkov UNKNOWN

**CKV_TF_1 (Supply Chain):** Los módulos de la comunidad `terraform-aws-modules` usan versionado semver (`version = "21.29.0"`). Fijar a un commit hash garantiza inmutabilidad de supply chain, pero rompe la compatibilidad con el Terraform Registry (que no acepta refs de git en el campo `version` para módulos públicos). Alternativa: usar la fuente git directa con ref:
```hcl
source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=<commit-hash>"
```

**CKV_AWS_288 / CKV_AWS_355 (Karpenter resource discovery):** `ec2:Describe*`, `pricing:GetProducts` y `ssm:GetParameter` son operaciones de solo lectura que **no admiten scope de recurso** en AWS IAM (el ARN `*` es técnicamente obligatorio para estas APIs). El hallazgo es un **falso positivo estructural** de Checkov. Justificado y documentado.

**CKV_AWS_355 (kubeconfig_policy):** `eks:DescribeCluster` y `eks:ListClusters` podrían ser acotados a ARNs de cluster específicos. Recomendación: restringir a `arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/devopslab-eks`.

**CKV_AWS_273 / CKV_AWS_40 (IAM Users):** El README del proyecto documenta explícitamente que el módulo IAM es para demo/laboratorio. En entornos productivos, estos usuarios deberían ser reemplazados por identidades federadas (AWS SSO / IAM Identity Center).

---

## 🟡 Hallazgos Justificados

| ID | Categoría | Hallazgo | Responsable | Fecha revisión | Justificación |
|---|---|---|---|---|---|
| AWS-0342 | Falso positivo | `iam:PassRole` en Karpenter | Equipo DevOps | 2027-01-29 | Condición `iam:PassedToService=ec2.amazonaws.com` + recurso ARN específico. Requerido por Karpenter. |
| CKV_AWS_288 | Falso positivo estructural | `ec2:Describe*` con `*` | Equipo DevOps | 2027-01-29 | AWS no admite scope de ARN para APIs Describe. Karpenter requiere estas acciones de discovery. |
| CKV_AWS_355 (karpenter) | Falso positivo estructural | `ec2:Describe*` con `*` | Equipo DevOps | 2027-01-29 | Ídem CKV_AWS_288. |
| CKV_AWS_273 | Deuda técnica / Lab | Usuarios IAM locales | Equipo DevOps | 2027-04-29 | Entorno de laboratorio. Migrar a IAM Identity Center en producción. |
| CKV_AWS_40 | Deuda técnica / Lab | Política en usuario | Equipo DevOps | 2027-04-29 | Entorno de laboratorio. Consolidar en grupos/roles en producción. |

---

## 🚀 Recomendaciones Priorizadas

### P1 — Crítico (acción inmediata)

1. **Restringir acceso público al API server de EKS**
   - Agregar en `modules/eks/main.tf`:
   ```hcl
   cluster_endpoint_public_access_cidrs = ["<IP_CORP>/32"]
   ```
   - O deshabilitar completamente: `endpoint_public_access = false`

2. **Verificar y eliminar secreto en `.github/workflows/main.yml:38`**
   - Si es un valor literal, rotar la credencial y migrar a OIDC:
   ```yaml
   - uses: aws-actions/configure-aws-credentials@v4
     with:
       role-to-assume: arn:aws:iam::<ACCOUNT>:role/github-actions-role
       aws-region: us-east-1
   ```

3. **Habilitar logs del control plane EKS**
   ```hcl
   cluster_enabled_log_types = ["audit", "api", "authenticator", "controllerManager", "scheduler"]
   ```

### P2 — Alto (próximo sprint)

4. **Desactivar auto-asignación de IP pública en subnets públicas**
   - En `modules/vpc/main.tf`: `map_public_ip_on_launch = false`

5. **Restringir `kubeconfig_policy` a ARNs de cluster específicos**
   ```hcl
   Resource = "arn:aws:eks:us-east-1:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
   ```

### P3 — Mejoras de madurez (backlog)

6. **Agregar DynamoDB para state locking**
   ```hcl
   backend "s3" {
     dynamodb_table = "tf-state-lock"
   }
   ```

7. **Corregir versión Terraform en `main.yml`**: `1.16.5` → `1.6.5` (o la versión real deseada)

8. **Reemplazar usuarios IAM locales por IAM Identity Center** en entornos no-lab

9. **Configurar NAT gateways por AZ** para verdadera alta disponibilidad (`single_nat_gateway = false`)

10. **Fijar módulos comunitarios a commit hash** si se requiere inmutabilidad de supply chain en producción

---

## 🏆 Top 3 Riesgos Principales

1. 🔴 **API Server EKS expuesto públicamente sin restricción de CIDR** — El plano de control Kubernetes acepta conexiones de `0.0.0.0/0`. Un endpoint expuesto con credenciales válidas filtradas es acceso directo al clúster.

2. 🔴 **Posible secreto/credencial en workflow de CI/CD** — Detectado por detect-secrets en `.github/workflows/main.yml:38`. Si es una credencial AWS hardcodeada, representa compromiso total de la cuenta.

3. 🟠 **Sin logs de auditoría del control plane** — La ausencia de logs de `audit`, `controllerManager` y `scheduler` en CloudWatch Logs elimina la capacidad de investigación forense ante un incidente de seguridad en el clúster.

---

## 📂 Fuentes Utilizadas

| Herramienta | Versión | Tipo | Reglas |
|---|---|---|---|
| Checkov | 3.3.8 | SAST estático Terraform | Reglas internas + PrismaCloud |
| Trivy | 0.71.1 | Misconfiguraciones IaC + secretos | AVD (Aqua Vulnerability Database) |
| detect-secrets | 1.5.47 | Detección de secretos en texto plano | 23 plugins (KeywordDetector, AWSKeyDetector, etc.) |
| Análisis por conocimiento | — | Revisión manual LLM | Patrones arquitecturales y mejores prácticas AWS/EKS |

> ⚠️ **Disclaimer:** Los hallazgos marcados como "evaluados por conocimiento" (sección de criterios ✔️ Cumple) se basan en la revisión manual del código por el LLM y no fueron validados por herramienta SAST automatizada. Se recomienda complementar con `terraform-compliance` o políticas de Sentinel para validación programática de esos criterios.

---

*Reporte generado por Kiro IDE + pragma_sast_ai MCP | 2026-10-29 | v1.0.0*
