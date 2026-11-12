#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# BookStore Co. - Script Automatizado Fase 2 y Fase 3 (AWS Academy Learner Lab)
# ==============================================================================
# Aprovisiona de forma idempotente y en paralelo:
#   Fase 2:
#     1. VPC Multi-AZ (2 Subredes Públicas + 2 Subredes Privadas + IGW + NAT GW)
#     2. Repositorios Amazon ECR + Build & Push de imágenes (Frontend y Backend)
#     3. Amazon RDS PostgreSQL en Subredes Privadas + Backups y Auto-escalado
#   Fase 3:
#     4. Clúster Amazon EKS + Managed Node Group en Subredes Privadas (con LabRole)
#     5. Inicialización de RDS (schema + roles + seed) desde el clúster EKS
#     6. Despliegue de Backend (con Sidecar Fluent Bit + emptyDir para clickstream.log)
#        y Frontend (con Service LoadBalancer público)
# ==============================================================================

export PATH="/usr/local/bin:/Users/reddragon/.docker/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# Usar credenciales locales del proyecto si existen en .aws/
if [[ -f "${ROOT_DIR}/.aws/credentials" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${ROOT_DIR}/.aws/credentials"
  export AWS_CONFIG_FILE="${ROOT_DIR}/.aws/config"
fi

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_PAGER=""

# Parámetros de configuración
PROJECT_NAME="bookstore"
CLUSTER_NAME="bookstore-cluster"
NODEGROUP_NAME="bookstore-private-nodes"
RDS_INSTANCE_ID="bookstore-db"
DB_NAME="bookstore"
DB_ADMIN_USER="bookstore_admin"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-AdminBookstore2026!}"
APP_DB_USER="bookstore_app"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-AppBookstore2026!}"
INGEST_DB_USER="bookstore_ingest"
INGEST_DB_PASSWORD="${INGEST_DB_PASSWORD:-IngestBookstore2026!}"
IMAGE_TAG="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"

log() {
  printf '\n\033[1;34m[%s] === %s ===\033[0m\n' "$(date '+%H:%M:%S')" "$1"
}

info() {
  printf '  -> %s\n' "$1"
}

# ==============================================================================
# 0. Verificar identidad en AWS Academy y obtener LabRole
# ==============================================================================
log "0. Verificando credenciales de AWS Academy y LabRole"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

info "Account ID : ${ACCOUNT_ID}"
info "Region     : ${AWS_REGION}"
info "LabRole ARN: ${LAB_ROLE_ARN}"
info "ECR URI    : ${ECR_REGISTRY}"

# ==============================================================================
# 1. Fase 2 - Diseño de Red (VPC Multi-AZ)
# ==============================================================================
log "1. Fase 2: Aprovisionando Topología de Red VPC Multi-AZ"

VPC_ID="$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query "Vpcs[0].VpcId" --output text)"

if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
  VPC_ID="$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
    --query "Vpc.VpcId" --output text)"
  info "VPC creada: ${VPC_ID}"
else
  info "VPC existente encontrada: ${VPC_ID}"
fi

aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames "{\"Value\":true}"

# Internet Gateway
IGW_ID="$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query "InternetGateways[0].InternetGatewayId" --output text)"

if [[ "${IGW_ID}" == "None" || -z "${IGW_ID}" ]]; then
  IGW_ID="$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw}]" \
    --query "InternetGateway.InternetGatewayId" --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
  info "Internet Gateway creado y adjuntado: ${IGW_ID}"
else
  info "Internet Gateway existente: ${IGW_ID}"
fi

