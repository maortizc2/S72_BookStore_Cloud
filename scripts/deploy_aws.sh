#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# BookStore Co. - Script Automatizado Microservicios + Cloudflare CDN + 3 DBs RDS
# ==============================================================================
# Aprovisiona de forma idempotente y en paralelo:
#   Fase 2:
#     1. VPC Multi-AZ (172.16.0.0/16: Subredes Públicas, Privadas de App 2A/2B y Privadas de Datos 3A/3B)
#     2. Repositorios Amazon ECR + Build & Push de imágenes:
#        - bookstore-auth-service
#        - bookstore-books-service
#        - bookstore-orders-service
#        - bookstore-api-gateway
#        (El Frontend React SPA se despliega directamente en Cloudflare CDN)
#     3. 3 Bases de Datos Amazon RDS PostgreSQL en Subredes Privadas de Datos (DB Books, DB Auth, DB Orders)
#   Fase 3:
#     4. Clúster Amazon EKS + Managed Node Group en Subredes Privadas (con LabRole)
#     5. Inicialización de las 3 bases de datos RDS (schemas + roles + seeds) desde EKS
#     6. Despliegue en Kubernetes:
#        - auth-service (Node.js + Sidecar Logs -> CloudWatch)
#        - books-service (Node.js + Sidecar Logs -> CloudWatch)
#        - orders-service (Node.js + Sidecar Logs -> CloudWatch)
#        - api-gateway (Enrutamiento por rutas /api/auth, /api/books, /api/orders + LoadBalancer Público)
# ==============================================================================

export PATH="/usr/local/bin:/Users/reddragon/.docker/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

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

RDS_AUTH_ID="bookstore-db-auth"
RDS_BOOKS_ID="bookstore-db-books"
RDS_ORDERS_ID="bookstore-db-orders"

AUTH_DB_NAME="bookstore_auth"
BOOKS_DB_NAME="bookstore_books"
ORDERS_DB_NAME="bookstore_orders"

DB_ADMIN_USER="bookstore_admin"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-AdminBookstore2026!}"
APP_DB_USER="bookstore_app"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-AppBookstore2026!}"
INGEST_DB_USER="bookstore_ingest"
INGEST_DB_PASSWORD="${INGEST_DB_PASSWORD:-IngestBookstore2026!}"
IMAGE_TAG="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
CLOUDFLARE_ORIGINS="${CLOUDFLARE_ORIGINS:-https://tudominio.com,https://bookstore.pages.dev}"

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
# 1. Fase 2 - Diseño de Red (VPC 172.16.0.0/16 Multi-AZ)
# ==============================================================================
log "1. Fase 2: Aprovisionando Topología de Red VPC Multi-AZ"

VPC_ID="$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query "Vpcs[0].VpcId" --output text)"

if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
  VPC_ID="$(aws ec2 create-vpc \
    --cidr-block 172.16.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
    --query "Vpc.VpcId" --output text)"
  info "VPC creada: ${VPC_ID}"
else
  info "VPC existente encontrada: ${VPC_ID}"
fi

aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames "{\"Value\":true}"

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

PUB_SUBNET_1="$(ensure_subnet "${PROJECT_NAME}-public-1a" "172.16.1.0/24" "${AWS_REGION}a" "true" "kubernetes.io/role/elb")"
PUB_SUBNET_2="$(ensure_subnet "${PROJECT_NAME}-public-1b" "172.16.2.0/24" "${AWS_REGION}b" "true" "kubernetes.io/role/elb")"
PRIV_SUBNET_2A="$(ensure_subnet "${PROJECT_NAME}-private-2a" "172.16.11.0/24" "${AWS_REGION}a" "false" "kubernetes.io/role/internal-elb")"
PRIV_SUBNET_2B="$(ensure_subnet "${PROJECT_NAME}-private-2b" "172.16.12.0/24" "${AWS_REGION}b" "false" "kubernetes.io/role/internal-elb")"
DATA_SUBNET_3A="$(ensure_subnet "${PROJECT_NAME}-data-3a" "172.16.21.0/24" "${AWS_REGION}a" "false" "kubernetes.io/role/data")"
DATA_SUBNET_3B="$(ensure_subnet "${PROJECT_NAME}-data-3b" "172.16.22.0/24" "${AWS_REGION}b" "false" "kubernetes.io/role/data")"

