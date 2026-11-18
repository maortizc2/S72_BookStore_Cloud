#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/bin:/Users/reddragon/.docker/bin:${PATH}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.aws/credentials" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${ROOT_DIR}/.aws/credentials"
  export AWS_CONFIG_FILE="${ROOT_DIR}/.aws/config"
fi

echo "=================================================================="
echo " 1. Estado de los Pods de Microservicios en Amazon EKS"
echo "=================================================================="
kubectl get pods -o wide

echo ""
echo "=================================================================="
echo " 2. Contenido de /usr/src/app/logs/clickstream.log (Volumen emptyDir)"
echo "=================================================================="
for SVC in auth-service books-service orders-service; do
  for POD in $(kubectl get pods -l app="${SVC}" -o jsonpath='{.items[*].metadata.name}'); do
    echo "--- Servicio: ${SVC} | Pod: ${POD} ---"
    kubectl exec "${POD}" -c "${SVC}" -- sh -c 'if [ -s /usr/src/app/logs/clickstream.log ]; then tail -n 10 /usr/src/app/logs/clickstream.log; else echo "(Archivo clickstream.log creado y vacío)"; ls -la /usr/src/app/logs/; fi'
    echo ""
  done
done

echo "=================================================================="
echo " 3. Logs del Contenedor Sidecar (clickstream-sidecar -> CloudWatch)"
echo "=================================================================="
if [[ "${1:-}" == "-f" ]]; then
  echo "Escuchando eventos de clickstream en TIEMPO REAL (Ctrl+C para salir)..."
  kubectl logs -l tier=api -c clickstream-sidecar -f --prefix=true --tail=20
else
  for SVC in auth-service books-service orders-service; do
    for POD in $(kubectl get pods -l app="${SVC}" -o jsonpath='{.items[*].metadata.name}'); do
      echo "--- Servicio: ${SVC} | Pod: ${POD} (Contenedor: clickstream-sidecar) ---"
      kubectl logs "${POD}" -c clickstream-sidecar --tail=15
      echo ""
    done
  done
  echo "Tip: Ejecuta './scripts/ver_logs.sh -f' para seguir los logs en tiempo real."
fi