# Función auxiliar para crear o recuperar subredes
ensure_subnet() {
  local name="$1"
  local cidr="$2"
  local az="$3"
  local is_public="$4"
  local elb_tag_key="$5"

  local subnet_id
  subnet_id="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${name}" \
    --query "Subnets[0].SubnetId" --output text)"

  if [[ "${subnet_id}" == "None" || -z "${subnet_id}" ]]; then
    subnet_id="$(aws ec2 create-subnet \
      --vpc-id "${VPC_ID}" \
      --cidr-block "${cidr}" \
      --availability-zone "${az}" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=${elb_tag_key},Value=1},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared}]" \
      --query "Subnet.SubnetId" --output text)"
  else
    aws ec2 create-tags --resources "${subnet_id}" \
      --tags "Key=${elb_tag_key},Value=1" "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
  fi

  if [[ "${is_public}" == "true" ]]; then
    aws ec2 modify-subnet-attribute --subnet-id "${subnet_id}" --map-public-ip-on-launch
  fi

  echo "${subnet_id}"
}

PUB_SUBNET_1="$(ensure_subnet "${PROJECT_NAME}-public-1a" "10.0.1.0/24" "${AWS_REGION}a" "true" "kubernetes.io/role/elb")"
PUB_SUBNET_2="$(ensure_subnet "${PROJECT_NAME}-public-1b" "10.0.2.0/24" "${AWS_REGION}b" "true" "kubernetes.io/role/elb")"
PRIV_SUBNET_1="$(ensure_subnet "${PROJECT_NAME}-private-1a" "10.0.11.0/24" "${AWS_REGION}a" "false" "kubernetes.io/role/internal-elb")"
PRIV_SUBNET_2="$(ensure_subnet "${PROJECT_NAME}-private-1b" "10.0.12.0/24" "${AWS_REGION}b" "false" "kubernetes.io/role/internal-elb")"

info "Subredes Públicas : ${PUB_SUBNET_1} (${AWS_REGION}a), ${PUB_SUBNET_2} (${AWS_REGION}b)"
info "Subredes Privadas : ${PRIV_SUBNET_1} (${AWS_REGION}a), ${PRIV_SUBNET_2} (${AWS_REGION}b)"

# Tabla de enrutamiento pública
PUB_RT_ID="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT_NAME}-public-rt" \
  --query "RouteTables[0].RouteTableId" --output text)"

if [[ "${PUB_RT_ID}" == "None" || -z "${PUB_RT_ID}" ]]; then
  PUB_RT_ID="$(aws ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-rt}]" \
    --query "RouteTable.RouteTableId" --output text)"
  aws ec2 create-route --route-table-id "${PUB_RT_ID}" --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PUB_RT_ID}" --subnet-id "${PUB_SUBNET_1}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PUB_RT_ID}" --subnet-id "${PUB_SUBNET_2}" >/dev/null
  info "Tabla de rutas pública configurada: ${PUB_RT_ID}"
fi

# NAT Gateway para salida a Internet desde las subredes privadas (nodos EKS)
NAT_GW_ID="$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=pending,available" \
  --query "NatGateways[0].NatGatewayId" --output text)"

if [[ "${NAT_GW_ID}" == "None" || -z "${NAT_GW_ID}" ]]; then
  EIP_ALLOC_ID="$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text)"
  NAT_GW_ID="$(aws ec2 create-nat-gateway \
    --subnet-id "${PUB_SUBNET_1}" \
    --allocation-id "${EIP_ALLOC_ID}" \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-gw}]" \
    --query "NatGateway.NatGatewayId" --output text)"
  info "NAT Gateway creado (${NAT_GW_ID}), esperando disponibilidad..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_ID}"
else
  info "NAT Gateway existente: ${NAT_GW_ID}"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_ID}"
fi

# Tabla de enrutamiento privada
PRIV_RT_ID="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT_NAME}-private-rt" \
  --query "RouteTables[0].RouteTableId" --output text)"

if [[ "${PRIV_RT_ID}" == "None" || -z "${PRIV_RT_ID}" ]]; then
  PRIV_RT_ID="$(aws ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt}]" \
    --query "RouteTable.RouteTableId" --output text)"
  aws ec2 create-route --route-table-id "${PRIV_RT_ID}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW_ID}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${PRIV_SUBNET_1}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${PRIV_SUBNET_2}" >/dev/null
  info "Tabla de rutas privada configurada: ${PRIV_RT_ID}"
fi