info "Subredes Públicas (1A/1B)        : ${PUB_SUBNET_1}, ${PUB_SUBNET_2}"
info "Subredes Privadas App (2A/2B)    : ${PRIV_SUBNET_2A}, ${PRIV_SUBNET_2B}"
info "Subredes Privadas Datos (3A/3B)  : ${DATA_SUBNET_3A}, ${DATA_SUBNET_3B}"

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
fi

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
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_ID}"
else
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_ID}"
fi

PRIV_RT_ID="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT_NAME}-private-rt" \
  --query "RouteTables[0].RouteTableId" --output text)"

if [[ "${PRIV_RT_ID}" == "None" || -z "${PRIV_RT_ID}" ]]; then
  PRIV_RT_ID="$(aws ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-private-rt}]" \
    --query "RouteTable.RouteTableId" --output text)"
  aws ec2 create-route --route-table-id "${PRIV_RT_ID}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW_ID}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${PRIV_SUBNET_2A}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${PRIV_SUBNET_2B}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${DATA_SUBNET_3A}" >/dev/null
  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID}" --subnet-id "${DATA_SUBNET_3B}" >/dev/null
fi

# ==============================================================================
# 2. Aprovisionar las 3 Instancias Amazon RDS (DB Books, DB Auth, DB Orders) y EKS
# ==============================================================================
log "2. Iniciando en paralelo las 3 instancias Amazon RDS (Subred de Datos 3A/3B) y Clúster Amazon EKS"

RDS_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${PROJECT_NAME}-rds-sg" \
  --query "SecurityGroups[0].GroupId" --output text)"

if [[ "${RDS_SG_ID}" == "None" || -z "${RDS_SG_ID}" ]]; then
  RDS_SG_ID="$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-rds-sg" \
    --description "Allow PostgreSQL 5432 from VPC private subnets" \
    --vpc-id "${VPC_ID}" \
    --query "GroupId" --output text)"
  aws ec2 authorize-security-group-ingress \
    --group-id "${RDS_SG_ID}" \
    --protocol tcp \
    --port 5432 \
    --cidr 172.16.0.0/16 >/dev/null
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" >/dev/null 2>&1; then
  aws rds create-db-subnet-group \
    --db-subnet-group-name "${PROJECT_NAME}-db-subnet-group" \
    --db-subnet-group-description "Private data subnets (3A/3B) for BookStore RDS PostgreSQL" \
    --subnet-ids "${DATA_SUBNET_3A}" "${DATA_SUBNET_3B}" >/dev/null
fi

ensure_rds_instance() {
  local instance_id="$1"
  local db_name="$2"

  if ! aws rds describe-db-instances --db-instance-identifier "${instance_id}" >/dev/null 2>&1; then
    aws rds create-db-instance \
      --db-instance-identifier "${instance_id}" \
      --db-name "${db_name}" \
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
    info "Creación de instancia RDS iniciada: ${instance_id} (${db_name})"
  else
    local status
    status="$(aws rds describe-db-instances --db-instance-identifier "${instance_id}" --query "DBInstances[0].DBInstanceStatus" --output text)"
    info "Instancia RDS existente: ${instance_id} (${status})"
    if [[ "${status}" == "stopped" ]]; then
      aws rds start-db-instance --db-instance-identifier "${instance_id}" >/dev/null
    fi
  fi
}

ensure_rds_instance "${RDS_AUTH_ID}" "${AUTH_DB_NAME}"
ensure_rds_instance "${RDS_BOOKS_ID}" "${BOOKS_DB_NAME}"
ensure_rds_instance "${RDS_ORDERS_ID}" "${ORDERS_DB_NAME}"

if ! aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws eks create-cluster \
    --name "${CLUSTER_NAME}" \
    --role-arn "${LAB_ROLE_ARN}" \
    --resources-vpc-config "subnetIds=${PUB_SUBNET_1},${PUB_SUBNET_2},${PRIV_SUBNET_2A},${PRIV_SUBNET_2B},endpointPublicAccess=true,endpointPrivateAccess=true" >/dev/null
  info "Creación de clúster EKS iniciada: ${CLUSTER_NAME}"
fi

# ==============================================================================
# 3. Fase 2 - Registro de Artefactos en Amazon ECR (3 Microservicios + API Gateway)
# ==============================================================================
log "3. Fase 2: Creando Repositorios ECR y Publicando Imágenes de Microservicios"

REPOS=(
  "bookstore-auth-service"
  "bookstore-books-service"
  "bookstore-orders-service"
  "bookstore-api-gateway"
)

for repo in "${REPOS[@]}"; do
  if ! aws ecr describe-repositories --repository-names "${repo}" >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "${repo}" >/dev/null
    info "Repositorio ECR creado: ${repo}"
  else
    info "Repositorio ECR existente: ${repo}"
  fi
done

aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

for svc in auth-service books-service orders-service; do
  info "Construyendo y subiendo bookstore-${svc}:${IMAGE_TAG}..."
  docker buildx build \
    --platform linux/amd64 \
    --build-arg NODE_IMAGE=node:24-alpine \
    -t "${ECR_REGISTRY}/bookstore-${svc}:${IMAGE_TAG}" \
    --push \
    "${ROOT_DIR}/backend/${svc}"
done

info "Construyendo y subiendo bookstore-api-gateway:${IMAGE_TAG}..."
docker buildx build \
  --platform linux/amd64 \
  --build-arg NGINX_IMAGE=nginx:1.27-alpine \
  -t "${ECR_REGISTRY}/bookstore-api-gateway:${IMAGE_TAG}" \
  --push \
  "${ROOT_DIR}/backend/api-gateway"

# ==============================================================================
# 4. Fase 3 - Finalizar Clúster EKS y Aprovisionar Node Group en Subred Privada (2A/2B)
# ==============================================================================
log "4. Fase 3: Esperando Clúster EKS y Aprovisionando Nodos en Subredes Privadas (2A/2B)"

aws eks wait cluster-active --name "${CLUSTER_NAME}"

if ! aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP_NAME}" >/dev/null 2>&1; then
  aws eks create-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    --node-role "${LAB_ROLE_ARN}" \
    --subnets "${PRIV_SUBNET_2A}" "${PRIV_SUBNET_2B}" \
    --instance-types t3.medium \
    --scaling-config minSize=2,maxSize=4,desiredSize=2 \
    --ami-type AL2023_x86_64_STANDARD >/dev/null
fi

aws eks wait nodegroup-active --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP_NAME}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

for INSTANCE_ID in $(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text); do
  aws ec2 modify-instance-metadata-options \
    --instance-id "${INSTANCE_ID}" \
    --http-put-response-hop-limit 2 \
    --http-endpoint enabled >/dev/null
done

# ==============================================================================
# 5. Esperar disponibilidad de las 3 instancias RDS e Inicializar Esquemas + Seeds
# ==============================================================================
log "5. Esperando disponibilidad de las 3 instancias Amazon RDS e Inicializando Bases de Datos"

aws rds wait db-instance-available --db-instance-identifier "${RDS_AUTH_ID}"
aws rds wait db-instance-available --db-instance-identifier "${RDS_BOOKS_ID}"
aws rds wait db-instance-available --db-instance-identifier "${RDS_ORDERS_ID}"

RDS_AUTH_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "${RDS_AUTH_ID}" --query "DBInstances[0].Endpoint.Address" --output text)"
RDS_BOOKS_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "${RDS_BOOKS_ID}" --query "DBInstances[0].Endpoint.Address" --output text)"
RDS_ORDERS_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "${RDS_ORDERS_ID}" --query "DBInstances[0].Endpoint.Address" --output text)"

info "RDS DB Auth Endpoint   : ${RDS_AUTH_ENDPOINT}"
info "RDS DB Books Endpoint  : ${RDS_BOOKS_ENDPOINT}"
info "RDS DB Orders Endpoint : ${RDS_ORDERS_ENDPOINT}"

kubectl delete pod rds-bootstrap --ignore-not-found >/dev/null 2>&1 || true
kubectl run rds-bootstrap --image=postgres:17 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/rds-bootstrap --timeout=120s
kubectl cp "${ROOT_DIR}/database" rds-bootstrap:/database