# ==============================================================================
# 2. Iniciar Aprovisionamiento en Paralelo de RDS (Fase 2) y Clúster EKS (Fase 3)
# ==============================================================================
log "2. Iniciando en paralelo Amazon RDS (Subredes Privadas) y Clúster Amazon EKS"

RDS_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${PROJECT_NAME}-rds-sg" \
  --query "SecurityGroups[0].GroupId" --output text)"

if [[ "${RDS_SG_ID}" == "None" || -z "${RDS_SG_ID}" ]]; then
  RDS_SG_ID="$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-rds-sg" \
    --description "Allow PostgreSQL 5432 from VPC subnets" \
    --vpc-id "${VPC_ID}" \
    --query "GroupId" --output text)"
  aws ec2 authorize-security-group-ingress \
    --group-id "${RDS_SG_ID}" \
    --protocol tcp \
    --port 5432 \
    --cidr 10.0.0.0/16 >/dev/null
  info "Security Group RDS creado: ${RDS_SG_ID}"
else
  info "Security Group RDS existente: ${RDS_SG_ID}"
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" >/dev/null 2>&1; then
  aws rds create-db-subnet-group \
    --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" \
    --db-subnet-group-description "Private subnets for BookStore RDS PostgreSQL" \
    --subnet-ids "${PRIV_SUBNET_1}" "${PRIV_SUBNET_2}" >/dev/null
  info "DB Subnet Group creado: ${PROJECT_NAME}-db-subnet-group"
else
  info "DB Subnet Group existente: ${PROJECT_NAME}-db-subnet-group"
fi

if ! aws rds describe-db-instances --db-instance-identifier "${RDS_INSTANCE_ID}" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --db-name "${DB_NAME}" \
    --engine postgres \
    --db-instance-class db.t3.micro \
    --allocated-storage 20 \
    --max-allocated-storage 100 \
    --storage-type gp3 \
    --master-username "${DB_ADMIN_USER}" \
    --master-user-password "${DB_ADMIN_PASSWORD}" \
    --vpc-security-group-ids "${RDS_SG_ID}" \
    --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --no-multi-az >/dev/null
  info "Creación de instancia RDS iniciada en segundo plano: ${RDS_INSTANCE_ID}"
else
  RDS_STATUS="$(aws rds describe-db-instances --db-instance-identifier "${RDS_INSTANCE_ID}" --query "DBInstances[0].DBInstanceStatus" --output text)"
  info "Instancia RDS ya existe (${RDS_INSTANCE_ID}) con estado: ${RDS_STATUS}"
  if [[ "${RDS_STATUS}" == "stopped" ]]; then
    info "Iniciando instancia RDS detenida (${RDS_INSTANCE_ID})..."
    aws rds start-db-instance --db-instance-identifier "${RDS_INSTANCE_ID}" >/dev/null
  fi
fi

if ! aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws eks create-cluster \
    --name "${CLUSTER_NAME}" \
    --role-arn "${LAB_ROLE_ARN}" \
    --resources-vpc-config "subnetIds=${PUB_SUBNET_1},${PUB_SUBNET_2},${PRIV_SUBNET_1},${PRIV_SUBNET_2},endpointPublicAccess=true,endpointPrivateAccess=true" >/dev/null
  info "Creación de clúster EKS iniciada en segundo plano: ${CLUSTER_NAME}"
else
  info "Clúster EKS ya existe: ${CLUSTER_NAME}"
fi

# ==============================================================================
# 3. Fase 2 - Registro de Artefactos en Amazon ECR (mientras EKS y RDS se crean)
# ==============================================================================
log "3. Fase 2: Creando Repositorios ECR y Publicando Imágenes"

for repo in bookstore-backend bookstore-frontend; do
  if ! aws ecr describe-repositories --repository-names "${repo}" >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "${repo}" >/dev/null
    info "Repositorio ECR creado: ${repo}"
  else
    info "Repositorio ECR existente: ${repo}"
  fi
done

# Actualizar IMAGE_REGISTRY en .env local
sed -i.bak "s|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${ECR_REGISTRY}|" "${ROOT_DIR}/.env"
rm -f "${ROOT_DIR}/.env.bak"

if aws ecr describe-images --repository-name bookstore-backend --image-ids imageTag="${IMAGE_TAG}" >/dev/null 2>&1 && \
   aws ecr describe-images --repository-name bookstore-frontend --image-ids imageTag="${IMAGE_TAG}" >/dev/null 2>&1 && \
   [[ "${FORCE_BUILD:-false}" != "true" ]]; then
  info "Imágenes bookstore-backend:${IMAGE_TAG} y bookstore-frontend:${IMAGE_TAG} ya existen en ECR (omitiendo rebuild)."
else
  # Verificar que Docker Desktop esté en ejecución
  if ! docker info >/dev/null 2>&1; then
    info "Iniciando Docker Desktop..."
    open -a Docker || true
    for _ in {1..30}; do
      if docker info >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
  fi

  aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"

  info "Construyendo y subiendo bookstore-backend:${IMAGE_TAG} a ECR..."
  docker buildx build \
    --platform linux/amd64 \
    --build-arg NODE_IMAGE=node:24-alpine \
    -t "${ECR_REGISTRY}/bookstore-backend:${IMAGE_TAG}" \
    --push \
    "${ROOT_DIR}/backend"

  info "Construyendo y subiendo bookstore-frontend:${IMAGE_TAG} a ECR..."
  docker buildx build \
    --platform linux/amd64 \
    --build-arg NODE_IMAGE=node:24-alpine \
    --build-arg NGINX_IMAGE=nginx:1.27-alpine \
    --build-arg VITE_API_BASE_URL=/ \
    --build-arg VITE_API_PREFIX=/api \
    --build-arg VITE_CURRENCY_LOCALE=es-CO \
    --build-arg VITE_CURRENCY_CODE=COP \
    -t "${ECR_REGISTRY}/bookstore-frontend:${IMAGE_TAG}" \
    --push \
    "${ROOT_DIR}/frontend"
fi

# ==============================================================================
# 4. Fase 3 - Finalizar Clúster EKS y Aprovisionar Node Group en Subredes Privadas
# ==============================================================================
log "4. Fase 3: Esperando Clúster EKS y Aprovisionando Nodos en Subredes Privadas"

aws eks wait cluster-active --name "${CLUSTER_NAME}"
info "Clúster EKS ACTIVE: ${CLUSTER_NAME}"

if ! aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP_NAME}" >/dev/null 2>&1; then
  aws eks create-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    --node-role "${LAB_ROLE_ARN}" \
    --subnets "${PRIV_SUBNET_1}" "${PRIV_SUBNET_2}" \
    --instance-types t3.medium \
    --scaling-config minSize=2,maxSize=3,desiredSize=2 \
    --ami-type AL2023_x86_64_STANDARD >/dev/null
  info "Creación de Node Group en subredes privadas iniciada (${NODEGROUP_NAME}). Esperando estado ACTIVE..."
else
  info "Node Group ya existe (${NODEGROUP_NAME}). Verificando estado ACTIVE..."
fi

aws eks wait nodegroup-active --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP_NAME}"
info "Node Group ACTIVE: ${NODEGROUP_NAME}"

# Configurar kubectl
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# Habilitar IMDSv2 hop limit = 2 en los nodos de EKS para que el Sidecar Fluent Bit pueda enviar logs a CloudWatch usando LabRole
for INSTANCE_ID in $(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text); do
  aws ec2 modify-instance-metadata-options \
    --instance-id "${INSTANCE_ID}" \
    --http-put-response-hop-limit 2 \
    --http-endpoint enabled >/dev/null
  info "IMDS hop-limit=2 configurado en nodo EC2: ${INSTANCE_ID}"
done

# ==============================================================================
# 5. Esperar disponibilidad de RDS e Inicializar Esquema + Datos Semilla
# ==============================================================================
log "5. Esperando disponibilidad de Amazon RDS e Inicializando Base de Datos"