kubectl exec rds-bootstrap -- env \
  AUTH_DB_HOST="${RDS_AUTH_ENDPOINT}" \
  AUTH_DB_PORT="5432" \
  AUTH_DB_NAME="${AUTH_DB_NAME}" \
  BOOKS_DB_HOST="${RDS_BOOKS_ENDPOINT}" \
  BOOKS_DB_PORT="5432" \
  BOOKS_DB_NAME="${BOOKS_DB_NAME}" \
  ORDERS_DB_HOST="${RDS_ORDERS_ENDPOINT}" \
  ORDERS_DB_PORT="5432" \
  ORDERS_DB_NAME="${ORDERS_DB_NAME}" \
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
# 6. Fase 3 - Despliegue en Kubernetes (3 Microservicios + Sidecar y API Gateway)
# ==============================================================================
log "6. Fase 3: Desplegando Manifiestos Kubernetes (Auth, Books, Orders y API Gateway)"

sed -i.bak \
  -e "s|AUTH_DB_HOST: .*|AUTH_DB_HOST: \"${RDS_AUTH_ENDPOINT}\"|" \
  -e "s|BOOKS_DB_HOST: .*|BOOKS_DB_HOST: \"${RDS_BOOKS_ENDPOINT}\"|" \
  -e "s|ORDERS_DB_HOST: .*|ORDERS_DB_HOST: \"${RDS_ORDERS_ENDPOINT}\"|" \
  "${ROOT_DIR}/k8s/configmap.yaml"

sed -i.bak \
  -e "s|DB_PASSWORD: .*|DB_PASSWORD: \"${APP_DB_PASSWORD}\"|" \
  "${ROOT_DIR}/k8s/secret.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-auth-service:.*|image: ${ECR_REGISTRY}/bookstore-auth-service:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/auth-deployment.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-books-service:.*|image: ${ECR_REGISTRY}/bookstore-books-service:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/books-deployment.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-orders-service:.*|image: ${ECR_REGISTRY}/bookstore-orders-service:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/orders-deployment.yaml"

sed -i.bak \
  -e "s|image: .*bookstore-api-gateway:.*|image: ${ECR_REGISTRY}/bookstore-api-gateway:${IMAGE_TAG}|" \
  "${ROOT_DIR}/k8s/api-gateway-deployment.yaml"

rm -f "${ROOT_DIR}/k8s/"*.bak

kubectl apply -f "${ROOT_DIR}/k8s/configmap.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/auth-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/books-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/orders-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/api-gateway-deployment.yaml"

info "Esperando asignación de DNS del LoadBalancer del API Gateway..."
ELB_DNS=""
for _ in {1..30}; do
  ELB_DNS="$(kubectl get svc api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${ELB_DNS}" ]]; then
    break
  fi
  sleep 5
done

if [[ -n "${ELB_DNS}" ]]; then
  info "API Gateway LoadBalancer DNS asignado: http://${ELB_DNS}"
  sed -i.bak \
    -e "s|CORS_ORIGINS: .*|CORS_ORIGINS: \"${CLOUDFLARE_ORIGINS},http://${ELB_DNS}\"|" \
    "${ROOT_DIR}/k8s/configmap.yaml"
  rm -f "${ROOT_DIR}/k8s/configmap.yaml.bak"
  kubectl apply -f "${ROOT_DIR}/k8s/configmap.yaml"
  kubectl rollout restart deployment/auth-service deployment/books-service deployment/orders-service
fi

kubectl rollout status deployment/auth-service --timeout=180s
kubectl rollout status deployment/books-service --timeout=180s
kubectl rollout status deployment/orders-service --timeout=180s
kubectl rollout status deployment/api-gateway --timeout=180s

log "DESPLIEGUE COMPLETADO EXITOSAMENTE"
echo "=============================================================================="
echo "  API Gateway URL (AWS LoadBalancer) : http://${ELB_DNS}"
echo "  RDS DB Auth Endpoint               : ${RDS_AUTH_ENDPOINT}"
echo "  RDS DB Books Endpoint              : ${RDS_BOOKS_ENDPOINT}"
echo "  RDS DB Orders Endpoint             : ${RDS_ORDERS_ENDPOINT}"
echo "  CloudWatch Log Group               : /bookstore/clickstream"
echo "=============================================================================="
kubectl get pods,svc -o wide