aws rds wait db-instance-available --db-instance-identifier "${RDS_INSTANCE_ID}"
RDS_ENDPOINT="$(aws rds describe-db-instances \
  --db-instance-identifier "${RDS_INSTANCE_ID}" \
  --query "DBInstances[0].Endpoint.Address" --output text)"
info "RDS Disponible en Endpoint Privado: ${RDS_ENDPOINT}"

# Ejecutar bootstrap desde un Pod temporal en EKS (dentro de las subredes privadas)
kubectl delete pod rds-bootstrap --ignore-not-found >/dev/null 2>&1 || true
kubectl run rds-bootstrap --image=postgres:17 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/rds-bootstrap --timeout=120s
kubectl cp "${ROOT_DIR}/database" rds-bootstrap:/database

kubectl exec rds-bootstrap -- env \
  DB_HOST="${RDS_ENDPOINT}" \
  DB_PORT="5432" \
  DB_NAME="${DB_NAME}" \
  DB_ADMIN_USER="${DB_ADMIN_USER}" \
  DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD}" \
  APP_DB_USER="${APP_DB_USER}" \
  APP_DB_PASSWORD="${APP_DB_PASSWORD}" \
  INGEST_DB_USER="${INGEST_DB_USER}" \
  INGEST_DB_PASSWORD="${INGEST_DB_PASSWORD}" \
  PGSSLMODE="require" \
  /bin/bash /database/rds/bootstrap.sh

kubectl delete pod rds-bootstrap --ignore-not-found

# ==============================================================================
# 6. Fase 3 - Despliegue en Kubernetes (Backend + Sidecar y Frontend + ELB)
# ==============================================================================
log "6. Fase 3: Desplegando Manifiestos Kubernetes (Backend + Sidecar y Frontend)"

# Actualizar manifiestos k8s/ con los valores reales aprovisionados
sed -i.bak \
  -e "s|DB_HOST: .*|DB_HOST: \"${RDS_ENDPOINT}\"|" \
  "${ROOT_DIR}/k8s/configmap.yaml"

sed -i.bak \
  -e "s|DB_PASSWORD: .*|DB_PASSWORD: \"${APP_DB_PASSWORD}\"|" \
  "${ROOT_DIR}/k8s/secret.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-backend:.*|image: ${ECR_REGISTRY}/bookstore-backend:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/backend-deployment.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-frontend:.*|image: ${ECR_REGISTRY}/bookstore-frontend:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/frontend-deployment.yaml"

rm -f "${ROOT_DIR}/k8s/"*.bak

kubectl apply -f "${ROOT_DIR}/k8s/configmap.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/backend-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/backend-service.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/frontend-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/frontend-service.yaml"

info "Esperando asignación de DNS del LoadBalancer del Frontend..."
ELB_DNS=""
for _ in {1..30}; do
  ELB_DNS="$(kubectl get svc frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${ELB_DNS}" ]]; then
    break
  fi
  sleep 5
done

if [[ -n "${ELB_DNS}" ]]; then
  info "LoadBalancer DNS asignado: http://${ELB_DNS}"
  sed -i.bak \
    -e "s|CORS_ORIGINS: .*|CORS_ORIGINS: \"http://localhost:8080,http://${ELB_DNS}\"|" \
    "${ROOT_DIR}/k8s/configmap.yaml"
  rm -f "${ROOT_DIR}/k8s/configmap.yaml.bak"
  kubectl apply -f "${ROOT_DIR}/k8s/configmap.yaml"
  kubectl rollout restart deployment/backend
fi

kubectl rollout status deployment/backend --timeout=180s
kubectl rollout status deployment/frontend --timeout=180s

log "DESPLIEGUE COMPLETADO EXITOSAMENTE"
echo "=============================================================================="
echo "  Frontend URL (LoadBalancer) : http://${ELB_DNS}"
echo "  RDS PostgreSQL Endpoint     : ${RDS_ENDPOINT}"
echo "  CloudWatch Log Group        : /bookstore/clickstream"
echo "=============================================================================="
kubectl get pods,svc -o wide
